-- CMD #2250 — UPI payee (business VPA + merchant QR), partner-phone payment
-- alerts, alert list/detail and one Payments-to-check list.
-- Every string this build shows lives here or in ui_copy; Flutter renders.

-- ── A. payment_upi_accounts: account type + the merchant params from the QR ──
alter table public.payment_upi_accounts
  add column if not exists account_type  text,
  add column if not exists merchant_code text,
  add column if not exists qr_params     jsonb not null default '{}'::jsonb,
  add column if not exists qr_raw        text,
  add column if not exists test_rupee_at timestamptz,
  add column if not exists test_alert_id uuid;

update public.payment_upi_accounts
   set account_type = case when coalesce(kind,'business') = 'business'
                           then 'business_vpa' else 'personal' end
 where account_type is null;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'payment_upi_accounts_account_type_chk') then
    alter table public.payment_upi_accounts
      add constraint payment_upi_accounts_account_type_chk
      check (account_type is null or account_type in ('business_vpa','personal')) not valid;
  end if;
end $$;

-- kind (CMD #2249) and account_type (#2250) are one fact under two names, so a
-- writer of either leaves both true. Never two sources of truth.
create or replace function public._c2250_upi_type_sync()
returns trigger language plpgsql set search_path to 'public' as $fn$
begin
  if tg_op = 'INSERT' then
    if new.account_type is null and new.kind is not null then
      new.account_type := case when new.kind = 'business' then 'business_vpa' else 'personal' end;
    end if;
    if new.account_type is null then new.account_type := 'business_vpa'; end if;
    new.kind := case when new.account_type = 'business_vpa' then 'business' else 'personal' end;
    return new;
  end if;
  if new.account_type is distinct from old.account_type then
    new.kind := case when new.account_type = 'business_vpa' then 'business' else 'personal' end;
  elsif new.kind is distinct from old.kind then
    new.account_type := case when new.kind = 'business' then 'business_vpa' else 'personal' end;
  end if;
  return new;
end $fn$;

drop trigger if exists trg_c2250_upi_type_sync on public.payment_upi_accounts;
create trigger trg_c2250_upi_type_sync
  before insert or update on public.payment_upi_accounts
  for each row execute function public._c2250_upi_type_sync();

-- ── copy (seed only; an admin's edit is never overwritten by a redeploy) ────
insert into public.ui_copy(key, value) values
  ('pay_payee.title',            '"Payment and Partner"'::jsonb),
  ('pay_payee.section',          '"WHERE CUSTOMERS PAY"'::jsonb),
  ('pay_payee.add_cta',          '"+ Add UPI"'::jsonb),
  ('pay_payee.active',           '"Active"'::jsonb),
  ('pay_payee.make_active',      '"Make active"'::jsonb),
  ('pay_payee.type.business_vpa','"Business VPA"'::jsonb),
  ('pay_payee.type.personal',    '"Personal UPI"'::jsonb),
  ('pay_payee.pay_on',           '"Pay button ON"'::jsonb),
  ('pay_payee.pay_off',          '"QR + screenshot only"'::jsonb),
  ('pay_payee.merchant_qr_ok',   '"Merchant QR ✓"'::jsonb),
  ('pay_payee.merchant_qr_none', '"No merchant QR"'::jsonb),
  ('pay_payee.see_title',        '"What customers see now"'::jsonb),
  ('pay_payee.see_business_1',   '"“Pay ₹X with UPI” button in Cart, Orders and the pay banner"'::jsonb),
  ('pay_payee.see_business_2',   '"Amount and order number locked in the UPI app"'::jsonb),
  ('pay_payee.see_business_3',   '"Laptop users see the same payment as a QR"'::jsonb),
  ('pay_payee.see_personal_1',   '"No Pay button — customers see a QR to scan"'::jsonb),
  ('pay_payee.see_personal_2',   '"The customer uploads a payment screenshot"'::jsonb),
  ('pay_payee.see_personal_3',   '"A partner verifies every payment by hand"'::jsonb),
  ('pay_payee.empty',            '"No UPI account yet."'::jsonb),
  ('pay_payee.empty_hint',       '"Add the business VPA customers should pay into."'::jsonb),
  ('pay_payee.add_title',        '"Add UPI"'::jsonb),
  ('pay_payee.type_label',       '"TYPE"'::jsonb),
  ('pay_payee.type_business_sub','"merchant · Pay button"'::jsonb),
  ('pay_payee.type_personal_sub','"QR + screenshot"'::jsonb),
  ('pay_payee.scan_cta',         '"Scan the merchant QR"'::jsonb),
  ('pay_payee.scan_hint',        '"Recommended. Reads the UPI ID, name and merchant code exactly as the bank issued them, so payments are not blocked."'::jsonb),
  ('pay_payee.or_type',          '"or type it"'::jsonb),
  ('pay_payee.vpa_label',        '"UPI ID (VPA)"'::jsonb),
  ('pay_payee.vpa_hint',         '"name@bank"'::jsonb),
  ('pay_payee.pn_label',         '"PAYEE NAME"'::jsonb),
  ('pay_payee.pn_hint',          '"As shown in the bank app"'::jsonb),
  ('pay_payee.partner_label',    '"PARTNER"'::jsonb),
  ('pay_payee.save_cta',         '"Save"'::jsonb),
  ('pay_payee.save_active_cta',  '"Save & make active"'::jsonb),
  ('pay_payee.qr_title',         '"Merchant QR read ✓"'::jsonb),
  ('pay_payee.qr_sub',           '"Check the details, then send ₹1 to test it."'::jsonb),
  ('pay_payee.qr_bad_title',     '"That QR is not a UPI payment QR"'::jsonb),
  ('pay_payee.qr_bad_sub',       '"Scan the merchant QR shown inside your bank app."'::jsonb),
  ('pay_payee.row_vpa',          '"UPI ID"'::jsonb),
  ('pay_payee.row_pn',           '"Payee name"'::jsonb),
  ('pay_payee.row_mc',           '"Merchant code"'::jsonb),
  ('pay_payee.row_mc_value',     '"Read from QR"'::jsonb),
  ('pay_payee.row_mc_none',      '"Not in this QR"'::jsonb),
  ('pay_payee.row_type',         '"Type"'::jsonb),
  ('pay_payee.type_business_full','"Business VPA · Pay button ON"'::jsonb),
  ('pay_payee.type_personal_full','"Personal UPI · QR + screenshot"'::jsonb),
  ('pay_payee.test_cta',         '"Send ₹1 test"'::jsonb),
  ('pay_payee.test_waiting',     '"₹1 sent — waiting for the Vyapar alert"'::jsonb),
  ('pay_payee.test_arrived',     '"Vyapar alert arrived — this VPA takes payments"'::jsonb),
  ('pay_payee.test_none',        '"No ₹1 test sent yet"'::jsonb),
  ('pay_payee.warn_title',       '"Make a personal UPI active?"'::jsonb),
  ('pay_payee.warn_head',        '"The Pay button turns off"'::jsonb),
  ('pay_payee.warn_body',        '"Banks can block many payments into a personal UPI. Customers will see a QR and upload a screenshot instead."'::jsonb),
  ('pay_payee.warn_keep',        '"Keep business"'::jsonb),
  ('pay_payee.warn_switch',      '"Switch anyway"'::jsonb),
  ('pay_payee.saved_toast',      '"UPI account saved."'::jsonb),
  ('pay_payee.activated_toast',  '"That UPI account is now active."'::jsonb),
  ('pay_payee.denied',           '"Only a super admin can change where customers pay."'::jsonb)
on conflict (key) do nothing;

-- ── B. Reading a merchant QR, saving an account, the ₹1 test ────────────────
-- The bank's own upi:// string, split into its params. Nothing is typed and
-- nothing is invented: what the bank wrote is what is stored.
-- Percent-decoding the bank's own query string. One hex pass, no guessing.
create or replace function public._c2250_url_decode(p_in text)
returns text language sql immutable set search_path to 'public' as $fn$
  select coalesce((
    select convert_from(decode(string_agg(
             case when length(m[1]) = 1 then encode(convert_to(m[1], 'UTF8'), 'hex')
                  else substring(m[1] from 2) end, ''), 'hex'), 'UTF8')
      from regexp_matches(coalesce(p_in,''), '%[0-9a-fA-F]{2}|.', 'g') as r(m)), coalesce(p_in,''));
$fn$;

create or replace function public.upi_qr_parse(p_qr text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_raw text := btrim(coalesce(p_qr,''));
  v_q   text;
  v_par jsonb := '{}'::jsonb;
  kv    text;
  k     text;
  v     text;
  v_pa  text; v_pn text; v_mc text;
  v_type text;
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_payee.denied',''));
  end if;

  if v_raw = '' or lower(left(v_raw, 10)) <> 'upi://pay?' then
    return jsonb_build_object('ok', false, 'error','not_a_upi_qr',
      'title',   public.uic('pay_payee.qr_bad_title',''),
      'message', public.uic('pay_payee.qr_bad_sub',''));
  end if;

  v_q := substr(v_raw, 11);
  foreach kv in array string_to_array(v_q, '&') loop
    k := lower(btrim(split_part(kv, '=', 1)));
    v := btrim(replace(substr(kv, position('=' in kv) + 1), '+', ' '));
    if k <> '' and v <> '' then
      -- %XX from the bank's own encoding, decoded once.
      begin v := public._c2250_url_decode(v);
      exception when others then null; end;
      v_par := v_par || jsonb_build_object(k, v);
    end if;
  end loop;

  v_pa := btrim(coalesce(v_par->>'pa',''));
  v_pn := btrim(coalesce(v_par->>'pn',''));
  v_mc := btrim(coalesce(v_par->>'mc',''));
  if v_pa = '' or position('@' in v_pa) = 0 then
    return jsonb_build_object('ok', false, 'error','no_vpa',
      'title',   public.uic('pay_payee.qr_bad_title',''),
      'message', public.uic('pay_payee.qr_bad_sub',''));
  end if;

  -- A merchant code is what makes it a business VPA; without one the bank
  -- issued a personal handle, and we say so instead of guessing.
  v_type := case when v_mc <> '' then 'business_vpa' else 'personal' end;

  return jsonb_build_object(
    'ok', true,
    'title',     public.uic('pay_payee.qr_title',''),
    'subtitle',  public.uic('pay_payee.qr_sub',''),
    'pa',        v_pa,
    'pn',        v_pn,
    'mc',        v_mc,
    'account_type', v_type,
    'qr_params', v_par - 'am' - 'tn' - 'tr',
    'qr_raw',    v_raw,
    'rows', jsonb_build_array(
      jsonb_build_object('label', public.uic('pay_payee.row_vpa',''),
                         'value', v_pa, 'ok', true),
      jsonb_build_object('label', public.uic('pay_payee.row_pn',''),
                         'value', coalesce(nullif(v_pn,''), v_pa), 'ok', v_pn <> ''),
      jsonb_build_object('label', public.uic('pay_payee.row_mc',''),
                         'value', case when v_mc <> '' then public.uic('pay_payee.row_mc_value','')
                                       else public.uic('pay_payee.row_mc_none','') end,
                         'ok', v_mc <> ''),
      jsonb_build_object('label', public.uic('pay_payee.row_type',''),
                         'value', case when v_type = 'business_vpa'
                                       then public.uic('pay_payee.type_business_full','')
                                       else public.uic('pay_payee.type_personal_full','') end,
                         'ok', v_type = 'business_vpa')),
    'test_label', public.uic('pay_payee.test_cta',''),
    'save_label', public.uic('pay_payee.save_active_cta',''));
end $fn$;

-- One writer for the whole Add-UPI form: type, merchant params and activation.
create or replace function public.upi_account_save(
  p_pa text, p_pn text, p_account_type text default 'business_vpa',
  p_merchant_code text default null, p_qr_params jsonb default '{}'::jsonb,
  p_qr_raw text default null, p_make_active boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_id uuid; v_first boolean; v_type text;
  v_pa text := btrim(coalesce(p_pa,'')); v_pn text := btrim(coalesce(p_pn,''));
begin
  if not public._is_super() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_payee.denied',''));
  end if;
  if v_pa = '' or position('@' in v_pa) = 0 then
    return jsonb_build_object('ok', false, 'error','invalid_upi',
      'message', public.uic('pay_payee.vpa_hint',''));
  end if;
  if v_pn = '' then
    return jsonb_build_object('ok', false, 'error','invalid_name',
      'message', public.uic('pay_payee.pn_hint',''));
  end if;
  v_type := case when lower(coalesce(p_account_type,'')) = 'personal'
                 then 'personal' else 'business_vpa' end;

  select not exists(select 1 from public.payment_upi_accounts) into v_first;

  insert into public.payment_upi_accounts
    (pa, pn, is_active, created_by, account_type, merchant_code, qr_params, qr_raw)
  values (v_pa, v_pn, false,
          lower(coalesce((select u.email from auth.users u where u.id = auth.uid()), '')),
          v_type, nullif(btrim(coalesce(p_merchant_code,'')),''),
          coalesce(p_qr_params,'{}'::jsonb), nullif(btrim(coalesce(p_qr_raw,'')),''))
  returning id into v_id;

  if coalesce(p_make_active,false) or v_first then
    update public.payment_upi_accounts set is_active = false where is_active;
    update public.payment_upi_accounts set is_active = true where id = v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id,
    'message', public.uic('pay_payee.saved_toast',''),
    'screen',  public.pay_payee_screen());
end $fn$;

-- Making an account active. The personal warning is the BACKEND's decision:
-- confirm=false on a personal account returns the sheet instead of switching.
create or replace function public.upi_make_active(p_id uuid, p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_type text; v_pa text; v_pn text;
begin
  if not public._is_super() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_payee.denied',''));
  end if;
  select account_type, pa, pn into v_type, v_pa, v_pn
    from public.payment_upi_accounts where id = p_id;
  if v_pa is null then
    return jsonb_build_object('ok', false, 'error','not_found');
  end if;

  if v_type = 'personal' and not coalesce(p_confirm,false) then
    return jsonb_build_object('ok', false, 'error','confirm_personal',
      'confirm', jsonb_build_object(
        'title',   public.uic('pay_payee.warn_title',''),
        'subtitle', v_pn || ' · ' || v_pa,
        'warn_title', public.uic('pay_payee.warn_head',''),
        'warn_body',  public.uic('pay_payee.warn_body',''),
        'cancel_label', public.uic('pay_payee.warn_keep',''),
        'confirm_label', public.uic('pay_payee.warn_switch','')));
  end if;

  update public.payment_upi_accounts set is_active = false where is_active;
  update public.payment_upi_accounts set is_active = true  where id = p_id;
  return jsonb_build_object('ok', true,
    'message', public.uic('pay_payee.activated_toast',''),
    'screen',  public.pay_payee_screen());
end $fn$;

-- ₹1 test: the link the admin pays, and — read, never polled — whether an
-- alert for ₹1 has arrived on the partner phone since it was started.
create or replace function public.upi_test_rupee(p_pa text, p_pn text default null, p_mc text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_pa text := btrim(coalesce(p_pa,'')); v_url text; v_since timestamptz;
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_payee.denied',''));
  end if;
  -- No VPA named (the partner-phone button) → the account money arrives into.
  if v_pa = '' then
    select a.pa, a.pn, nullif(btrim(coalesce(a.merchant_code,'')),'')
      into v_pa, p_pn, p_mc
      from public.payment_upi_accounts a where a.is_active
      order by a.created_at desc limit 1;
    v_pa := btrim(coalesce(v_pa,''));
  end if;
  if v_pa = '' then
    return jsonb_build_object('ok', false, 'error','no_vpa',
      'message', public.uic('pay_expected.no_payee','Online payment is not set up yet.'));
  end if;

  v_since := now();
  insert into public.app_settings(key, value)
  values ('pay_upi.test_rupee', jsonb_build_object('at', v_since, 'pa', v_pa))
  on conflict (key) do update set value = excluded.value;

  update public.payment_upi_accounts set test_rupee_at = v_since where pa = v_pa;

  v_url := replace(public.upi_qr_string(v_pa, coalesce(nullif(btrim(coalesce(p_pn,'')),''), v_pa),
                                        1.00, 'mediBO test'), ' ', '%20')
           || case when coalesce(btrim(coalesce(p_mc,'')),'') = '' then ''
                   else '&mc=' || btrim(p_mc) end;

  return jsonb_build_object('ok', true, 'upi_url', v_url,
    'state_label', public.uic('pay_payee.test_waiting',''),
    'state_tone',  'warning');
end $fn$;

-- The state half of the ₹1 test, computed on read from the alerts already
-- stored — no timer, no poll on the server side.
create or replace function public.upi_test_rupee_state()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v jsonb; v_at timestamptz; v_hit uuid;
begin
  select value into v from public.app_settings where key = 'pay_upi.test_rupee';
  v_at := nullif(coalesce(v->>'at',''),'')::timestamptz;
  if v_at is null then
    return jsonb_build_object('started', false,
      'state_label', public.uic('pay_payee.test_none',''), 'state_tone','muted');
  end if;
  select a.id into v_hit from public.payment_alerts a
   where a.posted_at >= v_at and a.parsed_amount = 1.00
   order by a.posted_at asc limit 1;
  return jsonb_build_object(
    'started', true,
    'arrived', v_hit is not null,
    'alert_id', v_hit,
    'state_label', case when v_hit is not null then public.uic('pay_payee.test_arrived','')
                        else public.uic('pay_payee.test_waiting','') end,
    'state_tone',  case when v_hit is not null then 'success' else 'warning' end);
end $fn$;

-- Frame 1 + frame 2's form copy + frame 4's warning: one payload, one screen.
create or replace function public.pay_payee_screen()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_rows jsonb;
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_payee.denied',''));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',           a.id,
           'pa',           a.pa,
           'pn',           a.pn,
           'is_active',    a.is_active,
           'account_type', coalesce(a.account_type,'business_vpa'),
           'type_label',   case when coalesce(a.account_type,'business_vpa') = 'business_vpa'
                                then public.uic('pay_payee.type.business_vpa','')
                                else public.uic('pay_payee.type.personal','') end,
           'pay_label',    case when coalesce(a.account_type,'business_vpa') = 'business_vpa'
                                then public.uic('pay_payee.pay_on','')
                                else public.uic('pay_payee.pay_off','') end,
           'pay_tone',     case when coalesce(a.account_type,'business_vpa') = 'business_vpa'
                                then 'success' else 'warning' end,
           'qr_label',     case when coalesce(nullif(btrim(coalesce(a.merchant_code,'')),''),'') <> ''
                                then public.uic('pay_payee.merchant_qr_ok','')
                                else public.uic('pay_payee.merchant_qr_none','') end,
           'has_merchant', coalesce(nullif(btrim(coalesce(a.merchant_code,'')),''),'') <> '',
           'state_label',  case when a.is_active then public.uic('pay_payee.active','')
                                else public.uic('pay_payee.make_active','') end,
           'is_business',  coalesce(a.account_type,'business_vpa') = 'business_vpa',
           'can_activate', not a.is_active)
         order by a.is_active desc, a.created_at desc), '[]'::jsonb)
    into v_rows from public.payment_upi_accounts a;

  return jsonb_build_object(
    'ok', true,
    'title',         public.uic('pay_payee.title',''),
    'section_label', public.uic('pay_payee.section',''),
    'add_label',     public.uic('pay_payee.add_cta',''),
    'empty_label',   public.uic('pay_payee.empty',''),
    'empty_hint',    public.uic('pay_payee.empty_hint',''),
    'rows',          v_rows,
    'payee',         public.pay_payee_active(),
    'see', jsonb_build_object(
      'title', public.uic('pay_payee.see_title',''),
      'lines', case when coalesce((select account_type from public.payment_upi_accounts
                                    where is_active order by created_at desc limit 1),
                                  'business_vpa') = 'business_vpa'
                    then jsonb_build_array(public.uic('pay_payee.see_business_1',''),
                                           public.uic('pay_payee.see_business_2',''),
                                           public.uic('pay_payee.see_business_3',''))
                    else jsonb_build_array(public.uic('pay_payee.see_personal_1',''),
                                           public.uic('pay_payee.see_personal_2',''),
                                           public.uic('pay_payee.see_personal_3','')) end),
    'form', jsonb_build_object(
      'title',          public.uic('pay_payee.add_title',''),
      'type_label',     public.uic('pay_payee.type_label',''),
      'types', jsonb_build_array(
        jsonb_build_object('key','business_vpa',
          'label', public.uic('pay_payee.type.business_vpa',''),
          'sub',   public.uic('pay_payee.type_business_sub','')),
        jsonb_build_object('key','personal',
          'label', public.uic('pay_payee.type.personal',''),
          'sub',   public.uic('pay_payee.type_personal_sub',''))),
      'scan_label',     public.uic('pay_payee.scan_cta',''),
      'scan_hint',      public.uic('pay_payee.scan_hint',''),
      'or_label',       public.uic('pay_payee.or_type',''),
      'vpa_label',      public.uic('pay_payee.vpa_label',''),
      'vpa_hint',       public.uic('pay_payee.vpa_hint',''),
      'pn_label',       public.uic('pay_payee.pn_label',''),
      'pn_hint',        public.uic('pay_payee.pn_hint',''),
      'partner_label',  public.uic('pay_payee.partner_label',''),
      'partner_value',  coalesce((select partner_name from public.region_partners
                                   where is_active order by id limit 1), ''),
      'save_label',     public.uic('pay_payee.save_cta',''),
      'save_active_label', public.uic('pay_payee.save_active_cta',''),
      'test_label',     public.uic('pay_payee.test_cta','')),
    'test',  public.upi_test_rupee_state());
end $fn$;

-- ── C. Partner phone — Payment alerts (frames 5–6) ──────────────────────────
insert into public.ui_copy(key, value) values
  ('pay_phone.title',        '"Payment alerts"'::jsonb),
  ('pay_phone.ok_title',     '"Listening on this phone"'::jsonb),
  ('pay_phone.ok_sub_tpl',   '"{device} · {zone} · last payment read {when}"'::jsonb),
  ('pay_phone.ok_sub_never', '"{device} · {zone} · no payment read yet"'::jsonb),
  ('pay_phone.off_title',    '"Listening is off on this phone"'::jsonb),
  ('pay_phone.off_sub',      '"Payments won''t verify on their own until notification access is allowed."'::jsonb),
  ('pay_phone.stale_title',  '"This phone stopped reporting"'::jsonb),
  ('pay_phone.stale_sub_tpl','"Last seen {when} · payments won''t verify on their own"'::jsonb),
  ('pay_phone.none_title',   '"No partner phone is registered"'::jsonb),
  ('pay_phone.none_sub',     '"Open mediBO Partner on the shop phone and allow notification access."'::jsonb),
  ('pay_phone.on_phone',     '"ON THIS PHONE"'::jsonb),
  ('pay_phone.read_label',   '"Read payment notifications"'::jsonb),
  ('pay_phone.read_sub_on',  '"Notification access allowed"'::jsonb),
  ('pay_phone.read_sub_off', '"Notification access is not allowed"'::jsonb),
  ('pay_phone.speak_label',  '"Say payments aloud"'::jsonb),
  ('pay_phone.speak_sub_none','"“₹431.64 received, chandra”"'::jsonb),
  ('pay_phone.battery_label','"Battery"'::jsonb),
  ('pay_phone.battery_sub',  '"Unrestricted — keeps listening in the background"'::jsonb),
  ('pay_phone.battery_ok',   '"OK"'::jsonb),
  ('pay_phone.battery_off',  '"Off"'::jsonb),
  ('pay_phone.apps_label',   '"APPS WE READ"'::jsonb),
  ('pay_phone.app_found',    '"Found"'::jsonb),
  ('pay_phone.app_missing',  '"—"'::jsonb),
  ('pay_phone.app_not_here', '"Not on this phone"'::jsonb),
  ('pay_phone.test_cta',     '"Send ₹1 test to Vyapar"'::jsonb),
  ('pay_phone.fix_label',    '"FIX IT IN 3 STEPS"'::jsonb),
  ('pay_phone.fix1',         '"Open mediBO Partner on this phone"'::jsonb),
  ('pay_phone.fix1_sub_tpl', '"Log in as {partner}"'::jsonb),
  ('pay_phone.fix2',         '"Allow notification access"'::jsonb),
  ('pay_phone.fix2_sub',     '"Needed to read Vyapar payments"'::jsonb),
  ('pay_phone.fix3',         '"Battery: Unrestricted"'::jsonb),
  ('pay_phone.fix3_sub',     '"Otherwise the phone stops listening at night"'::jsonb),
  ('pay_phone.step_done',    '"✓"'::jsonb),
  ('pay_phone.step_off',     '"Off"'::jsonb),
  ('pay_phone.settings_cta', '"Open phone settings"'::jsonb),
  ('pay_phone.link_cta',     '"Link this phone to the partner"'::jsonb),
  ('pay_phone.link_done_tpl','"Linked to {partner}"'::jsonb),
  ('pay_phone.linked_toast', '"Phone linked to the partner."'::jsonb),
  ('pay_alert.speak_tpl_order',  '"{amount} received from {sender} for order {order}"'::jsonb),
  ('pay_alert.notify_tpl_order', '"Verified · {order} · {sender}"'::jsonb)
on conflict (key) do nothing;

-- Health is read from last_seen_at when the screen is read. No cron, no timer.
create or replace function public.pay_phone_stale_hours()
returns int language sql stable set search_path to 'public' as $fn$
  select greatest(coalesce(((select value from public.app_settings
                              where key = 'pay_dev.config')->>'stale_hours')::int, 6), 1);
$fn$;

create or replace function public.payment_alert_device_set_partner(
  p_device text, p_partner_id bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_pid bigint; v_zone smallint;
begin
  if not public._pay_dev_allowed() then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  select zone_id into v_zone from public.payment_alert_device where device_id = btrim(coalesce(p_device,''));
  if v_zone is null and btrim(coalesce(p_device,'')) = '' then
    return jsonb_build_object('ok', false, 'error','not_found');
  end if;
  v_pid := p_partner_id;
  if v_pid is null then
    select p.id into v_pid from public.region_partners p
     where (v_zone is null or p.zone_id = v_zone) and p.is_active
     order by p.id limit 1;
  end if;
  update public.payment_alert_device
     set partner_id = v_pid, updated_at = now()
   where device_id = btrim(coalesce(p_device,''));
  return jsonb_build_object('ok', true,
    'message', public.uic('pay_phone.linked_toast',''),
    'phone',   public.pay_partner_phone_screen(p_device));
end $fn$;

create or replace function public.pay_partner_phone_screen(p_device text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  d public.payment_alert_device%rowtype;
  v_zone smallint; v_zname text; v_partner text; v_pid bigint;
  v_stale boolean; v_hours int := public.pay_phone_stale_hours();
  v_listen boolean; v_speak text; v_apps jsonb; v_state text;
  v_seen text; v_alert text;
begin
  if not public._pay_dev_allowed() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_dev.not_authorized',''));
  end if;
  v_zone := coalesce(public.partner_zone_id(), public.admin_active_zone());

  select * into d from public.payment_alert_device
   where (btrim(coalesce(p_device,'')) <> '' and device_id = btrim(p_device))
      or (btrim(coalesce(p_device,'')) =  '' and (v_zone is null or zone_id = v_zone))
   order by (device_id = btrim(coalesce(p_device,''))) desc, last_seen_at desc nulls last
   limit 1;

  select z.name into v_zname from public.zones z where z.id = coalesce(d.zone_id, v_zone);
  select p.id, p.partner_name into v_pid, v_partner from public.region_partners p
   where (coalesce(d.zone_id, v_zone) is null or p.zone_id = coalesce(d.zone_id, v_zone))
     and p.is_active order by p.id limit 1;

  v_listen := coalesce(d.listener_enabled, false);
  v_stale  := d.device_id is null
              or d.last_seen_at is null
              or d.last_seen_at < now() - make_interval(hours => v_hours);
  v_state  := case when d.device_id is null then 'none'
                   when v_stale then 'stale'
                   when not v_listen then 'off'
                   else 'ok' end;

  v_seen  := case when d.last_seen_at is null then ''
                  else to_char(d.last_seen_at at time zone 'Asia/Kolkata','DD Mon') end;
  v_alert := case when d.last_alert_at is null then ''
                  else to_char(d.last_alert_at at time zone 'Asia/Kolkata','hh12:mi am') end;

  -- The apps: every rule we listen for, and whether this phone has ever sent
  -- one. Vyapar (business) first — the order is the rules table's own.
  select coalesce(jsonb_agg(jsonb_build_object(
           'label',   coalesce(nullif(btrim(r.label),''), r.package_name),
           'package', r.package_name,
           'sub',     case when r.seen_n > 0
                           then coalesce(nullif(btrim(r.payee),''), r.package_name)
                           else public.uic('pay_phone.app_not_here','') end,
           'found',   r.seen_n > 0,
           'chip',    case when r.seen_n > 0 then public.uic('pay_phone.app_found','')
                           else public.uic('pay_phone.app_missing','') end,
           'chip_tone', case when r.seen_n > 0 then 'success' else 'muted' end)
         order by r.ord, r.priority, lower(coalesce(r.label, r.package_name))), '[]'::jsonb)
    into v_apps
  from (
    select x.label, x.package_name, x.priority,
           case coalesce(x.app_kind,'consumer')
             when 'business' then 0 when 'bank' then 1 else 2 end as ord,
           (select count(*) from public.payment_alerts a
             where a.package_name = x.package_name
               and (d.device_id is null or a.device_id = d.device_id)) as seen_n,
           (select coalesce(nullif(btrim(u.pn),'') || ' · ' || u.pa, u.pa)
              from public.payment_upi_accounts u where u.is_active
              order by u.created_at desc limit 1) as payee
      from public.payment_alert_rules x
     where x.package_name <> '*' and x.enabled
  ) r;

  select coalesce(nullif(s.message,''), public.uic('pay_phone.speak_sub_none',''))
    into v_speak
  from public.payment_alert_speak s
  where (d.device_id is null or s.zone_id is not distinct from d.zone_id)
  order by s.created_at desc limit 1;

  return jsonb_build_object(
    'ok', true,
    'title', public.uic('pay_phone.title',''),
    'state', v_state,
    'device_id', d.device_id,
    'partner_id', d.partner_id,
    'banner', jsonb_build_object(
      'tone',  case v_state when 'ok' then 'success' when 'none' then 'warning' else 'danger' end,
      'title', case v_state
                 when 'ok'   then public.uic('pay_phone.ok_title','')
                 when 'off'  then public.uic('pay_phone.off_title','')
                 when 'none' then public.uic('pay_phone.none_title','')
                 else public.uic('pay_phone.stale_title','') end,
      'body',  case v_state
                 when 'ok' then replace(replace(replace(
                     case when v_alert = '' then public.uic('pay_phone.ok_sub_never','')
                          else public.uic('pay_phone.ok_sub_tpl','') end,
                     '{device}', coalesce(nullif(btrim(coalesce(d.label,'')),''), coalesce(d.device_id,''))),
                     '{zone}', coalesce(v_zname,'')), '{when}', v_alert)
                 when 'off'  then public.uic('pay_phone.off_sub','')
                 when 'none' then public.uic('pay_phone.none_sub','')
                 else replace(public.uic('pay_phone.stale_sub_tpl',''), '{when}', coalesce(nullif(v_seen,''),'—')) end),
    'settings_label', public.uic('pay_phone.settings_cta',''),
    'test_label',     public.uic('pay_phone.test_cta',''),
    'link_label',     case when d.device_id is null then ''
                           when d.partner_id is null then public.uic('pay_phone.link_cta','')
                           else replace(public.uic('pay_phone.link_done_tpl',''),
                                        '{partner}', coalesce(v_partner,'')) end,
    'can_link',       d.device_id is not null and d.partner_id is null,
    'partner_name',   coalesce(v_partner,''),
    'phone_label',    public.uic('pay_phone.on_phone',''),
    'toggles', jsonb_build_array(
      jsonb_build_object('key','listener',
        'label', public.uic('pay_phone.read_label',''),
        'sub',   case when v_listen then public.uic('pay_phone.read_sub_on','')
                      else public.uic('pay_phone.read_sub_off','') end,
        'on',    v_listen, 'kind','switch'),
      jsonb_build_object('key','speak',
        'label', public.uic('pay_phone.speak_label',''),
        'sub',   coalesce(v_speak, public.uic('pay_phone.speak_sub_none','')),
        'on',    coalesce(d.speak_enabled, true), 'kind','switch'),
      jsonb_build_object('key','battery',
        'label', public.uic('pay_phone.battery_label',''),
        'sub',   public.uic('pay_phone.battery_sub',''),
        'on',    not v_stale, 'kind','chip',
        'chip',  case when v_stale then public.uic('pay_phone.battery_off','')
                      else public.uic('pay_phone.battery_ok','') end,
        'chip_tone', case when v_stale then 'warning' else 'success' end)),
    'apps_label', public.uic('pay_phone.apps_label',''),
    'apps',       coalesce(v_apps,'[]'::jsonb),
    'fix_label',  public.uic('pay_phone.fix_label',''),
    'fix', case when v_state in ('ok') then '[]'::jsonb else jsonb_build_array(
      jsonb_build_object('n', 1, 'label', public.uic('pay_phone.fix1',''),
        'sub',  replace(public.uic('pay_phone.fix1_sub_tpl',''), '{partner}', coalesce(v_partner,'')),
        'done', d.device_id is not null,
        'chip', case when d.device_id is not null then public.uic('pay_phone.step_done','')
                     else public.uic('pay_phone.step_off','') end),
      jsonb_build_object('n', 2, 'label', public.uic('pay_phone.fix2',''),
        'sub',  public.uic('pay_phone.fix2_sub',''),
        'done', v_listen,
        'chip', case when v_listen then public.uic('pay_phone.step_done','')
                     else public.uic('pay_phone.step_off','') end),
      jsonb_build_object('n', 3, 'label', public.uic('pay_phone.fix3',''),
        'sub',  public.uic('pay_phone.fix3_sub',''),
        'done', not v_stale,
        'chip', case when not v_stale then public.uic('pay_phone.step_done','')
                     else public.uic('pay_phone.step_off','') end)) end,
    'zone_id', coalesce(d.zone_id, v_zone));
end $fn$;

-- The spoken line names the customer AND the order once matching knows them.
create or replace function public._pa_speak_enrich(p_alert_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare a public.payment_alerts%rowtype; v_code text; v_sender text;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null or a.matched_order_id is null then return; end if;
  select coalesce(nullif(btrim(o.order_code),''), '') into v_code
    from public.orders o where o.id = a.matched_order_id;
  if coalesce(v_code,'') = '' then return; end if;
  select coalesce(nullif(btrim(pp.pharmacy_name),''), '') into v_sender
    from public.pharmacy_profiles pp where pp.id = a.matched_customer_id;
  v_sender := coalesce(nullif(v_sender,''), nullif(a.parsed_sender,''), nullif(a.parsed_vpa,''), '');

  update public.payment_alert_speak s
     set order_id     = a.matched_order_id,
         customer_id  = coalesce(a.matched_customer_id, s.customer_id),
         message      = replace(replace(replace(
                          public.uic('pay_alert.speak_tpl_order',''),
                          '{amount}', public.inr_money_compact(a.parsed_amount)),
                          '{sender}', v_sender), '{order}', v_code),
         notify_body  = replace(replace(
                          public.uic('pay_alert.notify_tpl_order',''),
                          '{order}', v_code), '{sender}', v_sender)
   where s.alert_id = a.id and s.spoken_at is null;
end $fn$;

-- ── D. Alerts: outcome chips, detail rows, actions, Undo (frames 33–37) ─────
alter table public.payment_alerts
  add column if not exists match_how text;

create table if not exists public.payment_alert_outcome (
  how_key    text primary key,
  chip_label text not null,
  ord        int  not null default 50
);

insert into public.payment_alert_outcome(how_key, chip_label, ord) values
  ('pay_expected.match.order_ref',    'order no.',   10),
  ('pay_expected.match.known_sender', 'known payer', 20),
  ('pay_expected.match.customer_vpa', 'known payer', 21),
  ('pay_expected.match.customer_name','name',        30),
  ('pay_alert.match.utr_full',        'ref',         40),
  ('pay_alert.match.utr_suffix',      'ref',         41),
  ('pay_alert.match.amount_vpa',      'known payer', 22),
  ('pay_alert.match.sender_bill',     'known payer', 23),
  ('pay_alert.match.customer_reply',  'reply',       50),
  ('pay_alert.match.manual',          'linked',      60)
on conflict (how_key) do nothing;

insert into public.ui_copy(key, value) values
  ('pay_alert.outcome.verified',     '"Verified"'::jsonb),
  ('pay_alert.outcome.verified_tpl', '"Verified · {how}"'::jsonb),
  ('pay_alert.outcome.waiting',      '"Waiting"'::jsonb),
  ('pay_alert.outcome.not_matched',  '"Not matched"'::jsonb),
  ('pay_alert.outcome.ignored',      '"Not a mediBO payment"'::jsonb),
  ('pay_alert.filter.verified',      '"Verified"'::jsonb),
  ('pay_alert.filter.waiting',       '"Waiting"'::jsonb),
  ('pay_alert.filter.not_matched',   '"Not matched"'::jsonb),
  ('pay_alert.sub.verified_tpl',     '"Verified automatically at {when}"'::jsonb),
  ('pay_alert.sub.waiting_tpl',      '"Waiting for {who} · asked on WhatsApp at {when}"'::jsonb),
  ('pay_alert.sub.waiting_plain',    '"Waiting for the customer to confirm"'::jsonb),
  ('pay_alert.sub.not_matched_tpl',  '"Not matched · {when}"'::jsonb),
  ('pay_alert.row.payer',            '"Payer"'::jsonb),
  ('pay_alert.row.order',            '"Order"'::jsonb),
  ('pay_alert.row.looks_like',       '"Looks like"'::jsonb),
  ('pay_alert.row.why',              '"Why"'::jsonb),
  ('pay_alert.row.writeoff',         '"Written off"'::jsonb),
  ('pay_alert.row.reply_hint',       '"If {who} replies 1"'::jsonb),
  ('pay_alert.reply_hint_tpl',       '"Verified and {payer} is remembered as {who}''s payer"'::jsonb),
  ('pay_alert.payer_unknown_tpl',    '"{payer} (not known yet)"'::jsonb),
  ('pay_alert.act.open_order',       '"Open order"'::jsonb),
  ('pay_alert.act.undo',             '"Undo"'::jsonb),
  ('pay_alert.act.verify_now',       '"Verify now"'::jsonb),
  ('pay_alert.act.not_this_order',   '"Not this order"'::jsonb),
  ('pay_alert.act.link',             '"Link to an order"'::jsonb),
  ('pay_alert.act.not_medibo',       '"Not a mediBO payment"'::jsonb),
  ('pay_alert.undo_done',            '"Undone — the payment is open again."'::jsonb),
  ('pay_alert.verify_done',          '"Verified."'::jsonb),
  ('pay_alert.not_this_done',        '"Left open — it is not this order."'::jsonb),
  ('pay_alert.act_denied',           '"Only a partner or an admin can act on a payment alert."'::jsonb),
  ('pay_alert.act_bad',              '"That action is not available on this alert."'::jsonb)
on conflict (key) do nothing;

-- match_how is the KEY behind match_reason. Filled on write so nothing has to
-- reverse-engineer a sentence later; the expected payment already stores it.
create or replace function public._c2250_alert_how()
returns trigger language plpgsql set search_path to 'public' as $fn$
begin
  if tg_op = 'UPDATE' and new.match_reason is not distinct from old.match_reason then
    return new;
  end if;
  new.match_how := coalesce(
    (select x.match_reason from public.payment_expected x
      where x.alert_id = new.id and nullif(x.match_reason,'') is not null
        and x.match_reason <> 'asked_customer'
      order by x.paid_at desc nulls last limit 1),
    (select k.key from public.ui_copy k
      where k.value #>> '{}' = new.match_reason
        and (k.key like 'pay_alert.match.%' or k.key like 'pay_expected.match.%')
      limit 1));
  return new;
end $fn$;

drop trigger if exists trg_c2250_alert_how on public.payment_alerts;
create trigger trg_c2250_alert_how
  before insert or update of match_reason on public.payment_alerts
  for each row execute function public._c2250_alert_how();

update public.payment_alerts a
   set match_reason = a.match_reason
 where a.match_how is null and a.match_reason is not null;

-- The one place an alert's outcome is decided. status + the open question,
-- never a client-side OR.
create or replace function public.payment_alert_outcome(p_alert_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare a public.payment_alerts%rowtype; v_how text; v_asked boolean;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return jsonb_build_object('key','', 'label','', 'tone','muted'); end if;
  select exists(select 1 from public.payment_alert_question q
                 where q.alert_id = a.id and q.status = 'open') into v_asked;
  select o.chip_label into v_how from public.payment_alert_outcome o where o.how_key = a.match_how;

  if a.status = 'matched' then
    return jsonb_build_object('key','verified', 'tone','success',
      'label', case when coalesce(v_how,'') = ''
                    then public.uic('pay_alert.outcome.verified','')
                    else replace(public.uic('pay_alert.outcome.verified_tpl',''), '{how}', v_how) end);
  elsif a.status = 'ignored' then
    return jsonb_build_object('key','ignored', 'tone','muted',
      'label', public.uic('pay_alert.outcome.ignored',''));
  elsif v_asked or a.status = 'new' then
    return jsonb_build_object('key','waiting', 'tone','info',
      'label', public.uic('pay_alert.outcome.waiting',''));
  end if;
  return jsonb_build_object('key','not_matched', 'tone','warning',
    'label', public.uic('pay_alert.outcome.not_matched',''));
end $fn$;

create or replace function public.payment_alert_state(p_alert_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  a public.payment_alerts%rowtype; v_rule text; v_cust text; v_code text;
  v_out jsonb; v_q public.payment_alert_question%rowtype; e public.payment_expected%rowtype;
  v_payer text; v_rows jsonb; v_acts jsonb; v_sub text; v_when text; v_writeoff numeric;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.uic('pay_alert.not_found','That payment alert is gone.'));
  end if;

  select coalesce(label, package_name) into v_rule
    from public.payment_alert_rules where id = a.parse_rule_id;
  select coalesce(nullif(btrim(pp.pharmacy_name),''), '') into v_cust
    from public.pharmacy_profiles pp where pp.id = a.matched_customer_id;
  select coalesce(nullif(btrim(o.order_code),''),
                  'PO-'||upper(right(replace(o.id::text,'-',''),4)))
    into v_code from public.orders o where o.id = a.matched_order_id;
  select * into v_q from public.payment_alert_question
   where alert_id = a.id order by asked_at desc nulls last limit 1;
  select * into e from public.payment_expected
   where alert_id = a.id order by created_at desc limit 1;

  v_out  := public.payment_alert_outcome(a.id);
  v_when := to_char(coalesce(a.updated_at, a.posted_at) at time zone 'Asia/Kolkata','hh12:mi am');
  v_payer := coalesce(nullif(a.parsed_sender,''), nullif(a.parsed_vpa,''),
                      public.uic('pay_alert.no_sender','Sender not named'));
  v_writeoff := coalesce(e.writeoff, 0);

  v_sub := case v_out->>'key'
    when 'verified' then replace(public.uic('pay_alert.sub.verified_tpl',''), '{when}', v_when)
    when 'waiting'  then case when v_q.id is not null and v_q.status = 'open'
                              then replace(replace(public.uic('pay_alert.sub.waiting_tpl',''),
                                     '{who}', coalesce(nullif(v_cust,''), v_payer)),
                                     '{when}', to_char(v_q.asked_at at time zone 'Asia/Kolkata','hh12:mi am'))
                              else public.uic('pay_alert.sub.waiting_plain','') end
    else replace(public.uic('pay_alert.sub.not_matched_tpl',''), '{when}',
                 to_char(a.posted_at at time zone 'Asia/Kolkata','hh12:mi am')) end;

  v_rows := jsonb_build_array(
    jsonb_build_object('label', public.uic('pay_alert.row.payer',''),
      'value', case when v_out->>'key' = 'waiting' and coalesce(v_cust,'') = ''
                    then replace(public.uic('pay_alert.payer_unknown_tpl',''), '{payer}', v_payer)
                    else v_payer end));

  if a.matched_order_id is not null then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'label', case when v_out->>'key' = 'waiting' then public.uic('pay_alert.row.looks_like','')
                    else public.uic('pay_alert.row.order','') end,
      'value', coalesce(v_code,'')
               || case when coalesce(v_cust,'') <> '' then ' · ' || v_cust else '' end
               || case when e.part is not null then ' · ' || e.part else '' end
               || case when v_writeoff > 0 then ' · ' || public.inr_money(coalesce(e.amount, a.parsed_amount))
                                                || ' · ' || replace(public.uic('pay_expected.writeoff_note','paid {n} paisa less'),
                                                                    '{n}', round(v_writeoff*100)::text)
                       else '' end));
  end if;

  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'label', public.uic('pay_alert.row.why',''),
    'value', coalesce(nullif(a.match_reason,''), nullif(a.parse_note,''), '')));

  if v_out->>'key' = 'waiting' and v_q.id is not null and v_q.status = 'open' then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'label', replace(public.uic('pay_alert.row.reply_hint',''), '{who}', coalesce(nullif(v_cust,''), v_payer)),
      'value', replace(replace(public.uic('pay_alert.reply_hint_tpl',''),
                 '{payer}', v_payer), '{who}', coalesce(nullif(v_cust,''), v_payer))));
  else
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'label', public.uic('pay_alert.row.writeoff',''),
      'value', public.inr_money(v_writeoff)));
  end if;

  v_acts := case v_out->>'key'
    when 'verified' then jsonb_build_array(
      jsonb_build_object('key','open_order','label', public.uic('pay_alert.act.open_order',''),
                         'tone','primary_outline','order_id', a.matched_order_id),
      jsonb_build_object('key','undo','label', public.uic('pay_alert.act.undo',''), 'tone','muted'))
    when 'waiting' then jsonb_build_array(
      jsonb_build_object('key','verify_now','label', public.uic('pay_alert.act.verify_now',''), 'tone','primary'),
      jsonb_build_object('key','not_this_order','label', public.uic('pay_alert.act.not_this_order',''), 'tone','muted'))
    when 'ignored' then jsonb_build_array(
      jsonb_build_object('key','link','label', public.uic('pay_alert.act.link',''), 'tone','primary_outline'))
    else jsonb_build_array(
      jsonb_build_object('key','link','label', public.uic('pay_alert.act.link',''), 'tone','primary_outline'),
      jsonb_build_object('key','not_medibo','label', public.uic('pay_alert.act.not_medibo',''), 'tone','muted'))
    end;

  return jsonb_build_object(
    'ok', true,
    'alert_id',      a.id,
    'status',        a.status,
    'status_label',  public.uic('pay_alert.status.'||a.status, initcap(a.status)),
    'status_tone',   case a.status when 'matched' then 'success'
                                   when 'unmatched' then 'warning'
                                   when 'ignored' then 'muted'
                                   else 'info' end,
    'outcome',       v_out,
    'outcome_label', v_out->>'label',
    'outcome_key',   v_out->>'key',
    'outcome_tone',  v_out->>'tone',
    'subtitle',      v_sub,
    'rows',          v_rows,
    'actions',       v_acts,
    'source',        a.parse_source,
    'source_label',  public.uic('pay_alert.source.'||a.parse_source, a.parse_source),
    'rule_label',    coalesce(v_rule, ''),
    'app_label',     coalesce(v_rule, a.package_name),
    'amount',        a.parsed_amount,
    'amount_label',  case when a.parsed_amount is null
                          then public.uic('pay_alert.no_amount','No amount read')
                          else public.inr_money(a.parsed_amount) end,
    'utr_label',     coalesce(nullif(a.parsed_utr,''),
                              public.uic('pay_alert.no_utr','No UTR in the notification')),
    'has_utr',       nullif(a.parsed_utr,'') is not null,
    'sender_label',  v_payer,
    'vpa',           coalesce(a.parsed_vpa,''),
    'raw_title',     coalesce(a.raw_title,''),
    'raw_text',      coalesce(a.raw_text,''),
    'posted_label',  to_char(a.posted_at at time zone 'Asia/Kolkata','DD Mon, hh12:mi am'),
    'time_label',    to_char(a.posted_at at time zone 'Asia/Kolkata','hh12:mi am'),
    'list_sub',      to_char(a.posted_at at time zone 'Asia/Kolkata','hh12:mi am')
                     || case when coalesce(v_code,'') <> '' then ' · ' || v_code
                             when coalesce(nullif(a.match_reason,''),'') <> '' then ' · ' || a.match_reason
                             else '' end,
    'match_reason',  coalesce(a.match_reason, a.parse_note, ''),
    'match_how',     coalesce(a.match_how,''),
    'writeoff',      v_writeoff,
    'writeoff_label',public.inr_money(v_writeoff),
    'retry_match_label', case when a.status = 'matched' then ''
                              else public.uic('pay_alert.retry_match','Match again') end,
    'ignore_label',      case when a.status = 'matched' then ''
                              else public.uic('pay_alert.ignore','Ignore') end,
    'link_label',        case when a.status = 'matched' then ''
                              else public.uic('pay_alert.link_label','Link to an order') end,
    'claim_id',      a.matched_claim_id,
    'order_id',      a.matched_order_id,
    'order_code',    coalesce(v_code,''),
    'customer_id',   a.matched_customer_id,
    'customer_label',coalesce(nullif(v_cust,''), ''),
    'expected_id',   e.id,
    'zone_id',       a.zone_id,
    'business_date', a.business_date);
end $fn$;

-- One writer for every button the detail sheet shows.
create or replace function public.payment_alert_act(
  p_alert_id uuid, p_action text, p_claim_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  a public.payment_alerts%rowtype; e public.payment_expected%rowtype;
  v_act text := lower(btrim(coalesce(p_action,''))); v_res jsonb;
begin
  if auth.uid() is null or not (coalesce(public.is_partner(),false)
        or coalesce(public.get_my_role(),'') in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_alert.act_denied',''));
  end if;
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.uic('pay_alert.not_found','That payment alert is gone.'));
  end if;
  select * into e from public.payment_expected
   where alert_id = a.id order by created_at desc limit 1;

  if v_act = 'verify_now' then
    if e.id is null or e.status <> 'open' then
      return jsonb_build_object('ok', false, 'error','nothing_to_verify',
        'message', public.uic('pay_alert.act_bad',''));
    end if;
    v_res := public._pay_expected_settle(e.id, a.id, 'pay_alert.match.manual');
    if v_res is null then
      return jsonb_build_object('ok', false, 'error','verify_failed',
        'message', public.uic('pay_alert.act_bad',''));
    end if;
    update public.payment_alert_question
       set status = 'answered', answered_at = now(), chosen_order_id = e.order_id
     where alert_id = a.id and status = 'open';
    perform public._pa_speak_enrich(a.id);
    return public.payment_alert_state(a.id)
           || jsonb_build_object('message', public.uic('pay_alert.verify_done',''));

  elsif v_act = 'not_this_order' then
    update public.payment_alert_question
       set status = 'closed', answered_at = now()
     where alert_id = a.id and status = 'open';
    if e.id is not null then
      update public.payment_expected set alert_id = null, match_reason = null where id = e.id;
    end if;
    update public.payment_alerts
       set status = 'unmatched', matched_order_id = null, matched_customer_id = null,
           match_reason = public.uic('pay_alert.unmatched.none',''), updated_at = now()
     where id = a.id;
    return public.payment_alert_state(a.id)
           || jsonb_build_object('message', public.uic('pay_alert.not_this_done',''));

  elsif v_act = 'not_medibo' then
    return public.payment_alert_set_status(a.id, 'ignored');

  elsif v_act = 'link' then
    if p_claim_id is null then
      return public.payment_alert_link_options(a.id, 20);
    end if;
    return public.payment_alert_link(a.id, p_claim_id);

  elsif v_act = 'undo' then
    -- Reject the claim the auto-match created and reopen the expected payment.
    if a.matched_claim_id is not null then
      update public.payment_claims
         set status = 'rejected',
             verify_reason = public.uic('pay_alert.undo_done',''),
             autolink_note = coalesce(autolink_note,'') || ' undo:c2250'
       where id = a.matched_claim_id;
    end if;
    if e.id is not null then
      update public.payment_expected
         set status = case when e.expires_at > now() then 'open' else 'expired' end,
             paid_at = null, claim_id = null, alert_id = null, match_reason = null
       where id = e.id;
    end if;
    update public.payment_alerts
       set status = 'unmatched', matched_claim_id = null, matched_order_id = null,
           matched_customer_id = null, match_how = null,
           match_reason = public.uic('pay_alert.unmatched.none',''), updated_at = now()
     where id = a.id;
    delete from public.payment_alert_speak where alert_id = a.id and spoken_at is null;
    return public.payment_alert_state(a.id)
           || jsonb_build_object('message', public.uic('pay_alert.undo_done',''));
  end if;

  return jsonb_build_object('ok', false, 'error','bad_action',
    'message', public.uic('pay_alert.act_bad',''));
end $fn$;

-- ── E. The alerts list (frame 34) — outcome filters, phone block on top ─────
create or replace function public._c2250_alert_outcome_key(a public.payment_alerts)
returns text language sql stable set search_path to 'public' as $fn$
  select case
    when a.status = 'matched' then 'verified'
    when a.status = 'ignored' then 'ignored'
    when a.status = 'new' or exists (select 1 from public.payment_alert_question q
                                      where q.alert_id = a.id and q.status = 'open')
      then 'waiting'
    else 'not_matched' end;
$fn$;

create or replace function public.payment_alerts_screen(p_status text default null, p_limit integer default 60)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_role  text := coalesce(public.get_my_role(),'');
  v_part  boolean := coalesce(public.is_partner(), false);
  v_zone  smallint; v_date date; v_rows jsonb; v_counts jsonb; v_total int;
  v_lim   int := least(greatest(coalesce(p_limit,60),1), 200);
  v_f     text := nullif(btrim(lower(coalesce(p_status,''))),'');
begin
  if auth.uid() is null or not (v_part or v_role in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_alert.screen_denied',
                            'Payment alerts are visible to a partner or an admin.'));
  end if;
  -- Legacy status keys still resolve, so an old link never lands on an empty list.
  v_f := case v_f when 'matched' then 'verified' when 'new' then 'waiting'
                  when 'unmatched' then 'not_matched' else v_f end;
  if v_f is not null and v_f not in ('verified','waiting','not_matched','ignored') then
    v_f := null;
  end if;

  v_zone := public.admin_active_zone();
  v_date := public.admin_active_date();

  select coalesce(jsonb_agg(public.payment_alert_state(x.id) order by x.posted_at desc), '[]'::jsonb),
         count(*)::int
    into v_rows, v_total
  from (
    select a.id, a.posted_at from public.payment_alerts a
     where (v_zone is null or a.zone_id = v_zone)
       and (v_date is null or a.business_date = v_date)
       and (v_f is null or public._c2250_alert_outcome_key(a) = v_f)
     order by a.posted_at desc
     limit v_lim
  ) x;

  select coalesce(jsonb_object_agg(s, n), '{}'::jsonb) into v_counts
    from (select public._c2250_alert_outcome_key(a) as s, count(*)::int as n
            from public.payment_alerts a
           where (v_zone is null or a.zone_id = v_zone)
             and (v_date is null or a.business_date = v_date)
           group by 1) q;

  return jsonb_build_object(
    'ok', true,
    'title',        public.uic('pay_alert.title','Payment alerts'),
    'subtitle',     public.uic('pay_alert.subtitle',
                      'Payment notifications forwarded from the partner phone'),
    'empty_label',  public.uic('pay_alert.empty',
                      'No payment notifications for this zone and date yet.'),
    'empty_hint',   public.uic('pay_alert.empty_hint',
                      'Alerts appear here the moment the partner phone forwards one.'),
    'retry_label',  public.uic('pay_alert.error_retry','Retry'),
    'count_label',  case
                      when v_total = 0 then public.uic('pay_alert.count_zero','No alerts')
                      when v_total = 1 then public.uic('pay_alert.count_one','1 alert')
                      else replace(public.uic('pay_alert.count_tpl','{n} alerts'),
                                   '{n}', v_total::text) end,
    'filters',      (select jsonb_agg(jsonb_build_object(
                        'key', f.key, 'label', f.label, 'count', f.n,
                        'chip_label', replace(replace(
                           public.uic('pay_alert.filter.chip_tpl','{label} {count}'),
                           '{label}', f.label), '{count}', f.n::text))
                       order by f.ord)
                     from (
                       select 0 as ord, '' as key,
                              public.uic('pay_alert.filter.all','All') as label,
                              (select coalesce(sum((value)::int),0) from jsonb_each_text(v_counts)) as n
                       union all select 1, 'verified',    public.uic('pay_alert.filter.verified',''),    coalesce((v_counts->>'verified')::int,0)
                       union all select 2, 'waiting',     public.uic('pay_alert.filter.waiting',''),     coalesce((v_counts->>'waiting')::int,0)
                       union all select 3, 'not_matched', public.uic('pay_alert.filter.not_matched',''), coalesce((v_counts->>'not_matched')::int,0)
                     ) f),
    'active_filter', coalesce(v_f,''),
    'zone_id',       v_zone,
    'date',          v_date,
    'phone',         public.pay_partner_phone_screen(null),
    'header',        public._pa_header_block(),
    'utr',           public._pa_utr_block(),
    'apps',          public._pa_apps_block(),
    'rows',          coalesce(v_rows,'[]'::jsonb));
end $fn$;

-- ── F. Payments to check (frame 42) ─────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('pay_check.title',       '"UPI payments to check"'::jsonb),
  ('pay_check.section_tpl', '"WAITING · {n}"'::jsonb),
  ('pay_check.empty',       '"Nothing is waiting to be checked."'::jsonb),
  ('pay_check.empty_hint',  '"Payments the app could not verify by itself land here."'::jsonb),
  ('pay_check.hint',        '"Match the UPI ref in the Vyapar / bank app, then Verify. Reject asks the customer to pay again."'::jsonb),
  ('pay_check.verify',      '"Verify"'::jsonb),
  ('pay_check.reject',      '"Reject"'::jsonb),
  ('pay_check.src.website', '"website"'::jsonb),
  ('pay_check.src.android', '"Android app"'::jsonb),
  ('pay_check.src.alert',   '"Vyapar alert"'::jsonb),
  ('pay_check.ref_tpl',     '"UPI ref {ref} · {when}"'::jsonb),
  ('pay_check.noref_tpl',   '"No UPI ref · {when}"'::jsonb),
  ('pay_check.app_said_tpl','"UPI app said {status} · ref {ref}"'::jsonb),
  ('pay_check.verified_toast','"Payment verified."'::jsonb),
  ('pay_check.rejected_toast','"Rejected — the customer is asked to pay again."'::jsonb),
  ('pay_check.denied',      '"Only a partner or an admin can check payments."'::jsonb)
on conflict (key) do nothing;

create or replace function public.payments_to_check_screen(p_limit integer default 60)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_zone smallint; v_date date; v_rows jsonb; v_n int;
  v_lim int := least(greatest(coalesce(p_limit,60),1), 200);
begin
  if auth.uid() is null or not (coalesce(public.is_partner(),false)
        or coalesce(public.get_my_role(),'') in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_check.denied',''));
  end if;
  v_zone := coalesce(public.partner_zone_id(), public.admin_active_zone());
  v_date := public.admin_active_date();

  with claims as (
    select 'expected'::text as kind, e.id as id, e.order_id, e.order_code, e.customer_id,
           e.amount, e.part, e.client_surface as surface, e.client_utr as utr,
           e.client_status as app_status, coalesce(e.client_at, e.created_at) as at
      from public.payment_expected e
     where e.status = 'open'
       and coalesce(e.client_status,'') <> ''
       and (v_zone is null or e.zone_id = v_zone)
  ), alerts as (
    select 'alert'::text as kind, a.id, a.matched_order_id as order_id,
           null::text as order_code, a.matched_customer_id as customer_id,
           a.parsed_amount as amount, null::text as part, 'alert'::text as surface,
           a.parsed_utr as utr, null::text as app_status, a.posted_at as at
      from public.payment_alerts a
     where public._c2250_alert_outcome_key(a) in ('waiting','not_matched')
       and (v_zone is null or a.zone_id = v_zone)
       and (v_date is null or a.business_date = v_date)
  ), all_rows as (select * from claims union all select * from alerts)
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind',        r.kind,
           'id',          r.id,
           'order_id',    r.order_id,
           'title',       coalesce(nullif(btrim(pp.pharmacy_name),''),
                                   public.uic('pay_alert.no_sender','Sender not named'))
                          || ' · ' || public.inr_money(r.amount),
           'amount_label',public.inr_money(r.amount),
           'customer_label', coalesce(nullif(btrim(pp.pharmacy_name),''), ''),
           'sub1',        coalesce(nullif(r.order_code,''),
                            (select coalesce(nullif(btrim(o.order_code),''),'') from public.orders o where o.id = r.order_id), '')
                          || case when r.part is not null then ' · ' || r.part else '' end
                          || ' · ' || case r.surface
                                        when 'web' then public.uic('pay_check.src.website','')
                                        when 'website' then public.uic('pay_check.src.website','')
                                        when 'android' then public.uic('pay_check.src.android','')
                                        else public.uic('pay_check.src.alert','') end,
           'sub2',        case
                            when coalesce(r.app_status,'') <> '' then
                              replace(replace(public.uic('pay_check.app_said_tpl',''),
                                '{status}', upper(r.app_status)), '{ref}', coalesce(nullif(r.utr,''),'—'))
                            when coalesce(r.utr,'') <> '' then
                              replace(replace(public.uic('pay_check.ref_tpl',''),
                                '{ref}', r.utr), '{when}', to_char(r.at at time zone 'Asia/Kolkata','hh12:mi am'))
                            else replace(public.uic('pay_check.noref_tpl',''),
                                '{when}', to_char(r.at at time zone 'Asia/Kolkata','hh12:mi am')) end,
           'verify_label', public.uic('pay_check.verify',''),
           'reject_label', public.uic('pay_check.reject',''))
         order by r.at desc), '[]'::jsonb), count(*)::int
    into v_rows, v_n
  from (select * from all_rows order by at desc limit v_lim) r
  left join public.pharmacy_profiles pp on pp.id = r.customer_id;

  return jsonb_build_object(
    'ok', true,
    'title',        public.uic('pay_check.title',''),
    'section_label',replace(public.uic('pay_check.section_tpl',''), '{n}', coalesce(v_n,0)::text),
    'hint',         public.uic('pay_check.hint',''),
    'empty_label',  public.uic('pay_check.empty',''),
    'empty_hint',   public.uic('pay_check.empty_hint',''),
    'count',        coalesce(v_n,0),
    'zone_id',      v_zone,
    'rows',         coalesce(v_rows,'[]'::jsonb));
end $fn$;

create or replace function public.payments_to_check_act(p_kind text, p_id uuid, p_action text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare e public.payment_expected%rowtype; v_act text := lower(btrim(coalesce(p_action,'')));
begin
  if auth.uid() is null or not (coalesce(public.is_partner(),false)
        or coalesce(public.get_my_role(),'') in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_check.denied',''));
  end if;

  if lower(btrim(coalesce(p_kind,''))) = 'alert' then
    if v_act = 'verify' then
      return public.payment_alert_act(p_id, 'verify_now')
             || jsonb_build_object('screen', public.payments_to_check_screen());
    end if;
    return public.payment_alert_act(p_id, 'not_medibo')
           || jsonb_build_object('screen', public.payments_to_check_screen());
  end if;

  select * into e from public.payment_expected where id = p_id;
  if e.id is null then
    return jsonb_build_object('ok', false, 'error','not_found');
  end if;
  if v_act = 'verify' then
    if public._pay_expected_settle(e.id, e.alert_id, 'pay_alert.match.manual') is null then
      -- No alert to settle against: verify the client's own claim by hand.
      update public.payment_expected
         set status = 'paid', paid_at = now(), match_reason = 'pay_alert.match.manual'
       where id = e.id;
    end if;
    return jsonb_build_object('ok', true,
      'message', public.uic('pay_check.verified_toast',''),
      'screen',  public.payments_to_check_screen());
  end if;

  update public.payment_expected
     set status = 'rejected', client_status = 'rejected', match_reason = null
   where id = e.id;
  return jsonb_build_object('ok', true,
    'message', public.uic('pay_check.rejected_toast',''),
    'screen',  public.payments_to_check_screen());
end $fn$;

-- ── G. Staff order payment card (frames 40–41) ──────────────────────────────
insert into public.ui_copy(key, value) values
  ('pay_card.booked',        '"Amount booked"'::jsonb),
  ('pay_card.received',      '"Received"'::jsonb),
  ('pay_card.utr',           '"UTR"'::jsonb),
  ('pay_card.how',           '"How"'::jsonb),
  ('pay_card.why',           '"Why"'::jsonb),
  ('pay_card.writeoff_tpl',  '"{received} · {writeoff} written off"'::jsonb),
  ('pay_card.part_tpl',      '"{amount} ({part})"'::jsonb),
  ('pay_card.src.alert',     '"Auto · Vyapar alert"'::jsonb),
  ('pay_card.src.screenshot','"Screenshot"'::jsonb),
  ('pay_card.src.reply',     '"Customer reply"'::jsonb),
  ('pay_card.src.manual',    '"Recorded by staff"'::jsonb),
  ('pay_card.chip.online',   '"Online"'::jsonb),
  ('pay_card.chip.cash',     '"Cash"'::jsonb),
  ('pay_card.chip.verified', '"Verified"'::jsonb),
  ('pay_card.chip.claimed',  '"Waiting"'::jsonb),
  ('pay_card.chip.rejected', '"Rejected"'::jsonb),
  ('pay_card.chip.duplicate','"Duplicate"'::jsonb),
  ('pay_card.chip.wrong_payee','"Wrong payee"'::jsonb),
  ('pay_card.chip.part_paid','"Part-paid"'::jsonb),
  ('pay_card.why.duplicate_tpl','"This UPI ref is already recorded on {order}"'::jsonb),
  ('pay_card.why.wrong_payee_tpl','"Paid to another UPI ID — only {payee}''s Vyapar ID counts"'::jsonb),
  ('pay_card.why.part_paid_tpl','"{paid} of {due} — counted; strip now says Pay {left}"'::jsonb),
  ('pay_card.how.reply_tpl', '"Customer replied 1 on WhatsApp at {when}"'::jsonb),
  ('pay_card.how.alert_tpl', '"{reason}"'::jsonb),
  ('pay_card.section',       '"SCREENSHOT OUTCOMES"'::jsonb)
on conflict (key) do nothing;

create or replace function public.order_payment_cards(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_rows jsonb; v_payee text;
begin
  select coalesce(nullif(btrim(pn),''),'') into v_payee
    from public.payment_upi_accounts where is_active order by created_at desc limit 1;

  select coalesce(jsonb_agg(card order by card->>'at' desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'claim_id', c.id,
      'at',       to_char(coalesce(c.paid_ts, c.received_at, c.created_at), 'YYYY-MM-DD HH24:MI:SS'),
      'chips',    (select jsonb_agg(ch) from (
                     select jsonb_build_object('label', public.uic('pay_card.chip.'||c.status, initcap(c.status)),
                              'tone', case c.status when 'verified' then 'success'
                                                    when 'rejected' then 'danger' else 'warning' end) as ch
                     union all
                     select jsonb_build_object('label', case when coalesce(c.payment_method,'online') = 'cash'
                                                        then public.uic('pay_card.chip.cash','')
                                                        else public.uic('pay_card.chip.online','') end,
                              'tone','info')
                     union all
                     select jsonb_build_object('label',
                              case when c.sender_type = 'payment_alert' then public.uic('pay_card.src.alert','')
                                   when coalesce(c.file_path,'') <> ''  then public.uic('pay_card.src.screenshot','')
                                   when exists (select 1 from public.payment_alert_question q
                                                 where q.chosen_order_id = c.order_id and q.status = 'answered')
                                        then public.uic('pay_card.src.reply','')
                                   else public.uic('pay_card.src.manual','') end,
                              'tone','muted')
                     union all
                     select jsonb_build_object('label', public.uic('pay_card.chip.duplicate',''), 'tone','warning')
                      where exists (select 1 from public.payment_claims d
                                     where nullif(d.utr,'') is not null and d.utr = c.utr
                                       and d.id <> c.id and d.status = 'verified')
                     union all
                     select jsonb_build_object('label', public.uic('pay_card.chip.wrong_payee',''), 'tone','danger')
                      where nullif(c.payee_vpa,'') is not null
                        and not exists (select 1 from public.payment_upi_accounts u
                                         where lower(u.pa) = lower(btrim(c.payee_vpa)))
                     union all
                     select jsonb_build_object('label', public.uic('pay_card.chip.part_paid',''), 'tone','warning')
                      where coalesce((c.raw_ocr->>'received')::numeric, c.amount) < coalesce(e.base_amount, c.amount)
                   ) z(ch)),
      'rows', (select jsonb_agg(r) from (
                 select jsonb_build_object('label', public.uic('pay_card.booked',''),
                          'value', case when e.part is not null
                                        then replace(replace(public.uic('pay_card.part_tpl',''),
                                               '{amount}', public.inr_money(coalesce(e.base_amount, c.amount))),
                                               '{part}', e.part)
                                        else public.inr_money(c.amount) end) as r
                 union all
                 select jsonb_build_object('label', public.uic('pay_card.received',''),
                          'value', case when coalesce(e.writeoff,0) > 0
                                        then replace(replace(public.uic('pay_card.writeoff_tpl',''),
                                               '{received}', public.inr_money(coalesce((c.raw_ocr->>'received')::numeric, e.amount, c.amount))),
                                               '{writeoff}', public.inr_money(e.writeoff))
                                        else public.inr_money(coalesce((c.raw_ocr->>'received')::numeric, c.amount)) end)
                 union all
                 select jsonb_build_object('label', public.uic('pay_card.utr',''), 'value', c.utr)
                  where coalesce(c.utr,'') <> ''
                 union all
                 select jsonb_build_object('label', public.uic('pay_card.how',''),
                          'value', coalesce(
                            (select replace(public.uic('pay_card.how.reply_tpl',''), '{when}',
                                     to_char(q.answered_at at time zone 'Asia/Kolkata','hh12:mi am'))
                               from public.payment_alert_question q
                              where q.chosen_order_id = c.order_id and q.status = 'answered'
                              order by q.answered_at desc limit 1),
                            (select a.match_reason from public.payment_alerts a where a.matched_claim_id = c.id limit 1),
                            nullif(c.verify_reason,''), ''))
                  where coalesce(
                            (select 1 from public.payment_alert_question q
                              where q.chosen_order_id = c.order_id and q.status = 'answered' limit 1),
                            (select 1 from public.payment_alerts a where a.matched_claim_id = c.id limit 1),
                            case when coalesce(c.verify_reason,'') <> '' then 1 else null end) is not null
               ) y(r)),
      'why', coalesce(
        (select replace(public.uic('pay_card.why.duplicate_tpl',''), '{order}',
                  coalesce(nullif(btrim(o2.order_code),''),''))
           from public.payment_claims d join public.orders o2 on o2.id = d.order_id
          where nullif(d.utr,'') is not null and d.utr = c.utr and d.id <> c.id and d.status = 'verified'
          limit 1),
        (select replace(public.uic('pay_card.why.wrong_payee_tpl',''), '{payee}', v_payee)
          where nullif(c.payee_vpa,'') is not null
            and not exists (select 1 from public.payment_upi_accounts u
                             where lower(u.pa) = lower(btrim(c.payee_vpa)))),
        (select replace(replace(replace(public.uic('pay_card.why.part_paid_tpl',''),
                  '{paid}', public.inr_money(coalesce((c.raw_ocr->>'received')::numeric, c.amount))),
                  '{due}',  public.inr_money(coalesce(e.base_amount, c.amount))),
                  '{left}', public.inr_money(greatest(coalesce(e.base_amount, c.amount)
                                                      - coalesce((c.raw_ocr->>'received')::numeric, c.amount), 0)))
          where coalesce((c.raw_ocr->>'received')::numeric, c.amount) < coalesce(e.base_amount, c.amount)),
        ''),
      'why_label', public.uic('pay_card.why','')
    ) as card
    from public.payment_claims c
    left join public.payment_expected e on e.claim_id = c.id
   where c.order_id = p_order_id
  ) q;

  return jsonb_build_object('ok', true,
    'section_label', public.uic('pay_card.section',''),
    'rows', coalesce(v_rows,'[]'::jsonb));
end $fn$;

create or replace function public.admin_order_payment_view_v2(p_order_id uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select d || public.money_display_block(d, array[
           'total','due','paid','amount','balance','order_total','net_payable',
           'advance_required','claimed_amount','ocr_amount','app_amount'])
           || jsonb_build_object('collection', public.rzp_panel_block())
           || jsonb_build_object('payment_cards', public.order_payment_cards(p_order_id))
  from (select public.admin_order_payment_view(p_order_id) d) z;
$fn$;

-- ── H. The UPI link carries the merchant code; personal says so by name ─────
create or replace function public.pay_expected_create(p_order_id uuid, p_part text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  o record; v_role text := coalesce(public.get_my_role(),'');
  v_part text; v_due numeric; v_cfg jsonb; v_hours int; v_step numeric; v_max int;
  v_pa text; v_pn text; v_kind text; v_mc text; v_amt numeric; v_i int := 0;
  e public.payment_expected%rowtype;
  v_n int; v_ref text; v_note text; v_id uuid;
begin
  select id, order_code, user_id, zone_id, status into o from public.orders where id = p_order_id;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if auth.uid() is null or not (
        o.user_id = auth.uid()
     or v_role in ('admin','super_admin')
     or (coalesce(public.is_partner(), false) and public.partner_zone_id() is not distinct from o.zone_id)) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('pay_expected.not_authorized', 'This order is not on your account.'));
  end if;
  if lower(coalesce(o.status,'')) in ('cancelled','rejected') then
    return jsonb_build_object('ok', false, 'error', 'order_closed',
      'message', public.uic('pay_expected.order_closed', 'This order is closed.'));
  end if;

  v_part := lower(coalesce(nullif(btrim(p_part),''),
              case when public.rzp_amount_due(p_order_id, 'advance') > 0 then 'advance' else 'balance' end));
  if v_part not in ('advance','balance') then return jsonb_build_object('ok', false, 'error', 'bad_part'); end if;

  v_due := round(coalesce(public.rzp_amount_due(p_order_id, v_part), 0), 2);
  if v_due <= 0 then
    return jsonb_build_object('ok', false, 'error', 'nothing_due',
      'message', public.uic('pay_expected.nothing_due', 'Nothing is due on this order right now.'));
  end if;

  select pa, pn, coalesce(account_type, case when kind='business' then 'business_vpa' else 'personal' end),
         nullif(btrim(coalesce(merchant_code,'')),'')
    into v_pa, v_pn, v_kind, v_mc
    from public.payment_upi_accounts where is_active order by created_at desc limit 1;
  if v_pa is null then
    return jsonb_build_object('ok', false, 'error', 'no_payee',
      'message', public.uic('pay_expected.no_payee', 'Online payment is not set up yet.'));
  end if;
  -- CMD #2249/#2250 — a personal UPI cannot take a fixed-amount merchant
  -- payment, so there is no Pay button: the app falls back to QR + screenshot.
  if v_kind <> 'business_vpa' then
    return jsonb_build_object('ok', false, 'error', 'payee_personal',
      'pay_button_off', true,
      'message', public.uic('pay_expected.personal_body',
                   'Personal UPI is active, so the Pay button is off.'),
      'payee', public.pay_payee_active());
  end if;

  v_cfg   := coalesce((select value from public.app_settings where key = 'pay_expected.config'), '{}'::jsonb);
  v_hours := greatest(coalesce((v_cfg->>'window_hours')::int, 12), 1);
  v_step  := greatest(coalesce((v_cfg->>'step_paise')::int, 1), 1) / 100.0;
  v_max   := least(greatest(coalesce((v_cfg->>'max_steps')::int, 99), 1), 99);

  perform pg_advisory_xact_lock(hashtext('pay_expected:' || coalesce(o.zone_id::text, '0')));

  select * into e from public.payment_expected
   where order_id = p_order_id and part = v_part and status = 'open' and expires_at > now()
   order by created_at desc limit 1;
  if e.id is not null and e.base_amount = v_due and e.payee_vpa = v_pa then
    return public._pay_expected_payload(e.id);
  end if;
  update public.payment_expected set status = 'superseded'
   where order_id = p_order_id and part = v_part and status = 'open';

  v_amt := v_due;
  while exists (select 1 from public.payment_expected x
                 where x.status = 'open' and x.expires_at > now()
                   and x.zone_id is not distinct from o.zone_id and x.amount = v_amt) loop
    v_i := v_i + 1;
    if v_i > v_max or v_amt - v_step <= 0 then
      return jsonb_build_object('ok', false, 'error', 'no_unique_amount',
        'message', public.uic('pay_expected.busy', 'Too many payments of this amount right now. Please try again in a minute.'));
    end if;
    v_amt := round(v_amt - v_step, 2);
  end loop;

  select count(*) into v_n from public.payment_expected where order_id = p_order_id and part = v_part;
  v_ref  := upper(regexp_replace(coalesce(o.order_code, left(o.id::text, 8)), '[^A-Za-z0-9]', '', 'g'))
            || case v_part when 'advance' then 'A' else 'B' end || (v_n + 1)::text;
  v_note := 'mediBO ' || coalesce(o.order_code, '') || ' ' || v_part;

  insert into public.payment_expected
    (order_id, order_code, customer_id, user_id, zone_id, part, base_amount, amount, writeoff,
     payee_vpa, payee_name, ref, upi_url, expires_at)
  values (o.id, o.order_code, public._pa_customer_of_order(o.id), o.user_id, o.zone_id, v_part, v_due, v_amt,
          round(v_due - v_amt, 2), v_pa, v_pn, v_ref,
          replace(public.upi_qr_string(v_pa, v_pn, v_amt, v_note), ' ', '%20')
            || '&tr=' || v_ref
            || case when v_mc is null then '' else '&mc=' || v_mc end,
          now() + make_interval(hours => v_hours))
  returning id into v_id;

  return public._pay_expected_payload(v_id);
end $fn$;

-- ── I. Change-basis: the screens follow these tables, nothing polls ─────────
do $$
begin
  begin alter publication supabase_realtime add table public.payment_alerts; exception when others then null; end;
  begin alter publication supabase_realtime add table public.payment_claims; exception when others then null; end;
  begin alter publication supabase_realtime add table public.payment_alert_device; exception when others then null; end;
end $$;

grant execute on function public._c2250_url_decode(text)              to authenticated;
grant execute on function public.upi_qr_parse(text)                       to authenticated;
grant execute on function public.upi_account_save(text,text,text,text,jsonb,text,boolean) to authenticated;
grant execute on function public.upi_make_active(uuid,boolean)            to authenticated;
grant execute on function public.upi_test_rupee(text,text,text)           to authenticated;
grant execute on function public.upi_test_rupee_state()                   to authenticated;
grant execute on function public.pay_payee_screen()                       to authenticated;
grant execute on function public.pay_partner_phone_screen(text)           to authenticated;
grant execute on function public.payment_alert_device_set_partner(text,bigint) to authenticated;
grant execute on function public.payment_alert_outcome(uuid)              to authenticated;
grant execute on function public.payment_alert_act(uuid,text,uuid)        to authenticated;
grant execute on function public.payments_to_check_screen(integer)        to authenticated;
grant execute on function public.payments_to_check_act(text,uuid,text)    to authenticated;
grant execute on function public.order_payment_cards(uuid)                to authenticated;
grant execute on function public.pay_phone_stale_hours()                  to authenticated;

-- ── J. The three business apps the partner phone is asked about (frame 5) ───
-- Seeded only when absent, so a live rule an admin has tuned is never replaced.
insert into public.payment_alert_rules(package_name, label, app_kind, priority, enabled)
select v.pkg, v.lbl, 'business', v.pri, true
  from (values
    ('com.hdfc.smarthub',            'HDFC SmartHub Vyapar', 10),
    ('com.phonepe.business',         'PhonePe Business',     20),
    ('net.one97.paytm.merchant',     'Paytm for Business',   30)
  ) as v(pkg, lbl, pri)
 where not exists (select 1 from public.payment_alert_rules r where r.package_name = v.pkg);

-- ── K. The two new entry points in the profile menu (§11 reachability) ──────
insert into public.ui_copy(key, value) values
  ('home_shell.payment_alerts',   '"Payment alerts"'::jsonb),
  ('home_shell.payments_to_check','"UPI payments to check"'::jsonb)
on conflict (key) do nothing;


-- ── L. Customer WhatsApp (frames 38–39): both bodies come from ui_copy ──────
insert into public.ui_copy(key, value) values
  ('pay_expected.ask_tpl',      '"We received {amount}. Is this your payment for order {order_code}? Reply 1 for yes."'::jsonb),
  ('pay_expected.asked',        '"Amount matches a Pay-button payment; asked the customer to confirm it is theirs."'::jsonb),
  ('pay_expected.received_tpl', '"Payment received ✓ {amount} for order {order_code}. Your order is confirmed."'::jsonb),
  ('pay_expected.writeoff_note','"paid {n} paisa less"'::jsonb)
on conflict (key) do nothing;

CREATE OR REPLACE FUNCTION public._payment_claim_verify_core(p_claim_id uuid, p_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_amt numeric; v_utr text; v_app text; v_paid text; v jsonb;
begin
  update public.payment_claims
     set order_id = p_order_id, status = 'verified', verify_reason = p_reason
   where id = p_claim_id
  returning amount, utr, app, paid_at into v_amt, v_utr, v_app, v_paid;

  if not found then
    return jsonb_build_object('ok', false, 'error','not_found');
  end if;

  -- Manual verify accepted the order too (verify_and_accept_payment); the
  -- auto path must land in the same state.
  update public.orders set status = 'accepted'
   where id = p_order_id and status <> 'accepted';

  begin
    v := public.notify('payment_received_online', public._order_customer_phone(p_order_id),
           jsonb_build_object(
             'order_id',    p_order_id,
             -- CMD #2250 — the customer's message is a backend string, so its
             -- wording is an UPDATE to ui_copy and never a deploy (frame 39).
             'body', replace(replace(
                       public.uic('pay_expected.received_tpl',
                         'Payment received ✓ {amount} for order {order_code}. Your order is confirmed.'),
                       '{amount}', public.inr_money(coalesce(v_amt,0))),
                       '{order_code}', coalesce((select nullif(btrim(o.order_code),'')
                                                   from public.orders o where o.id = p_order_id), '')),
             'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
             'legacy_body', jsonb_build_object('order_id', p_order_id::text, 'event','payment_received',
                              'amount', coalesce(v_amt,0), 'utr', coalesce(v_utr,''),
                              'app', coalesce(v_app,''), 'paid_at', coalesce(v_paid,''))));
  exception when others then
    perform public._wa_log_attempt('payment_received_online', p_order_id, null, 'skipped', false,
                                   'caller_error: ' || sqlerrm, null);
  end;

  return jsonb_build_object('ok', true, 'claim_id', p_claim_id, 'order_id', p_order_id,
                            'amount', v_amt, 'notify', v);
end $function$;



-- ── M. Both new screens are registered features with a test contract ────────
-- §11: a feature Om cannot open does not exist; c634: an active feature that
-- declares no test contract fails the regression guard. Both are declared here
-- against the REAL routes (not an /admin/go/ alias that no route handler has).
insert into public.feature_registry (
  feature_key, label, group_label, icon_key, route_key, sort_order, owner,
  partner_eligible, default_access, is_active, category, surface, roles_allowed,
  deep_link, search_terms, canonical_key,
  test_entry, test_roles, test_steps, test_expect, test_automatable, test_contract_at)
values
  ('admin.payment_alerts', 'Payment alerts', 'Money', 'payments',
   'payment_alerts', 51, 'medibo', true, 'write', true, 'money', 'dashboard',
   array['super_admin','admin','partner'],
   '/admin/payment-alerts',
   'payment alert vyapar upi listener partner phone matching verify',
   'admin.payment_alerts',
   '/admin/payment-alerts', array['super_admin'],
   jsonb_build_array(
     jsonb_build_object('kind','auth','role','{role}'),
     jsonb_build_object('kind','goto','path','/admin/payment-alerts'),
     jsonb_build_object('kind','settle','ms',6000)),
   jsonb_build_object('kind','visible','source','render_log',
                      'key','c2250_phone_state','equals',null),
   true, now()),
  ('admin.payments_to_check', 'UPI payments to check', 'Money', 'wallet',
   'payments_to_check', 52, 'medibo', true, 'write', true, 'money', 'dashboard',
   array['super_admin','admin','partner'],
   '/admin/payments-to-check',
   'upi payments to check verify reject waiting claim alert',
   'admin.payments_to_check',
   '/admin/payments-to-check', array['super_admin'],
   jsonb_build_array(
     jsonb_build_object('kind','auth','role','{role}'),
     jsonb_build_object('kind','goto','path','/admin/payments-to-check'),
     jsonb_build_object('kind','settle','ms',6000)),
   jsonb_build_object('kind','visible','source','render_log',
                      'key','c2250_check_rows','equals',null),
   true, now())
on conflict (feature_key) do update
   set label          = excluded.label,
       deep_link      = excluded.deep_link,
       test_entry     = excluded.test_entry,
       test_roles     = excluded.test_roles,
       test_steps     = excluded.test_steps,
       test_expect    = excluded.test_expect,
       test_automatable = excluded.test_automatable,
       test_contract_at = excluded.test_contract_at,
       is_active      = true;
