-- CHANGE #472 — the MONEY edges, hardened.
--
-- Five of these double-apply money when fired twice; the rest read a status,
-- decide, and write with nothing holding the row in between. Each one below is
-- wired to the ONE spine from 20260904100000 (_idem_claim/_idem_store_ok) or
-- given the row lock its state check always assumed it had.
--
-- Shape, everywhere: the key is the LAST parameter and it DEFAULTS TO NULL, so
-- every existing caller — Dart, another RPC, a proof script — keeps working
-- unchanged and simply gets the old behaviour. Adding a defaulted argument to
-- an existing zero-or-n-arg function makes the call ambiguous, so each one
-- drops its previous signature first; that is why the drops are here and why
-- they are `if exists`.

-- ── 1. supplier_payments: the dedupe columns the UTR check needed ───────────
-- _sup_record_payment_write refused a duplicate UTR with `if exists (...)` and
-- then inserted — a read-then-write with no unique index behind it, so two
-- concurrent screenshots of the same transfer both passed the check. And a
-- CASH payment carries no UTR and no txn id at all, so it had no dedupe of any
-- kind: a double tap recorded the supplier being paid twice.
alter table public.supplier_payments
  add column if not exists client_action_id uuid;

create unique index if not exists supplier_payments_action_uq
  on public.supplier_payments (client_action_id) where client_action_id is not null;
create unique index if not exists supplier_payments_utr_uq
  on public.supplier_payments (utr) where utr is not null;
create unique index if not exists supplier_payments_txn_uq
  on public.supplier_payments (txn_id) where txn_id is not null;

-- ── 2. partner_settlement_payments: the same, for the partner side ──────────
alter table public.partner_settlement_payments
  add column if not exists client_action_id uuid;
create unique index if not exists partner_settlement_payments_action_uq
  on public.partner_settlement_payments (client_action_id) where client_action_id is not null;

-- ── 3. refunds: money going back out ───────────────────────────────────────
alter table public.refunds
  add column if not exists client_action_id uuid;
create unique index if not exists refunds_action_uq
  on public.refunds (client_action_id) where client_action_id is not null;

-- ── 4. orders: the placement key ───────────────────────────────────────────
alter table public.orders
  add column if not exists client_action_id uuid;
create unique index if not exists orders_action_uq
  on public.orders (client_action_id) where client_action_id is not null;

-- ── 5. the Razorpay webhook: dedupe at the FRONT DOOR ──────────────────────
-- Razorpay redelivers on any non-2xx, and the edge function answers 500 on a
-- partial failure precisely so that it will. Every handled event was then
-- re-run from the top. The money paths survived that on their unique indexes
-- (payment_claims.utr), but the log grew a row per delivery and every event
-- paid for the whole match again. x-razorpay-event-id is already stored in
-- razorpay_webhook_log.rzp_event_id — it just was not unique, so it could not
-- be used as the key it is.
create unique index if not exists razorpay_webhook_log_event_uq
  on public.razorpay_webhook_log (rzp_event_id)
  where rzp_event_id is not null and btrim(rzp_event_id) <> '';

-- ── ORDER PLACEMENT ────────────────────────────────────────────────────────
-- The worst of the five. It inserted an order and then emptied the cart, with
-- nothing keyed: a double tap on Place Order, or a client retry after a
-- timeout on a request that actually committed, made two orders. Worse, the
-- retry path usually found the cart already empty and raised `empty_cart`, so
-- the customer was shown a failure for an order that exists.
drop function if exists public._place_order_v2_core();
create or replace function public._place_order_v2_core(p_client_action_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_sess jsonb := public.my_session();
  v_cart jsonb;
  v_cust uuid := public.my_customer_id();
  v_uid  uuid := auth.uid();
  v_act  uuid := public.my_acting_as();
  pp pharmacy_profiles%rowtype;
  v_items jsonb; v_net numeric; v_id uuid; v_code text;
  v_addr text; v_copy jsonb;
  v_checkout   jsonb;
  v_delivery   jsonb;
  v_rx         jsonb;
  v_total      numeric;
  v_prev       jsonb;
  v_out        jsonb;
begin
  -- CHANGE #472 — the replay gate, before anything is read or written.
  v_prev := public._idem_claim('order.place', p_client_action_id);
  if v_prev is not null then return v_prev; end if;

  if v_uid is null then
    raise exception 'not_authenticated'
      using hint = 'Session missing or expired; sign in again and retry.';
  end if;

  if (v_sess->>'can_place_order') is distinct from 'true' then
    raise exception 'order_gate_blocked'
      using hint = coalesce(v_sess->'order_gate'->>'message', 'Ordering is not available.');
  end if;

  v_cart := public.cart_state(null);
  v_items := coalesce(v_cart->'items', '[]'::jsonb);
  if jsonb_array_length(v_items) = 0 then
    raise exception 'empty_cart' using hint = 'No items to order.';
  end if;

  -- #461/#170: Schedule H/H1 stock needs a licence on file. In 'warn' mode the
  -- order still goes through and the licence state is recorded; in 'block' mode
  -- it is refused with the BACKEND's own copy.
  v_rx := public.cart_rx_gate(v_cust, v_items);
  if coalesce((v_rx->>'blocked')::boolean, false) then
    return public._idem_store_ok('order.place', p_client_action_id,
      jsonb_build_object('error','rx_licence_required',
        'message', coalesce(v_rx->>'message',''),
        'title',   coalesce(v_rx->>'title',''),
        'rx_gate', v_rx));
  end if;

  v_net := coalesce((v_cart->'pricing'->>'net_payable')::numeric, 0);

  -- #461/#167: the delivery line, computed by the SAME block the cart rendered.
  v_delivery := public.delivery_charge_block(v_cust, v_net);
  v_total    := round(v_net + coalesce((v_delivery->>'total')::numeric, 0), 2);

  select * into pp from pharmacy_profiles where id = v_cust;

  v_addr := array_to_string(array_remove(array_remove(array[
              nullif(btrim(coalesce(pp.address_local, pp.address, '')), ''),
              nullif(btrim(coalesce(pp.city,'')), ''),
              nullif(btrim(coalesce(pp.pincode,'')), '')], null), ''), ', ');

  insert into orders
    (user_id, customer_id, pharmacy_name, items, total_amount, phone, address,
     status, source, placed_by_admin, payment_id,
     delivery_charge, delivery_charge_gst, delivery_charge_waived, delivery_charge_label,
     rx_line_count, licence_snapshot, client_action_id)
  values
    (v_uid, v_cust, coalesce(pp.pharmacy_name,''), v_items, v_total,
     coalesce(pp.phone,''), coalesce(v_addr,''), 'pending',
     'website',
     (v_act is not null),
     public.next_order_number(),
     coalesce((v_delivery->>'amount')::numeric, 0),
     coalesce((v_delivery->>'gst')::numeric, 0),
     coalesce((v_delivery->>'waived')::boolean, false),
     coalesce(v_delivery->>'label',''),
     coalesce((v_rx->>'rx_count')::int, 0),
     coalesce(v_rx->'licence', '{}'::jsonb),
     p_client_action_id)
  returning id, order_code into v_id, v_code;

  delete from cart_items
   where (case when v_cust is not null then customer_id = v_cust else user_id = v_uid end);

  v_copy := coalesce((select value from app_settings where key='order_placed_copy'), '{}'::jsonb);
  v_checkout := public.checkout_action();

  if (v_checkout->>'acting_as')::boolean
     and (v_checkout->>'collection_mode') = 'gateway' then
    begin
      perform public.rzp_send_order_qr_wa(v_id);
    exception when others then null;
    end;
  end if;

  v_out := jsonb_build_object(
    'ok',              true,
    'id',              coalesce(v_id::text,''),
    'order_code',      coalesce(v_code,''),
    'amount',          v_total,
    'amount_display',  public.inr_money(v_total),
    'items_amount',    v_net,
    'delivery',        v_delivery,
    'rx_gate',         v_rx,
    'title',           coalesce(v_copy->>'title',''),
    'note',            coalesce(v_copy->>'note',''),
    'done_label',      coalesce(v_copy->>'done_label',''),
    'item_count',      coalesce((v_cart->>'item_count')::int, 0),
    'checkout',        v_checkout);

  return public._idem_store_ok('order.place', p_client_action_id, v_out);
end $function$;

drop function if exists public.place_order_v2();
create or replace function public.place_order_v2(p_client_action_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_bad jsonb;
begin
  select jsonb_agg(jsonb_build_object('product_id', u.product_id, 'product_name', u.product_name))
    into v_bad from public._cart_unavailable_lines() u;
  if v_bad is not null and jsonb_array_length(v_bad) > 0 then
    -- A refusal is never stored against the key: the customer removes the line
    -- and retries, and that retry must be allowed to succeed.
    return jsonb_build_object('error','unavailable_in_cart',
      'message','Remove unavailable items to place your order',
      'items', v_bad, 'count', jsonb_array_length(v_bad));
  end if;
  return public._place_order_v2_core(p_client_action_id);
end $function$;

-- ── SUPPLIER PAYMENT RECORDING ─────────────────────────────────────────────
drop function if exists public._sup_record_payment_write(uuid, text, numeric, text, text, text, text, jsonb, text);
create or replace function public._sup_record_payment_write(
  p_supplier_order_id uuid, p_kind text, p_amount numeric, p_mode text, p_note text,
  p_screenshot_path text, p_screenshot_bucket text, p_ocr jsonb, p_created_by text,
  p_client_action_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_id uuid; v_name text; v_utr text; v_txn text; v_prev jsonb;
begin
  v_prev := public._idem_claim('supplier.payment', p_client_action_id);
  if v_prev is not null then return v_prev; end if;

  select supplier_name into v_name from supplier_orders where id = p_supplier_order_id;
  if v_name is null then return jsonb_build_object('ok',false,'error','order_not_found'); end if;
  if coalesce(p_amount,0) <= 0 then return jsonb_build_object('ok',false,'error','bad_amount'); end if;
  v_utr := nullif(upper(regexp_replace(coalesce(p_ocr->>'utr',''),'\s','','g')),'');
  v_txn := nullif(upper(regexp_replace(coalesce(p_ocr->>'txn_id',''),'\s','','g')),'');
  if v_utr is not null and exists (select 1 from supplier_payments where utr=v_utr) then
    return jsonb_build_object('ok',false,'error','duplicate_utr','utr',v_utr);
  end if;
  if v_txn is not null and exists (select 1 from supplier_payments where txn_id=v_txn) then
    return jsonb_build_object('ok',false,'error','duplicate_txn','txn_id',v_txn);
  end if;

  -- The check above is still the one that produces the friendly message; the
  -- unique indexes are what make it TRUE under concurrency. A racing insert
  -- lands here, not on a second payment row.
  begin
    insert into supplier_payments(supplier_order_id, supplier_name, amount, mode, note, created_by,
      kind, payee_name, payee_vpa, utr, txn_id, app, paid_at, screenshot_path, screenshot_bucket,
      raw_ocr, client_action_id)
    values (p_supplier_order_id, v_name, p_amount, coalesce(nullif(p_mode,''),'online'), p_note,
      coalesce(nullif(p_created_by,''),'admin'),
      coalesce(nullif(p_kind,''),'advance'), p_ocr->>'payee_name', p_ocr->>'payee_vpa', v_utr, v_txn,
      p_ocr->>'app', p_ocr->>'paid_at', p_screenshot_path, p_screenshot_bucket, p_ocr,
      p_client_action_id)
    returning id into v_id;
  exception when unique_violation then
    if v_utr is not null then
      return jsonb_build_object('ok',false,'error','duplicate_utr','utr',v_utr);
    elsif v_txn is not null then
      return jsonb_build_object('ok',false,'error','duplicate_txn','txn_id',v_txn);
    end if;
    select id into v_id from supplier_payments where client_action_id = p_client_action_id;
    return jsonb_build_object('ok',true,'id',v_id,'replayed',true);
  end;

  return public._idem_store_ok('supplier.payment', p_client_action_id,
           jsonb_build_object('ok',true,'id',v_id));
end $function$;

drop function if exists public.sup_record_payment(uuid, text, numeric, text, text, text, text, jsonb);
create or replace function public.sup_record_payment(
  p_supplier_order_id uuid, p_kind text, p_amount numeric, p_mode text default 'online',
  p_note text default null, p_screenshot_path text default null,
  p_screenshot_bucket text default null, p_ocr jsonb default null,
  p_client_action_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if get_my_role() <> 'super_admin' then raise exception 'forbidden: super_admin required'; end if;
  return public._sup_record_payment_write(p_supplier_order_id, p_kind, p_amount, p_mode,
           p_note, p_screenshot_path, p_screenshot_bucket, p_ocr, 'admin', p_client_action_id);
end $function$;

drop function if exists public.partner_sup_record_payment(uuid, text, numeric, text, text, text, text, jsonb);
create or replace function public.partner_sup_record_payment(
  p_supplier_order_id uuid, p_kind text, p_amount numeric, p_mode text default 'online',
  p_note text default null, p_screenshot_path text default null,
  p_screenshot_bucket text default null, p_ocr jsonb default null,
  p_client_action_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_zone smallint := public.partner_zone_id(); so record; v_res jsonb;
begin
  if public.my_partner_id() is null or not public.partner_can('partner.supplier_payment','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pss_c('err_not_authorized'));
  end if;
  select * into so from supplier_orders where id = p_supplier_order_id;
  if so.id is null then
    return jsonb_build_object('ok',false,'error','order_not_found','tone','danger',
      'message', public._pss_c('err_order_not_found'));
  end if;
  if v_zone is null or so.zone_id is null or so.zone_id::smallint <> v_zone
     or coalesce(public.partner_supplier_zone(so.supplier_name), -1) <> v_zone then
    perform public.partner_audit('partner.supplier_payment','payment_denied_zone',
      jsonb_build_object('supplier_order_id', p_supplier_order_id,
                         'order_zone', so.zone_id, 'my_zone', v_zone,
                         'summary', 'Refused: out of zone'));
    return jsonb_build_object('ok',false,'error','out_of_zone','tone','danger',
      'message', public._pss_c('err_out_of_zone'));
  end if;
  if coalesce(p_amount,0) <= 0 then
    return jsonb_build_object('ok',false,'error','bad_amount','tone','danger',
      'message', public._pss_c('err_bad_amount'));
  end if;

  v_res := public._sup_record_payment_write(p_supplier_order_id, p_kind, p_amount, p_mode,
             p_note, p_screenshot_path, p_screenshot_bucket, p_ocr,
             'partner:' || coalesce(public.my_login_email(), public.my_partner_user_id()::text),
             p_client_action_id);

  if coalesce((v_res->>'ok')::boolean, false) then
    -- A replay must not write a second audit line either.
    if not coalesce((v_res->>'replayed')::boolean, false) then
      perform public.partner_audit('partner.supplier_payment','payment_recorded',
        jsonb_build_object('supplier_order_id', p_supplier_order_id,
                           'payment_id', v_res->>'id', 'amount', p_amount, 'kind', p_kind,
                           'summary', public.inr_money(p_amount) || ' → ' || coalesce(so.supplier_name,'')));
    end if;
    return v_res || jsonb_build_object('tone','success','message', public._pss_c('pay_saved'));
  end if;

  return v_res || jsonb_build_object('tone','danger','message',
    case v_res->>'error'
      when 'duplicate_utr' then public._pss_c('err_duplicate_utr')
      when 'duplicate_txn' then public._pss_c('err_duplicate_txn')
      when 'bad_amount'    then public._pss_c('err_bad_amount')
      when 'order_not_found' then public._pss_c('err_order_not_found')
      else public._pss_c('generic_error') end);
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public._pss_c('err_failed'), '{detail}', SQLERRM), 'sqlstate', SQLSTATE);
end $function$;

-- ── PARTNER SETTLEMENT PAYMENT ─────────────────────────────────────────────
-- The old shape converted the one 'queued' row to 'paid' and, finding none on
-- the second fire, INSERTED another 'paid' row — the partner recorded as paid
-- twice for one transfer.
drop function if exists public.settlement_record_payment(bigint, numeric, text, text);
create or replace function public.settlement_record_payment(
  p_period_id bigint, p_amount numeric, p_reference text default null,
  p_note text default null, p_client_action_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  cfg public.settlement_config%rowtype;
  p   public.partner_settlement_periods%rowtype;
  v_queued bigint;
  v_prev jsonb;
begin
  if not public.is_admin() then return public._stl_denied(); end if;

  v_prev := public._idem_claim('settlement.payment', p_client_action_id);
  if v_prev is not null then return v_prev; end if;

  -- The lock the state check always assumed: two admins pressing Record at the
  -- same moment both used to read the same 'queued' row.
  select * into p from public.partner_settlement_periods where id = p_period_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_period'));
  end if;
  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.bad_amount'));
  end if;
  select * into cfg from public.settlement_config where id = 1;

  select id into v_queued from public.partner_settlement_payments
   where period_id = p_period_id and status = 'queued'
   order by id limit 1
   for update;

  if v_queued is not null then
    update public.partner_settlement_payments
       set status = 'paid', amount = p_amount,
           rzp_transfer_id = coalesce(nullif(p_reference,''), rzp_transfer_id),
           note = coalesce(p_note, note),
           client_action_id = coalesce(client_action_id, p_client_action_id),
           paid_at = now(), recorded_by = coalesce(auth.jwt() ->> 'email','admin')
     where id = v_queued;
  else
    insert into public.partner_settlement_payments
      (period_id, amount, method, status, rzp_transfer_id, reference, note, recorded_by,
       client_action_id)
    values (p_period_id, p_amount,
            case when coalesce(cfg.route_mode,'manual') = 'automatic' then 'razorpay_route' else 'manual' end,
            'paid',
            case when coalesce(cfg.route_mode,'manual') = 'automatic' then nullif(p_reference,'') end,
            case when coalesce(cfg.route_mode,'manual') = 'automatic' then null else nullif(p_reference,'') end,
            p_note, coalesce(auth.jwt() ->> 'email','admin'), p_client_action_id);
  end if;

  return public._idem_store_ok('settlement.payment', p_client_action_id,
    jsonb_build_object('ok', true, 'message', public._stl_c('route.recorded'),
                       'statement', public.settlement_statement(p_period_id)));
end $function$;

-- ── SETTLEMENT CLOSE (settle) ──────────────────────────────────────────────
-- It set status='settled' with no guard and then issued the period's GST tax
-- invoice. Fired twice, it raised a SECOND tax document for one settlement.
create or replace function public.settlement_settle(p_period_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_mode text; v_frozen boolean; v_inv jsonb; v_status text;
begin
  if not public.is_admin() then return public._stl_denied(); end if;

  select status into v_status from public.partner_settlement_periods
   where id = p_period_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_period'));
  end if;

  -- CHANGE #472 — already settled is a SUCCESS, not a second settlement.
  if v_status = 'settled' then
    return jsonb_build_object('ok', true, 'replayed', true,
      'message', public._stl_c('period.settled_msg'),
      'statement', public.settlement_statement(p_period_id));
  end if;

  select coalesce(route_mode,'manual') into v_mode from public.settlement_config where id = 1;
  select (state = 'disputed' and resolved_at is null) into v_frozen
    from public.partner_settlement_ack where period_id = p_period_id;

  if coalesce(v_frozen,false) and coalesce(v_mode,'manual') = 'automatic' then
    return jsonb_build_object('ok', false, 'error','disputed_frozen','tone','danger',
      'message', public._pop_c('ack.err_frozen_settle'),
      'statement', public.settlement_statement(p_period_id));
  end if;

  update public.partner_settlement_periods
     set status = 'settled', settled_at = now(),
         settled_by = coalesce(auth.jwt() ->> 'email','admin')
   where id = p_period_id and status <> 'settled';

  -- CHANGE #695 — the tax document the settlement always implied.
  begin
    v_inv := public._c695_issue(p_period_id, coalesce(auth.jwt() ->> 'email','admin'));
  exception when others then
    v_inv := jsonb_build_object('ok', false, 'error','issue_failed', 'message', sqlerrm);
  end;
  if coalesce((v_inv->>'ok')::boolean,false) then
    perform public.settlement_invoice_request((v_inv->>'invoice_id')::uuid);
  end if;

  return jsonb_build_object('ok', true, 'message', public._stl_c('period.settled_msg'),
                            'invoice', v_inv,
                            'statement', public.settlement_statement(p_period_id));
end $function$;

-- ── REFUND REQUEST ─────────────────────────────────────────────────────────
-- It capped the amount against what was collected minus what was already
-- refunded — a read — and then inserted. Two concurrent requests both read the
-- same headroom and both got a refund row.
drop function if exists public.refund_request(uuid, numeric, text, text, text, uuid, uuid);
create or replace function public.refund_request(
  p_order_id uuid, p_amount numeric, p_reason_code text default null,
  p_method text default null, p_note text default null,
  p_return_id uuid default null, p_cancellation_id uuid default null,
  p_client_action_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_max numeric; v_pay text; v_method text; v_id uuid; v_prev jsonb;
begin
  perform public._returns_guard();

  v_prev := public._idem_claim('refund.request', p_client_action_id);
  if v_prev is not null then return v_prev; end if;

  -- Lock the ORDER, so the cap below is computed against a headroom no other
  -- refund request can be spending at the same time.
  perform 1 from public.orders where id = p_order_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'order_not_found',
      'message', public._c('refunds.err_order_not_found'));
  end if;
  if coalesce(p_amount,0) <= 0 then
    return jsonb_build_object('ok', false, 'error', 'amount_invalid',
      'message', public._c('refunds.err_amount_invalid'));
  end if;

  -- THE CAP.
  v_max := greatest(public._order_collected(p_order_id)
                    - public._order_refunded(p_order_id), 0);
  if p_amount > v_max then
    return jsonb_build_object('ok', false, 'error', 'over_collected',
      'refundable', v_max,
      'message', public._cf('refunds.err_over_collected',
                   jsonb_build_object('max', public.inr_money(v_max))));
  end if;

  v_pay := public._order_rzp_payment_id(p_order_id);
  v_method := lower(coalesce(nullif(btrim(p_method),''),
                             case when v_pay is not null then 'razorpay' else 'manual_upi' end));
  if v_method not in ('razorpay','manual_upi') then
    return jsonb_build_object('ok', false, 'error', 'method_unknown',
      'message', public._c('refunds.err_method_unknown'));
  end if;
  if v_method = 'razorpay' and v_pay is null then
    return jsonb_build_object('ok', false, 'error', 'no_razorpay_payment',
      'message', public._c('refunds.err_no_rzp_payment'));
  end if;

  insert into public.refunds (
    order_id, amount, reason_code, note, method, status,
    provider_payment_id, return_id, cancellation_id, requested_by, client_action_id)
  values (
    p_order_id, round(p_amount,2), p_reason_code, p_note, v_method, 'pending',
    case when v_method = 'razorpay' then v_pay end,
    p_return_id, p_cancellation_id, auth.uid(), p_client_action_id)
  returning id into v_id;

  return public._idem_store_ok('refund.request', p_client_action_id,
    jsonb_build_object('ok', true, 'id', v_id, 'method', v_method,
      'amount', round(p_amount,2), 'amount_label', public.inr_money(round(p_amount,2)),
      'needs_provider_call', v_method = 'razorpay',
      'message', public._c('refunds.requested_toast')));
end $function$;

-- ── PAYMENT CLAIM DECISION ─────────────────────────────────────────────────
-- `if c.status <> 'open' then already_decided` is the right answer and was
-- read without a lock, so two reviewers could both see 'open'.
create or replace function public.admin_claim_decide(
  p_claim_id uuid, p_action text, p_amount numeric default null, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare c public.delivery_claims%rowtype; a public.delivery_claims%rowtype;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin')
     or not public.admin_can('admin.delivery_ops','write') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  select * into c from public.delivery_claims where id = p_claim_id for update;
  if c.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if c.status <> 'open' then
    return jsonb_build_object('ok',false,'error','already_decided','status',c.status);
  end if;

  if p_action = 'approve' then
    update public.delivery_claims
       set status='approved', amount = coalesce(p_amount, amount),
           reviewed_by=auth.uid(), reviewed_at=now()
     where id = p_claim_id;
  elsif p_action = 'reject' then
    update public.delivery_claims
       set status='rejected', reject_reason=nullif(btrim(coalesce(p_reason,'')),''),
           reviewed_by=auth.uid(), reviewed_at=now()
     where id = p_claim_id;
  else
    return jsonb_build_object('ok',false,'error','bad_action');
  end if;

  select * into a from public.delivery_claims where id = p_claim_id;
  perform public.audit_write('payment_claim.' || p_action, 'payment_claim',
            p_claim_id::text, to_jsonb(c), to_jsonb(a));

  return jsonb_build_object('ok',true,'claim_id',p_claim_id,'status',a.status);
end $function$;

-- ── the grants the new signatures need ─────────────────────────────────────
-- Dropping a function drops its grants with it, and a bare `revoke from anon`
-- would leave the implicit PUBLIC grant standing (the delivery-area lesson).
revoke all on function public.place_order_v2(uuid)                    from public, anon;
revoke all on function public._place_order_v2_core(uuid)              from public, anon;
revoke all on function public.refund_request(uuid, numeric, text, text, text, uuid, uuid, uuid) from public, anon;
revoke all on function public.sup_record_payment(uuid, text, numeric, text, text, text, text, jsonb, uuid) from public, anon;
revoke all on function public.partner_sup_record_payment(uuid, text, numeric, text, text, text, text, jsonb, uuid) from public, anon;
revoke all on function public._sup_record_payment_write(uuid, text, numeric, text, text, text, text, jsonb, text, uuid) from public, anon;
revoke all on function public.settlement_record_payment(bigint, numeric, text, text, uuid) from public, anon;

grant execute on function public.place_order_v2(uuid)                 to authenticated, service_role;
grant execute on function public._place_order_v2_core(uuid)           to authenticated, service_role;
grant execute on function public.refund_request(uuid, numeric, text, text, text, uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.sup_record_payment(uuid, text, numeric, text, text, text, text, jsonb, uuid) to authenticated, service_role;
grant execute on function public.partner_sup_record_payment(uuid, text, numeric, text, text, text, text, jsonb, uuid) to authenticated, service_role;
grant execute on function public._sup_record_payment_write(uuid, text, numeric, text, text, text, text, jsonb, text, uuid) to authenticated, service_role;
grant execute on function public.settlement_record_payment(bigint, numeric, text, text, uuid) to authenticated, service_role;
