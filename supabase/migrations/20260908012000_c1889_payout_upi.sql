-- CMD #1889 — UPI is asked for at the FIRST payout, never at signup.
--
-- A customer is asked where money should land only once there is money to send:
-- a refund waiting, or a settlement owed. Saving the VPA does not make it
-- payable — the backend sends ₹1 down the existing verify path and the payout
-- stays blocked until that ₹1 is confirmed. Every word here is backend copy.

insert into public.ui_copy(key, value) values
  ('upi.payout_title',       '"Where should we send your money?"'::jsonb),
  ('upi.payout_hint',        '"Add the UPI ID your refunds and settlements should reach. We send ₹1 to prove it works before anything else is paid out."'::jsonb),
  ('upi.payout_add_label',   '"Add UPI"'::jsonb),
  ('upi.payout_due_one',     '"{amt} is waiting to be sent to you."'::jsonb),
  ('upi.payout_due_many',    '"{amt} across {n} payouts is waiting to be sent to you."'::jsonb),
  ('upi.payout_blocked',     '"Payouts are on hold until your UPI ID is verified."'::jsonb),
  ('upi.payout_ready',       '"Your UPI ID is verified. Payouts go out to it."'::jsonb),
  ('upi.verify_sent',        '"₹1 is on its way to {vpa}. Tap Confirm once you see it."'::jsonb),
  ('upi.verify_send_label',  '"Send ₹1 test"'::jsonb),
  ('upi.verify_confirm_label','"I received ₹1"'::jsonb),
  ('upi.verify_pending_label','"₹1 test sent — waiting for you to confirm"'::jsonb),
  ('upi.verify_confirmed',   '"UPI ID verified. Payouts are open."'::jsonb),
  ('upi.err_no_verify',      '"Send the ₹1 test first."'::jsonb),
  ('upi.err_payout_blocked', '"This customer has no verified UPI ID yet, so the payout cannot be sent."'::jsonb),
  ('upi.change_label',       '"Change UPI ID"'::jsonb)
on conflict (key) do nothing;

insert into public.wa_event_routes(event_key, label, description, enabled)
values ('upi_verify_sent', 'UPI ₹1 test sent',
        'Tells the customer a ₹1 verification is on its way to the UPI ID they added.', true)
on conflict (event_key) do nothing;

-- ── the ₹1 tests, one row per attempt ─────────────────────────────────────
create table if not exists public.pharmacy_upi_verify (
  id           bigserial primary key,
  pharmacy_id  uuid not null references public.pharmacy_profiles(id) on delete cascade,
  vpa          text not null,
  vpa_name     text,
  amount       numeric(10,2) not null default 1.00,
  status       text not null default 'sent',   -- sent | confirmed | cancelled
  reference    text not null,
  sent_at      timestamptz not null default now(),
  confirmed_at timestamptz,
  confirmed_by uuid,
  source       text not null default 'payout',
  zone_id      smallint
);
create index if not exists pharmacy_upi_verify_shop_idx
  on public.pharmacy_upi_verify(pharmacy_id, sent_at desc);
alter table public.pharmacy_upi_verify enable row level security;

-- ── what is owed to this customer right now ───────────────────────────────
create or replace function public.pharmacy_payout_due(p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_ids uuid[]; v_n int := 0; v_amt numeric := 0;
begin
  if p_customer_id is null then
    return jsonb_build_object('has', false, 'count', 0, 'amount', 0);
  end if;
  v_ids := public._cus810_order_ids(p_customer_id);
  select count(*)::int, coalesce(sum(r.amount),0)
    into v_n, v_amt
    from public.refunds r
   where r.order_id = any(v_ids)
     and coalesce(r.status,'') in ('pending','processing');
  return jsonb_build_object(
    'has', v_n > 0, 'count', v_n, 'amount', round(v_amt,2),
    'amount_display', public._cus810_money(round(v_amt,2)));
end $fn$;

-- ── the ONE answer to "may money leave for this customer?" ────────────────
create or replace function public.pharmacy_payout_guard(p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_payee jsonb;
begin
  v_payee := public._upi_payee(p_customer_id);
  if coalesce((v_payee->>'has')::boolean, false) then
    return jsonb_build_object('allowed', true, 'blocked', false, 'message','');
  end if;
  return jsonb_build_object('allowed', false, 'blocked', true,
    'reason',  coalesce(v_payee->>'reason','no_vpa'),
    'message', public._c('upi.err_payout_blocked'));
end $fn$;

-- ── the customer's own card ───────────────────────────────────────────────
create or replace function public.pharmacy_payout_upi()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_shop uuid := public.pos_shop();
  pp public.pharmacy_profiles%rowtype;
  v_due jsonb; v_setup jsonb; v_last public.pharmacy_upi_verify%rowtype;
  v_verified boolean; v_pending boolean;
begin
  if v_shop is null then
    return jsonb_build_object('ok', false, 'needed', false,
      'message', public._c('upi.err_not_owner'));
  end if;
  select * into pp from public.pharmacy_profiles where id = v_shop;
  v_due   := public.pharmacy_payout_due(v_shop);
  v_setup := public._upi_setup_block(v_shop);
  select * into v_last from public.pharmacy_upi_verify
   where pharmacy_id = v_shop order by sent_at desc limit 1;

  v_verified := pp.upi_verified_at is not null;
  v_pending  := (not v_verified) and v_last.id is not null and v_last.status = 'sent'
                and lower(btrim(coalesce(v_last.vpa,''))) = lower(btrim(coalesce(pp.upi_vpa,'')));

  return jsonb_build_object(
    'ok', true,
    -- Asked for ONLY when there is money to send, or when the customer has
    -- already started. Signup never sees this card.
    'needed', coalesce((v_due->>'has')::boolean, false) or coalesce(pp.upi_vpa,'') <> '',
    'title',  public._c('upi.payout_title'),
    'hint',   public._c('upi.payout_hint'),
    'due',    v_due,
    'due_label', case when not coalesce((v_due->>'has')::boolean, false) then ''
                      when (v_due->>'count')::int = 1
                        then public.ui_fmt('upi.payout_due_one',
                               jsonb_build_object('amt', v_due->>'amount_display'))
                      else public.ui_fmt('upi.payout_due_many',
                             jsonb_build_object('amt', v_due->>'amount_display',
                                                'n', v_due->>'count')) end,
    'state_label', case when v_verified then public._c('upi.payout_ready')
                        when v_pending  then public._c('upi.verify_pending_label')
                        else public._c('upi.payout_blocked') end,
    'state_tone',  case when v_verified then 'success'
                        when v_pending  then 'warning' else 'danger' end,
    'vpa',          coalesce(pp.upi_vpa,''),
    'vpa_name',     coalesce(pp.upi_vpa_name,''),
    'verified',     v_verified,
    'test_pending', v_pending,
    'vpa_label',    v_setup->>'vpa_label',
    'name_label',   v_setup->>'name_label',
    'can_edit',     coalesce((v_setup->>'can_edit')::boolean, false),
    'locked_hint',  v_setup->>'locked_hint',
    'add_label',    public._c('upi.payout_add_label'),
    'change_label', public._c('upi.change_label'),
    'send_label',   public._c('upi.verify_send_label'),
    'confirm_label',public._c('upi.verify_confirm_label'),
    'reference',    case when v_pending then coalesce(v_last.reference,'') else '' end);
end $fn$;

-- ── add the VPA and send the ₹1 ───────────────────────────────────────────
create or replace function public.pharmacy_upi_verify_start(p_vpa text, p_name text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_shop uuid := public.pos_shop();
  v_saved jsonb; v_ref text; pp public.pharmacy_profiles%rowtype;
begin
  if v_shop is null then return public._pos_denied(); end if;
  -- The VPA format check, the owner check and the "a changed VPA drops back to
  -- unconfirmed" rule all live in pharmacy_upi_save. This never repeats them.
  v_saved := public.pharmacy_upi_save(p_vpa, p_name, 'payout');
  if not coalesce((v_saved->>'ok')::boolean, false) then return v_saved; end if;

  select * into pp from public.pharmacy_profiles where id = v_shop;
  if pp.upi_verified_at is not null then
    return v_saved || jsonb_build_object('verified', true, 'test_pending', false,
      'card', public.pharmacy_payout_upi());
  end if;

  v_ref := 'UPI1-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  update public.pharmacy_upi_verify set status = 'cancelled'
   where pharmacy_id = v_shop and status = 'sent';
  insert into public.pharmacy_upi_verify(pharmacy_id, vpa, vpa_name, reference, zone_id)
  values (v_shop, pp.upi_vpa, pp.upi_vpa_name, v_ref, pp.zone_id);

  begin
    perform public.wa_send_event('upi_verify_sent', v_shop,
      jsonb_build_object('vpa', pp.upi_vpa, 'ref', v_ref, 'amt', '₹1',
                         'name', coalesce(pp.pharmacy_name,''), 'link', 'https://medibo.in/'),
      coalesce(nullif(pp.whatsapp_no,''), pp.phone), null);
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'tone','info',
    'reference', v_ref, 'test_pending', true, 'verified', false,
    'message', public.ui_fmt('upi.verify_sent', jsonb_build_object('vpa', pp.upi_vpa)),
    'card', public.pharmacy_payout_upi());
end $fn$;

-- ── the customer says the ₹1 landed ───────────────────────────────────────
create or replace function public.pharmacy_upi_verify_confirm()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_shop uuid := public.pos_shop();
  pp public.pharmacy_profiles%rowtype; v_res jsonb;
begin
  if v_shop is null then return public._pos_denied(); end if;
  select * into pp from public.pharmacy_profiles where id = v_shop;
  if not exists (select 1 from public.pharmacy_upi_verify
                  where pharmacy_id = v_shop and status = 'sent'
                    and lower(btrim(vpa)) = lower(btrim(coalesce(pp.upi_vpa,'')))) then
    return jsonb_build_object('ok', false, 'error','no_test', 'tone','danger',
      'message', public._c('upi.err_no_verify'));
  end if;
  -- the ONE existing confirm path writes upi_verified_at and the history row
  v_res := public.pharmacy_upi_confirm(pp.upi_vpa, 'payout');
  if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;

  update public.pharmacy_upi_verify
     set status = 'confirmed', confirmed_at = now(), confirmed_by = auth.uid()
   where pharmacy_id = v_shop and status = 'sent';

  return jsonb_build_object('ok', true, 'tone','success', 'verified', true,
    'message', public._c('upi.verify_confirmed'),
    'card', public.pharmacy_payout_upi());
end $fn$;

revoke all on function public.pharmacy_payout_upi() from public;
grant execute on function public.pharmacy_payout_upi() to authenticated;
revoke all on function public.pharmacy_upi_verify_start(text, text) from public;
grant execute on function public.pharmacy_upi_verify_start(text, text) to authenticated;
revoke all on function public.pharmacy_upi_verify_confirm() from public;
grant execute on function public.pharmacy_upi_verify_confirm() to authenticated;
revoke all on function public.pharmacy_payout_guard(uuid) from public;
grant execute on function public.pharmacy_payout_guard(uuid) to authenticated;
revoke all on function public.pharmacy_payout_due(uuid) from public;
-- CMD #1889 — money does not leave for a customer whose UPI ID is unproven.
create or replace function public.refund_mark_manual(p_refund_id uuid, p_utr text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r public.refunds%rowtype; v_cust uuid; v_guard jsonb;
begin
  perform public._returns_guard();
  select * into r from public.refunds where id = p_refund_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'refund_not_found',
      'message', public._c('refunds.err_not_found'));
  end if;
  if r.method <> 'manual_upi' then
    return jsonb_build_object('ok', false, 'error', 'not_manual',
      'message', public._c('refunds.err_not_manual'));
  end if;
  if r.status not in ('pending','processing') then
    return jsonb_build_object('ok', false, 'error', 'not_pending',
      'message', public._c('refunds.err_not_pending'));
  end if;

  -- CMD #1889 — the ₹1 test is what makes a VPA payable. Until it is confirmed
  -- the payout is refused HERE, with the backend's own sentence, so no screen
  -- has to know the rule.
  select o.customer_id into v_cust from public.orders o where o.id = r.order_id;
  v_guard := public.pharmacy_payout_guard(v_cust);
  if v_cust is not null and coalesce((v_guard->>'blocked')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', 'upi_unverified',
      'reason', v_guard->>'reason', 'message', v_guard->>'message');
  end if;

  update public.refunds
     set status = 'processed', utr = nullif(btrim(p_utr),''),
         approved_by = coalesce(approved_by, auth.uid()),
         approved_at = coalesce(approved_at, now()),
         processed_at = now()
   where id = p_refund_id;
  return jsonb_build_object('ok', true, 'id', p_refund_id,
    'message', public._c('refunds.manual_done_toast'));
end $fn$;
-- CMD #1889 — the Billing tab carries the payout-UPI card when money is owed.
CREATE OR REPLACE FUNCTION public.my_account_tab_billing(p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  pp public.pharmacy_profiles%rowtype;
  v_ids uuid[]; v_lim int := least(greatest(coalesce(p_limit,25),5), 100);
  v_billed numeric := 0; v_paid numeric := 0; v_inv jsonb; v_claims jsonb; v_phones text[];
  v_upi jsonb;
begin
  pp := public._acct840_me();
  if pp.id is null then return public._acct840_deny(); end if;
  v_ids := public._cus810_order_ids(pp.id);

  v_phones := array_remove(array[
      public.identity_norm(pp.phone), public.identity_norm(pp.whatsapp_no),
      public.identity_norm(pp.other_contact_no), public.identity_norm(pp.last_payment_wa_no)], null);

  select coalesce(sum(v.val),0) into v_billed
    from public.orders o
    left join lateral (select coalesce((select sum(coalesce(oi.line_total, oi.quantity*oi.price))
                                          from public.order_items oi where oi.order_id = o.id
                                           and coalesce(oi.unfulfillable,false) = false),0) as val) v on true
   where o.id = any(v_ids);

  select coalesce(sum(pc.amount),0) into v_paid from public.payment_claims pc
   where pc.order_id = any(v_ids)
     and coalesce(pc.status,'') not in ('rejected','duplicate','need_details');

  select coalesce(jsonb_agg(y order by ord desc), '[]'::jsonb) into v_inv from (
    select o.created_at as ord, jsonb_build_object(
      'title', coalesce(nullif(o.invoice_no,''), nullif(o.order_code,''), left(o.id::text,8)),
      'subtitle', to_char(coalesce(o.invoice_issued_at, o.created_at) at time zone 'Asia/Kolkata','FMDD Mon YYYY'),
      'meta', public._cus810_money(coalesce(pd.amt,0))||' '||public._c('acct.b_of'),
      'trailing', public._cus810_money(coalesce(v.val,0)),
      'trailing_tone', case when coalesce(v.val,0) - coalesce(pd.amt,0) > 0.009 then 'danger' else 'success' end) as y
      from public.orders o
      left join lateral (select coalesce((select sum(coalesce(oi.line_total, oi.quantity*oi.price))
                                            from public.order_items oi where oi.order_id = o.id
                                             and coalesce(oi.unfulfillable,false) = false),0) as val) v on true
      left join lateral (select coalesce((select sum(pc.amount) from public.payment_claims pc
                                           where pc.order_id = o.id
                                             and coalesce(pc.status,'') not in ('rejected','duplicate','need_details')),0) as amt) pd on true
     where o.id = any(v_ids) and coalesce(v.val,0) > 0
     order by o.created_at desc limit v_lim) s;

  -- The customer sees the SAME verification word the operator sees. What they
  -- do not get is the operator's approve/reject buttons: no `actions` here.
  select coalesce(jsonb_agg(y order by ord desc), '[]'::jsonb) into v_claims from (
    select coalesce(pc.paid_ts, pc.received_at) as ord, jsonb_build_object(
      'title', public._cus810_money(pc.amount)
               || case when coalesce(pc.utr,'') <> '' then '  ·  '||pc.utr else '' end,
      'subtitle', to_char(coalesce(pc.paid_ts, pc.received_at) at time zone 'Asia/Kolkata','FMDD Mon YYYY, HH12:MI AM'),
      'meta', array_to_string(array_remove(array[
                nullif(coalesce(pc.payment_method, pc.app, ''),''),
                (select nullif(o2.order_code,'') from public.orders o2 where o2.id = pc.order_id)], null), '  ·  '),
      'chip', public._acct840_chip(
                initcap(replace(coalesce(pc.status,''),'_',' ')),
                case when coalesce(pc.status,'') in ('rejected','duplicate','need_details') then 'danger'
                     when coalesce(pc.status,'') in ('verified','matched','linked','approved') then 'success'
                     else 'warning' end)) as y
      from public.payment_claims pc
     where pc.order_id = any(v_ids)
        or (cardinality(v_phones) > 0 and pc.sender_phone is not null
            and public.identity_norm(pc.sender_phone) = any(v_phones))
     order by coalesce(pc.paid_ts, pc.received_at) desc limit v_lim) s;

  -- CMD #1889 — "where should the money land?" is asked HERE, and only once
  -- there is money to send. The card decides that itself (pharmacy_payout_upi
  -- answers needed:false at signup), so this tab just carries it.
  v_upi := public.pharmacy_payout_upi();

  return jsonb_build_object('ok', true, 'limit', v_lim, 'blocks',
    (case when coalesce((v_upi->>'needed')::boolean, false)
          then jsonb_build_array(jsonb_build_object('kind','embed','widget','payout_upi'))
          else '[]'::jsonb end) ||
    jsonb_build_array(
    jsonb_build_object('kind','tiles','tiles', jsonb_build_array(
      jsonb_build_object('label', public._c('acct.b_billed'), 'value', public._cus810_money(v_billed), 'tone','neutral'),
      jsonb_build_object('label', public._c('acct.b_paid'),   'value', public._cus810_money(v_paid),   'tone','success'),
      jsonb_build_object('label', public._c('acct.b_outstanding'),
                         'value', public._cus810_money(greatest(v_billed - v_paid,0)),
                         'tone', case when v_billed - v_paid > 0.009 then 'danger' else 'success' end))),
    jsonb_build_object('kind','list','title', public._c('acct.b_invoices'),
                       'empty', public._c('acct.b_empty_inv'), 'items', v_inv),
    jsonb_build_object('kind','list','title', public._c('acct.b_claims'),
                       'empty', public._c('acct.b_empty_claims'), 'items', v_claims)));
end $function$


