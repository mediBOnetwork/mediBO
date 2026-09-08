do $$
declare
  v_order uuid := '4e35305b-ba73-43e2-bc87-12c9244994c1';
  v_prep jsonb; v_att uuid; v_res jsonb; v_qr uuid; v_payid text;
begin
  -- A) payment.captured that belongs to NOBODY here is acknowledged, not 500
  v_res := public.rzp_webhook_apply(jsonb_build_object(
    'event','payment.captured','payload', jsonb_build_object('payment',
      jsonb_build_object('entity', jsonb_build_object('id','pay_stranger304','amount',100)))));
  assert (v_res->>'ok')::boolean and (v_res->>'ignored') = 'payment.captured'
     and (v_res->>'reason') = 'no_attempt', 'stranger capture: ' || v_res::text;
  raise notice 'A ok — foreign payment.captured ignored, never credited';

  -- B) payment_link.expired closes the attempt cleanly
  -- a live attempt already exists for this order, so close it first: this
  -- block is exercising the CLOSE paths, not the reuse path (proved elsewhere)
  update rzp_payment_attempt set status='expired'
   where order_id=v_order and status in ('pending','attempted');
  v_prep := public.rzp_checkout_prepare(v_order,'advance','sdk');
  v_att  := (v_prep->>'attempt_id')::uuid;
  assert v_att is not null, 'prepare reused instead of minting: ' || v_prep::text;
  perform public.rzp_checkout_store(v_att,'plink_EXP304','https://rzp.io/i/exp304',null);
  v_res := public.rzp_webhook_apply(jsonb_build_object(
    'event','payment_link.expired','payload', jsonb_build_object('payment_link',
      jsonb_build_object('entity', jsonb_build_object('id','plink_EXP304')))));
  assert (select status from rzp_payment_attempt where id=v_att) = 'expired',
         'not expired: ' || (select status from rzp_payment_attempt where id=v_att);
  assert (public._rzp_attempt_view(v_att)->>'failure_label') = 'This payment link has expired. Start a new one.',
         'expired copy missing';
  raise notice 'B ok — expired attempt closes with the backend''s own words';

  -- C) payment.failed marks failed, and the attempt is then NOT resumable
  -- a live attempt already exists for this order, so close it first: this
  -- block is exercising the CLOSE paths, not the reuse path (proved elsewhere)
  update rzp_payment_attempt set status='expired'
   where order_id=v_order and status in ('pending','attempted');
  v_prep := public.rzp_checkout_prepare(v_order,'advance','sdk');
  v_att  := (v_prep->>'attempt_id')::uuid;
  assert v_att is not null, 'prepare reused instead of minting: ' || v_prep::text;
  perform public.rzp_checkout_store(v_att,'plink_FAIL304','https://rzp.io/i/fail304',null);
  v_res := public.rzp_webhook_apply(jsonb_build_object(
    'event','payment.failed','payload', jsonb_build_object(
      'payment_link', jsonb_build_object('entity', jsonb_build_object('id','plink_FAIL304')),
      'payment', jsonb_build_object('entity', jsonb_build_object(
        'id','pay_fail304','error_description','UPI timed out')))));
  assert (select status from rzp_payment_attempt where id=v_att) = 'failed', 'not failed';
  assert (public._rzp_attempt_view(v_att)->>'resumable')::boolean is false, 'failed must not be resumable';
  assert (select failure_reason from rzp_payment_attempt where id=v_att) = 'UPI timed out',
         'reason not carried';
  raise notice 'C ok — failed attempt carries Razorpay''s own reason';

  -- D) REGRESSION: #291/#300's QR path is untouched by the splice
  insert into razorpay_qr (order_id, rzp_qr_id, image_url, amount, kind, status)
  values (v_order,'qr_c304regress','https://x/y',52.76,'advance','active') returning id into v_qr;
  v_payid := 'pay_qr304regress';
  v_res := public.rzp_webhook_apply(jsonb_build_object(
    'event','qr_code.credited','payload', jsonb_build_object(
      'qr_code', jsonb_build_object('entity', jsonb_build_object('id','qr_c304regress',
        'notes', jsonb_build_object('order_id', v_order::text))),
      'payment', jsonb_build_object('entity', jsonb_build_object(
        'id', v_payid,'amount',5276,'method','upi')))));
  assert (v_res->>'ok')::boolean and (v_res->>'payment_id') = v_payid, 'qr path broke: ' || v_res::text;
  assert (select status from razorpay_qr where id=v_qr) = 'paid', 'qr not paid';
  assert (select payment_method from payment_claims where utr=v_payid) = 'razorpay_qr',
         'qr claim method changed';
  raise notice 'D ok — the QR path #300 proved on 53 events still credits as razorpay_qr';

  -- E) a checkout event may never double-credit a payment the QR path banked
  v_res := public.rzp_webhook_apply(jsonb_build_object(
    'event','payment.captured','payload', jsonb_build_object(
      'payment_link', jsonb_build_object('entity', jsonb_build_object('id','plink_FAIL304')),
      'payment', jsonb_build_object('entity', jsonb_build_object('id', v_payid,'amount',5276)))));
  assert (v_res->>'duplicate')::boolean, 'cross-method double credit: ' || v_res::text;
  assert (select count(*) from payment_claims where utr=v_payid) = 1, 'two claims for one payment';
  raise notice 'E ok — one payment id, one claim, across BOTH razorpay methods';

  raise notice 'ALL 5 WEBHOOK CHECKS PASSED';
  raise exception 'C304_WH_ROLLBACK_OK';
end $$;
