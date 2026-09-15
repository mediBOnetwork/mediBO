-- CHANGE #304 (d) — payment_claims.payment_method must admit the checkout path.
-- #291 hit the identical wall adding 'razorpay_qr'. A verified Razorpay
-- Checkout / payment-link capture is a distinct method from the QR one on
-- purpose: the two are reported separately and only the QR set is what #300's
-- 53-event proof covers.
alter table public.payment_claims
  drop constraint if exists payment_claims_payment_method_check;
alter table public.payment_claims
  add constraint payment_claims_payment_method_check
  check (payment_method = any (array['online','cash','razorpay_qr','razorpay_checkout']));
