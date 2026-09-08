CREATE OR REPLACE FUNCTION public.rzp_webhook_apply(p_event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_n   integer;
begin
  -- 1. RECORD FIRST. Every one of Razorpay's ticked events lands here, handled
  --    or not, so a "the webhook never fired" argument is always answerable.
  insert into public.razorpay_webhook_log (event, rzp_event_id, payload_id, handled)
  values (coalesce(v_event,'(none)'),
          nullif(btrim(coalesce(p_event->>'id','')),''),
          coalesce(v_payid, v_qrid),
          false)
  returning id into v_log;

  -- cheap retention, no cron job to collide on minute 0
  delete from public.razorpay_webhook_log where received_at < now() - interval '30 days';

  -- 2. qr_code.closed — the QR expired or was closed. A PAID QR is read-only
  --    here: neither its status nor its reason may be rewritten by a close that
  --    arrives after the money did.
  if v_event = 'qr_code.closed' then
    with upd as (
      update public.razorpay_qr
         set status        = case when status = 'paid' then 'paid' else 'closed' end,
             closed_reason = case when status = 'paid' then closed_reason
                                  else coalesce(v_qr->>'close_reason', 'closed') end
       where rzp_qr_id = v_qrid
      returning 1
    )
    select count(*) into v_n from upd;
    v_out := jsonb_build_object('ok', true, 'closed', v_n > 0,
                                'matched', v_n, 'qr_id', v_qrid);
    update public.razorpay_webhook_log
       set handled = (v_n > 0), result = v_out where id = v_log;
    return v_out;
  end if;

  -- ── CHANGE #304 — the CHECKOUT/payment-link events ────────────────────────
  -- The webhook is truth for the SDK path exactly as it is for the QR path.
  -- Matched to an attempt row (link id / reference_id / rzp order id / notes),
  -- and credited through the one shared, doubly-idempotent credit path.
  if v_event in ('payment_link.paid','payment_link.expired','payment_link.cancelled',
                 'payment.captured','payment.failed') then
    declare
      v_link jsonb := p_event #> '{payload,payment_link,entity}';
      v_att  uuid  := public._rzp_attempt_match(
                        coalesce(p_event #> '{payload,payment_link,entity}','{}'::jsonb),
                        coalesce(v_pay,'{}'::jsonb));
      v_ord  uuid;
      v_amt  numeric;
    begin
      -- A payment.captured with no attempt of ours is somebody else's event
      -- (the QR path raises its own qr_code.credited) — acknowledge and drop.
      if v_att is null and v_event in ('payment.captured','payment.failed') then
        v_out := jsonb_build_object('ok', true, 'ignored', v_event, 'reason','no_attempt');
        update public.razorpay_webhook_log set result = v_out where id = v_log;
        return v_out;
      end if;

      if v_event in ('payment_link.expired','payment_link.cancelled') then
        update public.rzp_payment_attempt
           set status = case when status = 'paid' then 'paid' else 'expired' end,
               failure_reason = case when status = 'paid' then failure_reason
                                     else replace(v_event,'payment_link.','') end
         where id = v_att;
        v_out := jsonb_build_object('ok', true, 'attempt_id', v_att, 'event', v_event);
        update public.razorpay_webhook_log set handled = (v_att is not null), result = v_out
         where id = v_log;
        return v_out;
      end if;

      if v_event = 'payment.failed' then
        update public.rzp_payment_attempt
           set status = case when status = 'paid' then 'paid' else 'failed' end,
               failure_reason = case when status = 'paid' then failure_reason
                                     else left(coalesce(v_pay->>'error_description','failed'),200) end
         where id = v_att;
        v_out := jsonb_build_object('ok', true, 'attempt_id', v_att, 'event', v_event);
        update public.razorpay_webhook_log set handled = true, result = v_out where id = v_log;
        return v_out;
      end if;

      -- payment_link.paid / payment.captured => money landed.
      if nullif(btrim(coalesce(v_payid,'')),'') is null then
        v_out := jsonb_build_object('ok', false, 'error','no_payment_id', 'event', v_event);
        update public.razorpay_webhook_log set result = v_out where id = v_log;
        return v_out;
      end if;

      v_ord := nullif(coalesce(v_link #>> '{notes,order_id}',
                               v_pay  #>> '{notes,order_id}'), '')::uuid;
      if v_ord is null and v_att is not null then
        select order_id into v_ord from public.rzp_payment_attempt where id = v_att;
      end if;
      v_amt := round(coalesce((v_pay->>'amount')::numeric,
                              (v_link->>'amount_paid')::numeric, 0) / 100.0, 2);

      v_out := public._rzp_checkout_credit(v_att, v_ord, v_payid, v_amt, v_pay->>'method');
      update public.razorpay_webhook_log
         set handled = coalesce((v_out->>'ok')::boolean,false), result = v_out where id = v_log;
      return v_out;
    end;
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

  -- zone_id / business_date are stamped by trg_payment_claim_scope from the order.
  -- Its own sub-block: a racing duplicate must not roll back the log row above.
  begin
    insert into payment_claims (
      order_id, sender_phone, sender_type, amount, utr, txn_id, app,
      payee_name, status, verify_reason, payment_method, received_at, created_at)
    values (
      v_order, v_ph, 'customer', v_amount, v_payid, v_payid,
      coalesce(v_pay->>'method','upi'), 'Razorpay', 'verified',
      public._rzp_copy('claim_reason'), 'razorpay_qr', now(), now())
    returning id into v_claim;
  exception
    when unique_violation then
      v_out := jsonb_build_object('ok', true, 'duplicate', true, 'payment_id', v_payid);
      update public.razorpay_webhook_log set handled = true, result = v_out where id = v_log;
      return v_out;
  end;

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
    -- the outer block rolled the log insert back with it — re-record the delivery
    v_out := jsonb_build_object('ok', true, 'duplicate', true, 'payment_id', v_payid);
    insert into public.razorpay_webhook_log (event, rzp_event_id, payload_id, handled, result)
    values (coalesce(v_event,'(none)'),
            nullif(btrim(coalesce(p_event->>'id','')),''),
            coalesce(v_payid, v_qrid), true, v_out);
    return v_out;
end $function$

;
