-- CHANGE #304 (b) — the webhook is TRUTH, the client callback is only speed.
--
-- The SDK/hosted-checkout return is a UI hint and nothing more: an order is
-- marked paid here, from a delivery Razorpay signed, or it is not marked paid
-- at all. If the app dies mid-payment the webhook still completes the order.
--
-- Spliced onto the LIVE rzp_webhook_apply (#291 -> #293 -> #300) so the QR
-- branch that #300 proved against 53 real events is untouched, byte for byte.

-- ── The poll the sheet uses, and the order-level answer ─────────────────────
create or replace function public.rzp_checkout_state(p_order_id uuid, p_kind text default 'advance')
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_ok boolean; v_kind text; a public.rzp_payment_attempt%rowtype;
begin
  select (o.user_id = any (public.my_owner_user_ids())
          or o.customer_id is not distinct from public.my_customer_id()
          or public.get_my_role() in ('admin','super_admin'))
    into v_ok from orders o where o.id = p_order_id;
  if not coalesce(v_ok,false) then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;

  v_kind := case when lower(coalesce(p_kind,'advance')) = 'advance' then 'advance' else 'balance' end;
  select * into a from public.rzp_payment_attempt
   where order_id = p_order_id and kind = v_kind
   order by (status = 'paid') desc, created_at desc limit 1;

  if not found then
    return jsonb_build_object('ok', true, 'paid', false, 'has_attempt', false,
                              'pay_mode', public.rzp_pay_mode(p_order_id));
  end if;
  return jsonb_build_object(
    'ok', true, 'has_attempt', true,
    'paid', (a.status = 'paid'),
    'status', a.status,
    'pay_mode', public.rzp_pay_mode(p_order_id),
    'view', public._rzp_attempt_view(a.id),
    'paid_toast', public._rzp_copy('checkout_paid_toast'));
end $$;

-- ── The ONE credit path for a checkout/link payment ────────────────────────
-- Idempotent on the Razorpay payment id across BOTH razorpay methods, so a
-- payment that arrives as qr_code.credited and again as payment.captured is
-- banked exactly once.
create or replace function public._rzp_checkout_credit(
  p_attempt uuid, p_order uuid, p_payid text, p_amount numeric, p_method text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_claim uuid; v_ph text; v_owner uuid;
begin
  if exists (select 1 from payment_claims
              where utr = p_payid and payment_method like 'razorpay%') then
    if p_attempt is not null then
      update public.rzp_payment_attempt
         set status='paid', rzp_payment_id = coalesce(rzp_payment_id, p_payid),
             paid_at = coalesce(paid_at, now())
       where id = p_attempt and status <> 'paid';
    end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'payment_id', p_payid);
  end if;

  if p_order is null then
    return jsonb_build_object('ok', false, 'error','unmatched_order', 'payment_id', p_payid);
  end if;

  if p_attempt is not null then
    update public.rzp_payment_attempt
       set status='paid', rzp_payment_id = p_payid, paid_at = now()
     where id = p_attempt;
  end if;

  select o.user_id into v_owner from orders o where o.id = p_order;
  select right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone,''),'\D','','g'),10)
    into v_ph from pharmacy_profiles pp
   where pp.user_id = v_owner and coalesce(pp.is_deleted,false) = false limit 1;

  begin
    insert into payment_claims (
      order_id, sender_phone, sender_type, amount, utr, txn_id, app,
      payee_name, status, verify_reason, payment_method, received_at, created_at)
    values (
      p_order, v_ph, 'customer', p_amount, p_payid, p_payid,
      coalesce(nullif(p_method,''),'upi'), 'Razorpay', 'verified',
      public._rzp_copy('claim_reason_sdk'), 'razorpay_checkout', now(), now())
    returning id into v_claim;
  exception when unique_violation then
    return jsonb_build_object('ok', true, 'duplicate', true, 'payment_id', p_payid);
  end;

  update orders set status = 'accepted', payment_id = p_payid
   where id = p_order and coalesce(status,'') <> 'accepted';

  return jsonb_build_object('ok', true, 'order_id', p_order, 'claim_id', v_claim,
                            'payment_id', p_payid, 'amount', p_amount,
                            'attempt_id', p_attempt);
end $$;

-- ── Resolve which attempt a checkout event is about ─────────────────────────
create or replace function public._rzp_attempt_match(p_link jsonb, p_pay jsonb)
returns uuid language sql stable security definer set search_path to 'public' as $$
  select a.id from public.rzp_payment_attempt a
   where (nullif(p_link->>'id','')          is not null and a.rzp_link_id  = p_link->>'id')
      or (nullif(p_link->>'reference_id','')is not null and a.reference_id = p_link->>'reference_id')
      or (nullif(p_pay->>'order_id','')     is not null and a.rzp_order_id = p_pay->>'order_id')
      or (nullif(coalesce(p_link #>> '{notes,attempt_id}', p_pay #>> '{notes,attempt_id}'),'') is not null
          and a.id = nullif(coalesce(p_link #>> '{notes,attempt_id}', p_pay #>> '{notes,attempt_id}'),'')::uuid)
   order by a.created_at desc limit 1;
$$;
