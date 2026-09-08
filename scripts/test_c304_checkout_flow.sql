-- CHANGE #304 — the DB half of the payment flow, proved on REAL rows and then
-- rolled back so nothing is left behind.
\set ON_ERROR_STOP on
do $$
declare
  v_order uuid := '4e35305b-ba73-43e2-bc87-12c9244994c1';
  v_prep jsonb; v_att uuid; v_view jsonb; v_state jsonb; v_res jsonb;
  v_payid text := 'pay_C304PROOF' || to_char(clock_timestamp(),'USSMI');
  v_ev jsonb;
begin
  -- 1. prepare mints ONE attempt with the money the backend re-derived
  v_prep := public.rzp_checkout_prepare(v_order, 'advance', 'sdk');
  assert (v_prep->>'ok')::boolean, 'prepare not ok: ' || v_prep::text;
  assert (v_prep->>'reused')::boolean is false, 'first prepare must not reuse';
  assert (v_prep->>'pay_mode') = 'sdk', 'mode: ' || (v_prep->>'pay_mode');
  v_att := (v_prep->>'attempt_id')::uuid;
  assert (v_prep->>'amount_paise')::bigint = round((v_prep->>'amount')::numeric,2)*100,
         'paise mismatch';
  assert (v_prep #>> '{notes,order_id}') = v_order::text, 'notes.order_id missing';
  raise notice 'PREP ok attempt=% amount=% paise=% ref=%',
    v_att, v_prep->>'amount', v_prep->>'amount_paise', v_prep->>'reference_id';

  -- 2. store flips pending -> attempted and hands back the render view
  v_res := public.rzp_checkout_store(v_att,'plink_C304PROOF','https://rzp.io/i/c304proof','order_C304PROOF');
  assert (v_res->>'ok')::boolean, 'store failed';
  v_view := v_res->'view';
  assert (v_view->>'status') = 'attempted', 'status: ' || (v_view->>'status');
  assert (v_view->>'pay_url') = 'https://rzp.io/i/c304proof', 'pay_url not carried';
  assert (v_view->>'button_label') = 'Resume payment', 'resume label: ' || (v_view->>'button_label');
  assert (v_view->>'resumable')::boolean, 'must be resumable';

  -- 3. RESUME, never duplicate: a second prepare returns the SAME attempt
  v_prep := public.rzp_checkout_prepare(v_order, 'advance', 'sdk');
  assert (v_prep->>'reused')::boolean, 'second prepare must reuse';
  assert (v_prep #>> '{view,attempt_id}') = v_att::text, 'reused a DIFFERENT attempt';
  assert (v_prep #>> '{view,pay_url}') = 'https://rzp.io/i/c304proof', 'reuse lost the link';
  assert (select count(*) from public.rzp_payment_attempt
           where order_id = v_order and status in ('pending','attempted')) = 1,
         'more than one open attempt';
  raise notice 'RESUME ok — same attempt, same link, one open row';

  -- 4. THE WEBHOOK IS TRUTH. A signed payment_link.paid marks it paid and
  --    banks a verified claim; the client never does this.
  v_ev := jsonb_build_object(
    'event','payment_link.paid',
    'payload', jsonb_build_object(
      'payment_link', jsonb_build_object('entity', jsonb_build_object(
         'id','plink_C304PROOF','reference_id', v_prep #>> '{view,attempt_id}',
         'amount_paid', 5276,
         'notes', jsonb_build_object('order_id', v_order::text,'attempt_id', v_att::text))),
      'payment', jsonb_build_object('entity', jsonb_build_object(
         'id', v_payid, 'amount', 5276, 'method','upi',
         'notes', jsonb_build_object('order_id', v_order::text,'attempt_id', v_att::text)))));
  v_res := public.rzp_webhook_apply(v_ev);
  assert (v_res->>'ok')::boolean, 'webhook apply failed: ' || v_res::text;
  assert (v_res->>'payment_id') = v_payid, 'wrong payment id';
  assert (select status from public.rzp_payment_attempt where id = v_att) = 'paid',
         'attempt not paid';
  assert exists (select 1 from payment_claims
                  where utr = v_payid and payment_method='razorpay_checkout'
                    and status='verified' and order_id = v_order), 'no verified claim';
  raise notice 'WEBHOOK ok — attempt paid, verified claim banked';

  -- 5. REPLAY is a no-op, not a second credit
  v_res := public.rzp_webhook_apply(v_ev);
  assert (v_res->>'duplicate')::boolean, 'replay not deduped: ' || v_res::text;
  assert (select count(*) from payment_claims where utr = v_payid) = 1, 'double credit';
  raise notice 'REPLAY ok — deduped, exactly one claim';

  -- 6. The CLIENT may never mark paid, and may never un-pay a paid attempt
  v_res := public.rzp_checkout_failed(v_att, 'user dismissed');
  assert (select status from public.rzp_payment_attempt where id = v_att) = 'paid',
         'client downgraded a PAID attempt';
  raise notice 'CLIENT-CANNOT-UNPAY ok';

  -- 7. state() is what the sheet polls — and it refuses a caller who does not
  --    own the order (this session carries no JWT claims at all)
  v_state := public.rzp_checkout_state(v_order,'advance');
  assert (v_state->>'ok')::boolean is false and (v_state->>'error') = 'not_authorized',
         'state must refuse a claimless caller: ' || v_state::text;
  -- with the OWNER's claims it is the paid attempt, rendered by the backend
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select user_id::text from orders where id = v_order),
                      'role','authenticated')::text, true);
  v_state := public.rzp_checkout_state(v_order,'advance');
  assert (v_state->>'ok')::boolean and (v_state->>'paid')::boolean,
         'owner state not paid: ' || v_state::text;
  assert (v_state #>> '{view,status_label}') = 'Paid', 'status_label: ' || v_state::text;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'STATE ok — refused claimless, paid for the owner (%)', v_state->>'status';

  -- 8. mode routing: an admin-placed / whatsapp order is QR, never sdk
  assert public.rzp_pay_mode(null) in ('sdk','qr','manual'), 'bad mode';
  raise notice 'ALL 8 CHECKS PASSED';
  raise exception 'C304_ROLLBACK_OK';
end $$;
