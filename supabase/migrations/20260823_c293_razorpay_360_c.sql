-- CHANGE #293 — Part C: the webhook, the QR gate, and the checkout paths.

-- ── the QR gate reads the ONE switch ──────────────────────────────────────
create or replace function public.rzp_qr_prepare(p_order_id uuid, p_kind text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_enabled boolean; v_hours integer; v_kind text;
  v_amount numeric;  v_code text; v_open public.razorpay_qr%rowtype;
begin
  v_enabled := (public.payment_collection_mode() = 'gateway');
  select greatest(coalesce(razorpay_close_hours,24),1) into v_hours
    from payment_config where id = 1;
  v_hours := coalesce(v_hours, 24);

  if not v_enabled then
    return jsonb_build_object('ok', false, 'enabled', false, 'provider', 'upi_manual');
  end if;

  select order_code into v_code from orders where id = p_order_id;
  if v_code is null then
    return jsonb_build_object('ok', false, 'enabled', true, 'error', 'order_not_found');
  end if;

  v_kind   := case when lower(coalesce(p_kind,'advance')) = 'advance' then 'advance' else 'balance' end;
  v_amount := public.rzp_amount_due(p_order_id, v_kind);

  if v_amount <= 0 then
    return jsonb_build_object('ok', false, 'enabled', true, 'error', 'nothing_due',
                              'message', public._rzp_copy('nothing_due_label'));
  end if;

  -- NEVER a second QR for the same order+kind while one is still open.
  select * into v_open from public.razorpay_qr
   where order_id = p_order_id and kind = v_kind and status = 'active'
     and round(amount,2) = round(v_amount,2)
     and created_at > now() - make_interval(hours => v_hours)
   order by created_at desc limit 1;

  if found then
    return jsonb_build_object('ok', true, 'enabled', true, 'reused', true,
                              'view', public.rzp_qr_view(v_open.id));
  end if;

  return jsonb_build_object(
    'ok', true, 'enabled', true, 'reused', false,
    'kind', v_kind,
    'order_code', v_code,
    'amount', v_amount,
    'amount_paise', (round(v_amount, 2) * 100)::bigint,
    'close_by', (extract(epoch from (now() + make_interval(hours => v_hours))))::bigint,
    'description', 'mediBO ' || v_code || ' — ' ||
                   case when v_kind = 'advance' then 'advance' else 'balance' end,
    'notes', jsonb_build_object('order_id', p_order_id::text, 'order_code', v_code, 'kind', v_kind)
  );
end $function$;

-- ── the webhook: log EVERY event, handle two, ignore 53 quietly ───────────
create or replace function public.rzp_webhook_apply(p_event jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_event text := p_event->>'event';
  v_qr    jsonb := p_event #> '{payload,qr_code,entity}';
  v_pay   jsonb := p_event #> '{payload,payment,entity}';
  v_qrid  text  := v_qr->>'id';
  v_payid text  := v_pay->>'id';
  v_order uuid;
  v_amount numeric;
  v_row   public.razorpay_qr%rowtype;
  v_claim uuid; v_ph text; v_owner uuid;
  v_out jsonb;
  v_log bigint;
begin
  -- 1. RECORD FIRST. Every one of Razorpay's 55 events lands here, handled or
  --    not, so a "the webhook never fired" argument is always answerable.
  insert into public.razorpay_webhook_log (event, rzp_event_id, payload_id, handled)
  values (coalesce(v_event,'(none)'),
          nullif(btrim(coalesce(p_event->>'id','')),''),
          coalesce(v_payid, v_qrid),
          false)
  returning id into v_log;

  -- cheap retention, no cron job to collide on minute 0
  delete from public.razorpay_webhook_log where received_at < now() - interval '30 days';

  -- 2. qr_code.closed — the QR expired or was closed without being paid.
  if v_event = 'qr_code.closed' then
    update public.razorpay_qr
       set status = case when status = 'paid' then 'paid' else 'closed' end,
           closed_reason = coalesce(v_qr->>'close_reason', 'closed')
     where rzp_qr_id = v_qrid;
    v_out := jsonb_build_object('ok', true, 'closed', true, 'qr_id', v_qrid);
    update public.razorpay_webhook_log set handled = true, result = v_out where id = v_log;
    return v_out;
  end if;

  -- 3. Anything that is not a credit is acknowledged and dropped. Returning
  --    ok:true keeps the edge function on HTTP 200, which is what stops
  --    Razorpay retrying and eventually disabling the endpoint.
  if v_event is distinct from 'qr_code.credited' then
    v_out := jsonb_build_object('ok', true, 'ignored', coalesce(v_event,'(none)'));
    update public.razorpay_webhook_log set result = v_out where id = v_log;
    return v_out;
  end if;

  if nullif(btrim(coalesce(v_payid,'')),'') is null then
    v_out := jsonb_build_object('ok', false, 'error', 'no_payment_id');
    update public.razorpay_webhook_log set result = v_out where id = v_log;
    return v_out;
  end if;

  -- 4. Idempotent on the Razorpay payment id.
  if exists (select 1 from payment_claims
              where utr = v_payid and payment_method = 'razorpay_qr') then
    v_out := jsonb_build_object('ok', true, 'duplicate', true, 'payment_id', v_payid);
    update public.razorpay_webhook_log set handled = true, result = v_out where id = v_log;
    return v_out;
  end if;

  v_order := nullif(coalesce(v_qr #>> '{notes,order_id}', v_pay #>> '{notes,order_id}'), '')::uuid;
  select * into v_row from public.razorpay_qr where rzp_qr_id = v_qrid;
  if v_order is null then v_order := v_row.order_id; end if;
  if v_order is null then
    v_out := jsonb_build_object('ok', false, 'error', 'unmatched_order', 'qr_id', v_qrid);
    update public.razorpay_webhook_log set result = v_out where id = v_log;
    return v_out;
  end if;

  v_amount := round(coalesce((v_pay->>'amount')::numeric, 0) / 100.0, 2);

  update public.razorpay_qr
     set status = 'paid', payment_id = v_payid, paid_at = now(),
         closed_reason = coalesce(v_qr->>'close_reason', 'paid')
   where rzp_qr_id = v_qrid;

  select o.user_id into v_owner from orders o where o.id = v_order;
  select right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone,''),'\D','','g'),10)
    into v_ph from pharmacy_profiles pp
   where pp.user_id = v_owner and coalesce(pp.is_deleted,false) = false limit 1;

  -- zone_id / business_date are stamped by trg_payment_claim_scope from the order
  insert into payment_claims (
    order_id, sender_phone, sender_type, amount, utr, txn_id, app,
    payee_name, status, verify_reason, payment_method, received_at, created_at)
  values (
    v_order, v_ph, 'customer', v_amount, v_payid, v_payid,
    coalesce(v_pay->>'method','upi'), 'Razorpay', 'verified',
    public._rzp_copy('claim_reason'), 'razorpay_qr', now(), now())
  returning id into v_claim;

  update orders
     set status = 'accepted',
         payment_id = v_payid
   where id = v_order and coalesce(status,'') <> 'accepted';

  v_out := jsonb_build_object('ok', true, 'order_id', v_order, 'claim_id', v_claim,
                              'payment_id', v_payid, 'amount', v_amount);
  update public.razorpay_webhook_log set handled = true, result = v_out where id = v_log;
  return v_out;
exception
  when unique_violation then
    v_out := jsonb_build_object('ok', true, 'duplicate', true, 'payment_id', v_payid);
    return v_out;
end $function$;

-- Admin-facing tail of the webhook log, rendered verbatim.
create or replace function public.rzp_webhook_log_recent(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    raise exception 'not_authorized';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'event', l.event,
           'handled', l.handled,
           'payload_id', coalesce(l.payload_id,''),
           'at_label', to_char(l.received_at at time zone 'Asia/Kolkata','DD Mon, FMHH12:MI am'))
         order by l.received_at desc), '[]'::jsonb)
    into v
    from (select * from public.razorpay_webhook_log
           order by received_at desc limit greatest(coalesce(p_limit,20),1)) l;
  return jsonb_build_object('ok', true, 'rows', v);
end $function$;

-- ── the acting-as / WhatsApp path mints the QR server-side ────────────────
-- One place decides it, so the customer app, the admin write-as screen and the
-- WhatsApp lane cannot drift apart.
create or replace function public.rzp_send_order_qr_wa(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_ph text; v_owner uuid; v_due numeric;
begin
  if public.payment_collection_mode() <> 'gateway' then
    return jsonb_build_object('ok', false, 'error', 'not_gateway_mode');
  end if;
  select o.user_id into v_owner from orders o where o.id = p_order_id;
  if v_owner is null then return jsonb_build_object('ok', false, 'error','no_order'); end if;

  v_due := public.rzp_amount_due(p_order_id, 'advance');
  if coalesce(v_due,0) <= 0 then
    return jsonb_build_object('ok', false, 'error','nothing_due');
  end if;

  select right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone,''),'\D','','g'),10)
    into v_ph from pharmacy_profiles pp
   where pp.user_id = v_owner and coalesce(pp.is_deleted,false) = false limit 1;
  if length(coalesce(v_ph,'')) <> 10 then
    return jsonb_build_object('ok', false, 'error','bad_phone');
  end if;

  return public._send_payment_qr_wa_auto(p_order_id, v_ph, v_due, 'advance');
end $function$;

-- The admin order payment panel reads the SAME switch as the customer sheet, so
-- an admin can never be looking at a mode the platform is not in.
create or replace function public.admin_order_payment_view_v2(p_order_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select d || public.money_display_block(d, array[
           'total','due','paid','amount','balance','order_total','net_payable',
           'advance_required','claimed_amount','ocr_amount','app_amount'])
           || jsonb_build_object('collection', public.rzp_panel_block())
  from (select public.admin_order_payment_view(p_order_id) d) z;
$function$;
