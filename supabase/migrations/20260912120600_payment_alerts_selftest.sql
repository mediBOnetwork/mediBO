-- CMD #1929 (8/9) — the tests.
--
-- Two shapes, on purpose:
--  * payment_alert_rule_sample is DATA. A new payment app is an INSERT of a
--    rule plus an INSERT of one sample notification, and the test below covers
--    it from then on with no code change. That is the only way "parsing is
--    dynamic" stays true a year from now.
--  * payment_alert_selftest() builds its own fixture, asserts, and deletes
--    every row it made. It is safe to run on live and leaves nothing behind.

-- ─── the ingest guard, split from the ingest work ───────────────────────────
-- The door checks who is knocking; the core does the work. The selftest and
-- the AI sweep use the core, so the guard can be tested as a guard.
create or replace function public._pa_ingest_core(
  p_device text, p_package text, p_title text, p_text text,
  p_posted_at timestamptz, p_zone smallint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_md5 text; v_posted timestamptz; v_parse jsonb;
begin
  if coalesce(btrim(p_device),'') = '' or coalesce(btrim(p_package),'') = '' then
    return jsonb_build_object('ok', false, 'error','bad_request',
      'message', public.uic('pay_alert.bad_request','A device id and a package name are required.'));
  end if;

  v_posted := coalesce(p_posted_at, now());
  v_md5    := md5(coalesce(p_text,''));

  insert into public.payment_alerts
    (device_id, package_name, raw_title, raw_text, posted_at, text_md5, zone_id, business_date, status)
  values
    (btrim(p_device), btrim(p_package), nullif(btrim(coalesce(p_title,'')),''),
     p_text, v_posted, v_md5, p_zone,
     (v_posted at time zone 'Asia/Kolkata')::date, 'new')
  on conflict (device_id, package_name, posted_at, text_md5) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.payment_alerts
     where device_id = btrim(p_device) and package_name = btrim(p_package)
       and posted_at = v_posted and text_md5 = v_md5;
    return public.payment_alert_state(v_id) || jsonb_build_object('duplicate', true);
  end if;

  v_parse := public.payment_alert_parse_rules(btrim(p_package), p_title, p_text);

  if (v_parse->>'ok')::boolean then
    update public.payment_alerts
       set parsed_amount = nullif(v_parse->>'amount','')::numeric,
           parsed_utr    = nullif(v_parse->>'utr',''),
           parsed_vpa    = nullif(v_parse->>'vpa',''),
           parsed_sender = nullif(v_parse->>'sender',''),
           parse_source  = 'rule',
           parse_rule_id = nullif(v_parse->>'rule_id','')::bigint,
           parse_note    = nullif(v_parse->>'rule_label',''),
           updated_at    = now()
     where id = v_id;
    perform public.payment_alert_match(v_id);

  elsif (v_parse->>'reason') = 'not_credit' then
    update public.payment_alerts
       set status = 'ignored', parse_source = 'rule',
           parse_rule_id = nullif(v_parse->>'rule_id','')::bigint,
           parse_note = public.uic('pay_alert.ignored.not_credit','Not money coming in.'),
           updated_at = now()
     where id = v_id;

  else
    update public.payment_alerts
       set parse_note = v_parse->>'reason', updated_at = now()
     where id = v_id;
    perform public._pa_ai_enqueue(v_id);
  end if;

  return public.payment_alert_state(v_id);
end $$;

create or replace function public.payment_alert_ingest(
  p_device text, p_package text, p_title text, p_text text,
  p_posted_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_role text := coalesce(public.get_my_role(),'');
begin
  if auth.uid() is null
     or not (coalesce(public.is_partner(),false) or v_role in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_alert.not_authorized',
                            'Only a partner or an admin phone can forward payment alerts.'));
  end if;
  return public._pa_ingest_core(p_device, p_package, p_title, p_text, p_posted_at,
           coalesce(public.partner_zone_id(), public.admin_active_zone(), public.zone_default_id()));
end $$;
grant execute on function public.payment_alert_ingest(text, text, text, text, timestamptz) to authenticated;
revoke all on function public._pa_ingest_core(text, text, text, text, timestamptz, smallint) from anon, authenticated;

-- ─── rule samples are DATA ──────────────────────────────────────────────────
create table if not exists public.payment_alert_rule_sample (
  id             bigserial primary key,
  rule_label     text not null,
  package_name   text not null,
  raw_title      text,
  raw_text       text not null,
  expect_credit  boolean not null default true,
  expect_amount  numeric,
  expect_utr     text,
  expect_vpa     text,
  expect_sender  text,
  note           text
);
create unique index if not exists payment_alert_rule_sample_uidx
  on public.payment_alert_rule_sample (rule_label, md5(raw_text));
alter table public.payment_alert_rule_sample enable row level security;

insert into public.payment_alert_rule_sample
  (rule_label, package_name, raw_title, raw_text, expect_credit, expect_amount, expect_utr, expect_vpa, expect_sender, note)
values
 ('Google Pay','com.google.android.apps.nbu.paisa.user','You received ₹500',
  'Pooja Medical paid you ₹500. UPI transaction ID: 412345678901',
  true, 500, '412345678901', null, 'Pooja Medical', 'name before the verb'),
 ('PhonePe','com.phonepe.app','₹1,250.50 received',
  'Received ₹1,250.50 from Sharma Pharma (sharma@ybl). UTR: 523456789012',
  true, 1250.50, '523456789012', 'sharma@ybl', 'Sharma Pharma', 'amount with comma and paise'),
 ('Paytm','net.one97.paytm','Payment received',
  'Received ₹2,000 in your Paytm account from Ravi Kumar. UPI Ref No 634567890123',
  true, 2000, '634567890123', null, 'Ravi Kumar', 'name must not swallow "UPI Ref No"'),
 ('BHIM','in.org.npci.upiapp','Money received',
  'You have received Rs. 750 from anita@okaxis. UPI Transaction ID 745678901234',
  true, 750, '745678901234', 'anita@okaxis', null, 'handle only, no printed name'),
 ('SBI YONO','com.sbi.lotusintouch','SBI Alert',
  'Your A/c XX1234 is credited by Rs.3,499.00 on 12-09-26 trf from POOJA MEDICAL Ref No 856789012345',
  true, 3499.00, '856789012345', null, 'POOJA MEDICAL', '"by Rs." must not read as the sender'),
 ('HDFC Bank','com.snapwork.hdfc','HDFC Bank',
  'Rs.1200.00 credited to a/c XX9876 on 12-09-26 by a/c linked to VPA pooja@oksbi (UPI Ref No 123412341234)',
  true, 1200.00, '123412341234', 'pooja@oksbi', null, 'bank credit naming only the VPA'),
 ('ICICI iMobile','com.icicibank.pockets','ICICI Bank',
  'ICICI Bank Acct XX123 credited with Rs 4,100.00 on 12-Sep-26 from NEHA MEDICALS. UPI Ref No 111122223333',
  true, 4100.00, '111122223333', null, 'NEHA MEDICALS', null),
 ('Axis Bank','com.axis.mobile','Axis Bank',
  'INR 2,150.00 credited to A/c no. XX4321 on 12-09-26 trf from AGARWAL MEDICAL Ref No 444455556666',
  true, 2150.00, '444455556666', null, 'AGARWAL MEDICAL', null),
 ('Kotak 811','com.msf.kbank.mobile','Kotak Bank',
  'Rs.980.00 credited to your Kotak Bank A/c XX2211 by UPI from gupta.medico@paytm. RRN 777788889999',
  true, 980.00, '777788889999', 'gupta.medico@paytm', null, null),
 ('Bank of Baroda','com.bankofbaroda.mconnect','BOB Alert',
  'Rs.1,500.00 credited to A/c XX7788 on 12-09-26 trf from VERMA PHARMA Ref No 222233334444',
  true, 1500.00, '222233334444', null, 'VERMA PHARMA', null),
 ('PNB One','com.infrasofttech.PNBOne','PNB Alert',
  'Rs.650.00 credited to A/c XX3344 on 12-09-26 trf from SINGH MEDICOS Ref No 555566667777',
  true, 650.00, '555566667777', null, 'SINGH MEDICOS', null),
 ('ICICI iMobile Pay','com.csam.icici.bank.imobile','ICICI Bank',
  'Acct XX5566 credited with Rs 3,000.00 on 12-Sep-26 from JAIN DRUG HOUSE. UPI Ref No 888899990000',
  true, 3000.00, '888899990000', null, 'JAIN DRUG HOUSE', null),
 ('WhatsApp Pay','com.whatsapp','Payment received',
  '₹300 received from Neha Medicals. UPI transaction ID 998877665544',
  true, 300, '998877665544', null, 'Neha Medicals', null),
 ('Generic UPI credit','com.some.unknown.bank','Credit alert',
  'INR 899 credited. RRN 123456789012 from MEDIPLUS',
  true, 899, '123456789012', null, 'MEDIPLUS', 'unknown package falls to the * rule'),
 -- Money that is NOT arriving. Each of these carries a ₹ figure and must
 -- still be refused before anything is read out of it.
 ('PhonePe','com.phonepe.app','Payment sent','You paid ₹500 to Ravi. UTR 912345678901',
  false, null, null, null, null, 'an outgoing payment'),
 ('Google Pay','com.google.android.apps.nbu.paisa.user','Payment request','Ravi is requesting ₹500',
  false, null, null, null, null, 'a collect request'),
 ('Axis Bank','com.axis.mobile','Axis Bank','Rs.900 debited from a/c XX1111 on 12-09-26. Avl Bal Rs.5000',
  false, null, null, null, null, 'a debit'),
 ('Paytm','net.one97.paytm','Cashback','You received ₹20 cashback on your last order',
  false, null, null, null, null, 'cashback is not a customer payment')
on conflict (rule_label, md5(raw_text)) do nothing;

-- ─── the self-test ──────────────────────────────────────────────────────────
create or replace function public.payment_alert_selftest()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_pass int := 0; v_fail int := 0;
  v_dev text := 'selftest-1929';
  v_zone smallint := 1;
  v_cust uuid; v_uid uuid; v_order uuid; v_order2 uuid;
  v_claim uuid; v_claim2 uuid;
  v_alert uuid; v_st jsonb; v_r jsonb; s record;
  v_parse jsonb; v_repl boolean := false; v_now timestamptz := now();
  v_speak text; v_n int; v_q bigint;

  procedure_note text;
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin')
     and auth.uid() is not null then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;

  -- Triggers off for the fixture only: this must not raise an order-placed
  -- alert, a WhatsApp message or an invoice on live.
  begin
    set local session_replication_role = replica;
    v_repl := true;
  exception when others then v_repl := false;
  end;

  -- ── fixture ───────────────────────────────────────────────────────────────
  v_uid  := '11111111-1111-4111-8111-191919291929'::uuid;
  v_cust := '22222222-2222-4222-8222-191919291929'::uuid;
  insert into public.pharmacy_profiles
    (id, user_id, pharmacy_name, phone, whatsapp_no, zone_id, address, city, pincode)
  values (v_cust, v_uid, 'Selftest Pharma 1929', '9000019290', '9000019290', v_zone,
          'Selftest address', 'Selftest city', '000000')
  on conflict (id) do update set pharmacy_name = excluded.pharmacy_name,
                                 user_id = excluded.user_id, zone_id = excluded.zone_id;

  insert into public.orders (id, user_id, status, total_amount, zone_id, created_at, order_code)
  values ('33333333-3333-4333-8333-191919291929'::uuid, v_uid, 'pending', 5000, v_zone, v_now, 'ST1929A')
  on conflict (id) do update set status='pending', total_amount=5000, user_id=excluded.user_id
  returning id into v_order;
  insert into public.orders (id, user_id, status, total_amount, zone_id, created_at, order_code)
  values ('44444444-4444-4444-8444-191919291929'::uuid, v_uid, 'pending', 7000, v_zone, v_now, 'ST1929B')
  on conflict (id) do update set status='pending', total_amount=7000, user_id=excluded.user_id
  returning id into v_order2;

  -- ── 1. every seeded rule, from the sample table ───────────────────────────
  for s in select * from public.payment_alert_rule_sample order by id loop
    v_parse := public.payment_alert_parse_rules(s.package_name, s.raw_title, s.raw_text);
    if not s.expect_credit then
      if coalesce((v_parse->>'ok')::boolean,false) = false
         and coalesce(v_parse->>'reason','') = 'not_credit' then
        v_pass := v_pass + 1;
        v_out := v_out || jsonb_build_object('case','rule:'||s.rule_label||' (refused)','ok',true);
      else
        v_fail := v_fail + 1;
        v_out := v_out || jsonb_build_object('case','rule:'||s.rule_label||' (refused)','ok',false,
                            'got', v_parse);
      end if;
    elsif coalesce((v_parse->>'ok')::boolean,false)
      and round(coalesce((v_parse->>'amount')::numeric,-1),2) = round(s.expect_amount,2)
      and coalesce(public._pa_digits(v_parse->>'utr'),'') = coalesce(public._pa_digits(s.expect_utr),'')
      and lower(coalesce(v_parse->>'vpa','')) = lower(coalesce(s.expect_vpa,''))
      and lower(coalesce(v_parse->>'sender','')) = lower(coalesce(s.expect_sender,'')) then
      v_pass := v_pass + 1;
      v_out := v_out || jsonb_build_object('case','rule:'||s.rule_label,'ok',true);
    else
      v_fail := v_fail + 1;
      v_out := v_out || jsonb_build_object('case','rule:'||s.rule_label,'ok',false,
                 'expected', jsonb_build_object('amount',s.expect_amount,'utr',s.expect_utr,
                               'vpa',s.expect_vpa,'sender',s.expect_sender),
                 'got', v_parse);
    end if;
  end loop;

  -- ── 2. full round trip: claim with a UTR → alert → verified ───────────────
  insert into public.payment_claims
    (sender_type, amount, payee_vpa, payee_name, utr, app, order_id, received_at, paid_ts,
     status, payment_method, zone_id)
  values ('selftest', 500, 'pooja@okhdfcbank', 'Pooja Medical', '412345678901',
          'gpay', v_order, v_now, v_now, 'claimed', 'online', v_zone)
  returning id into v_claim;

  v_st := public._pa_ingest_core(v_dev, 'com.google.android.apps.nbu.paisa.user',
            'You received ₹500',
            'Pooja Medical paid you ₹500. UPI transaction ID: 412345678901',
            v_now, v_zone);
  v_alert := (v_st->>'alert_id')::uuid;

  if v_st->>'status' = 'matched'
     and (select status from public.payment_claims where id = v_claim) = 'verified'
     and (select status from public.orders where id = v_order) = 'accepted'
     and (v_st->>'claim_id')::uuid = v_claim then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','roundtrip:utr_full','ok',true);
  else
    v_fail := v_fail + 1;
    v_out := v_out || jsonb_build_object('case','roundtrip:utr_full','ok',false,'got',v_st,
               'claim_status',(select status from public.payment_claims where id = v_claim),
               'order_status',(select status from public.orders where id = v_order));
  end if;

  -- the spoken sentence, built in SQL
  select message into v_speak from public.payment_alert_speak
   where alert_id = v_alert order by id desc limit 1;
  if v_speak = public.inr_money_compact(500) || ' received from Selftest Pharma 1929' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','speak:sentence','ok',true,'message',v_speak);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','speak:sentence','ok',false,'message',coalesce(v_speak,'<none>'));
  end if;

  -- the sender was learned off that verified claim
  if exists (select 1 from public.customer_payment_senders
              where customer_id = v_cust and lower(sender_name) = lower('Pooja Medical')) then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','learn:sender','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','learn:sender','ok',false);
  end if;

  -- ── 3. idempotency: the same notification again is ONE row ────────────────
  v_st := public._pa_ingest_core(v_dev, 'com.google.android.apps.nbu.paisa.user',
            'You received ₹500',
            'Pooja Medical paid you ₹500. UPI transaction ID: 412345678901',
            v_now, v_zone);
  select count(*)::int into v_n from public.payment_alerts where device_id = v_dev
   and text_md5 = md5('Pooja Medical paid you ₹500. UPI transaction ID: 412345678901');
  if coalesce((v_st->>'duplicate')::boolean,false) and v_n = 1 then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ingest:idempotent','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ingest:idempotent','ok',false,'rows',v_n,'got',v_st);
  end if;

  -- ── 4. truncated UTR + amount ─────────────────────────────────────────────
  insert into public.payment_claims
    (sender_type, amount, payee_vpa, utr, app, order_id, received_at, paid_ts, status,
     payment_method, zone_id)
  values ('selftest', 1234.50, 'sharma@ybl', '900011223344', 'phonepe', v_order2,
          v_now, v_now, 'claimed', 'online', v_zone)
  returning id into v_claim2;

  v_st := public._pa_ingest_core(v_dev, 'com.phonepe.app', '₹1,234.50 received',
            'Received ₹1,234.50 from Sharma Pharma. UTR: 223344', v_now, v_zone);
  if v_st->>'status' = 'matched'
     and (v_st->>'claim_id')::uuid = v_claim2
     and (select status from public.payment_claims where id = v_claim2) = 'verified' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','match:utr_suffix','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','match:utr_suffix','ok',false,'got',v_st);
  end if;

  -- ── 5. no UTR at all: amount + payee VPA inside ±15 min ───────────────────
  update public.orders set status='pending' where id = v_order2;
  insert into public.payment_claims
    (sender_type, amount, payee_vpa, app, order_id, received_at, paid_ts, status,
     payment_method, zone_id)
  values ('selftest', 640, 'novutr@okicici', 'phonepe', v_order2, v_now, v_now,
          'claimed', 'online', v_zone)
  returning id into v_claim2;

  v_st := public._pa_ingest_core(v_dev, 'com.phonepe.app', 'Payment received',
            'Received ₹640 from novutr@okicici', v_now, v_zone);
  if v_st->>'status' = 'matched' and (v_st->>'claim_id')::uuid = v_claim2 then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','match:amount_vpa_15min','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','match:amount_vpa_15min','ok',false,'got',v_st);
  end if;

  -- ── 6. ambiguous is never guessed ─────────────────────────────────────────
  update public.orders set status='pending' where id in (v_order, v_order2);
  insert into public.payment_claims
    (sender_type, amount, payee_vpa, app, order_id, received_at, paid_ts, status, payment_method, zone_id)
  values ('selftest', 777, 'twins@okaxis', 'phonepe', v_order,  v_now, v_now, 'claimed','online',v_zone),
         ('selftest', 777, 'twins@okaxis', 'phonepe', v_order2, v_now, v_now, 'claimed','online',v_zone);

  v_st := public._pa_ingest_core(v_dev, 'com.phonepe.app', 'Payment received',
            'Received ₹777 from twins@okaxis', v_now, v_zone);
  if v_st->>'status' = 'unmatched'
     and v_st->>'match_reason' = public.uic('pay_alert.unmatched.ambiguous','') then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','match:ambiguous_refused','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','match:ambiguous_refused','ok',false,'got',v_st);
  end if;

  -- ── 7. a debit is ignored, not matched ────────────────────────────────────
  v_st := public._pa_ingest_core(v_dev, 'com.axis.mobile', 'Axis Bank',
            'Rs.900 debited from a/c XX1111 on 12-09-26. Avl Bal Rs.5000', v_now, v_zone);
  if v_st->>'status' = 'ignored' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ingest:debit_ignored','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ingest:debit_ignored','ok',false,'got',v_st);
  end if;

  -- ── 8. the AI fallback, without paying Vertex ─────────────────────────────
  -- No rule can read this, so it must land unparsed and waiting.
  v_st := public._pa_ingest_core(v_dev, 'com.brand.new.wallet', 'Credit',
            'Paisa aaya: five hundred only, ref XYZ', v_now, v_zone);
  v_alert := (v_st->>'alert_id')::uuid;
  if v_st->>'source' = 'none' and v_st->>'status' = 'new' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ai:falls_through_to_ai','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ai:falls_through_to_ai','ok',false,'got',v_st);
  end if;
  -- the prompt is the backend's
  v_r := public.payment_alert_ai_prompt(v_alert);
  if coalesce((v_r->>'ok')::boolean,false)
     and v_r->>'prompt' like '%Paisa aaya%' and v_r->>'prompt' like '%is_credit%' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ai:prompt_from_backend','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ai:prompt_from_backend','ok',false);
  end if;
  -- and what it read gets matched exactly like a rule parse
  update public.orders set status='pending' where id = v_order;
  insert into public.payment_claims
    (sender_type, amount, utr, app, order_id, received_at, paid_ts, status, payment_method, zone_id)
  values ('selftest', 500, '505050505050', 'wallet', v_order, v_now, v_now, 'claimed','online',v_zone)
  returning id into v_claim2;
  v_st := public.payment_alert_ai_apply(v_alert,
            jsonb_build_object('is_credit',true,'amount',500,'utr','505050505050',
                               'vpa',null,'sender','Paisa Wallet'),
            'gemini-3.5-flash');
  if v_st->>'source' = 'ai' and v_st->>'status' = 'matched'
     and (v_st->>'claim_id')::uuid = v_claim2 then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ai:apply_matches','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ai:apply_matches','ok',false,'got',v_st);
  end if;
  -- an AI answer that says "not a credit" is ignored, never matched
  v_st := public._pa_ingest_core(v_dev, 'com.brand.new.wallet', 'Credit',
            'Kuch hua hai, dekh lo', v_now, v_zone);
  v_st := public.payment_alert_ai_apply((v_st->>'alert_id')::uuid,
            jsonb_build_object('is_credit',false), 'gemini-3.5-flash');
  if v_st->>'status' = 'ignored' and v_st->>'source' = 'ai' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ai:not_credit_ignored','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ai:not_credit_ignored','ok',false,'got',v_st);
  end if;

  -- ── 9. sender learning books a no-claim payment to the only open bill ─────
  -- Close everything except ONE open bill, then send money with no UTR from a
  -- handle we have already learned.
  update public.orders set status='accepted', total_amount = 0 where id = v_order2;
  update public.orders set status='pending', total_amount = 2500 where id = v_order;
  delete from public.payment_claims where sender_type in ('selftest','payment_alert')
    and order_id in (v_order, v_order2);
  insert into public.customer_payment_senders (customer_id, vpa, sender_name, confirmed_at)
  values (v_cust, 'known@okhdfcbank', 'Known Payer', now())
  on conflict (customer_id, coalesce(lower(vpa),''), coalesce(lower(sender_name),''))
  do update set confirmed_at = now();

  select count(*)::int into v_n from public._pa_open_bills(v_cust);
  v_st := public._pa_ingest_core(v_dev, 'com.phonepe.app', 'Payment received',
            'Received ₹2,500 from known@okhdfcbank', v_now + interval '1 second', v_zone);
  if v_n = 1 and v_st->>'status' = 'matched'
     and v_st->>'match_reason' = public.uic('pay_alert.match.sender_bill','')
     and (v_st->>'order_id')::uuid = v_order then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','sender:only_open_bill','ok',true);
  else
    v_fail := v_fail + 1;
    v_out := v_out || jsonb_build_object('case','sender:only_open_bill','ok',false,
               'open_bills', v_n, 'got', v_st);
  end if;

  -- ── 10. two open bills → the customer is asked, and their reply resolves ──
  update public.orders set status='pending', total_amount = 3000 where id = v_order;
  update public.orders set status='pending', total_amount = 4000 where id = v_order2;
  delete from public.payment_claims where autolink_note like 'payment_alert:%'
    and order_id in (v_order, v_order2);
  delete from public.payment_claims where sender_type = 'selftest'
    and order_id in (v_order, v_order2);

  v_st := public._pa_ingest_core(v_dev, 'com.phonepe.app', 'Payment received',
            'Received ₹1,000 from known@okhdfcbank', v_now + interval '2 seconds', v_zone);
  v_alert := (v_st->>'alert_id')::uuid;
  select id into v_q from public.payment_alert_question where alert_id = v_alert and status='open';
  if v_st->>'status' = 'unmatched'
     and v_st->>'match_reason' = public.uic('pay_alert.unmatched.asked','')
     and v_q is not null
     and jsonb_array_length((select options from public.payment_alert_question where id = v_q)) = 2 then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ask:two_bills_asks','ok',true);
  else
    v_fail := v_fail + 1;
    v_out := v_out || jsonb_build_object('case','ask:two_bills_asks','ok',false,'got',v_st,
               'question', (select options from public.payment_alert_question where id = v_q));
  end if;

  -- a reply that is not on the list is refused, with the backend's own words
  v_r := public.payment_alert_answer_try('9000019290', 'maybe 9');
  if coalesce((v_r->>'handled')::boolean,false)
     and coalesce((v_r->>'ok')::boolean,true) = false
     and v_r->>'reply' = public.uic('pay_alert.ask_badnumber','') then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ask:bad_choice_refused','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ask:bad_choice_refused','ok',false,'got',v_r);
  end if;

  -- "1" books it against the first option and says thank you
  v_r := public.payment_alert_answer_try('9000019290', '1');
  if coalesce((v_r->>'ok')::boolean,false)
     and (v_r->>'order_id')::uuid = v_order
     and (select status from public.payment_alerts where id = v_alert) = 'matched'
     and (select status from public.payment_alert_question where id = v_q) = 'answered'
     and v_r->>'reply' like '%'||public.inr_money_compact(1000)||'%' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ask:reply_resolves','ok',true,'reply',v_r->>'reply');
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ask:reply_resolves','ok',false,'got',v_r);
  end if;

  -- a phone with nothing open is left entirely alone
  v_r := public.payment_alert_answer_try('9000019290', '1');
  if coalesce((v_r->>'ok')::boolean,true) = false
     and v_r->>'reason' = 'no_open_question'
     and coalesce((v_r->>'handled')::boolean,false) = false then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ask:no_question_untouched','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ask:no_question_untouched','ok',false,'got',v_r);
  end if;

  -- ── 11. the ingest door refuses a stranger ────────────────────────────────
  v_r := public.payment_alert_ingest(v_dev, 'com.phonepe.app', 'x', 'Received ₹1 from x@y', v_now);
  if coalesce((v_r->>'ok')::boolean,true) = false and v_r->>'error' = 'not_authorized' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ingest:guard_refuses','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ingest:guard_refuses','ok',false,'got',v_r);
  end if;

  -- ── cleanup: nothing this test made survives it ───────────────────────────
  delete from public.payment_alert_speak
   where alert_id in (select id from public.payment_alerts where device_id = v_dev);
  delete from public.payment_alert_question
   where alert_id in (select id from public.payment_alerts where device_id = v_dev);
  delete from public.payment_alerts where device_id = v_dev;
  delete from public.customer_payment_senders where customer_id = v_cust;
  delete from public.payment_claims
   where order_id in (v_order, v_order2)
     and (sender_type in ('selftest','payment_alert') or autolink_note like 'payment_alert:%');
  delete from public.orders where id in (v_order, v_order2);
  delete from public.pharmacy_profiles where id = v_cust;

  return jsonb_build_object(
    'ok', v_fail = 0,
    'passed', v_pass, 'failed', v_fail,
    'triggers_bypassed', v_repl,
    'cases', v_out);
end $$;

revoke all on function public.payment_alert_selftest() from anon;
grant execute on function public.payment_alert_selftest() to authenticated;
