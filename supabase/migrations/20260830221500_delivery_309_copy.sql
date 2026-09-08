-- CHANGE #309 — every word the delivery module's ten new features print.
--
-- Rule: a display string written in Dart is a bug. All of it lives here, so
-- changing the wording is an UPDATE, never a deploy. Keys are namespaced by the
-- surface that prints them (delivery.*, checkout.*, admin.delivery.*) so the
-- ui_copy table stays browsable at 2 700+ keys.
--
-- Idempotent: re-running only refreshes the text, never duplicates a key.

insert into public.ui_copy(key, value) values
  -- (1) handover scan
  ('delivery.handover_bad_qr_title',        to_jsonb('Unknown code'::text)),
  ('delivery.handover_bad_qr_msg',          to_jsonb('This code does not match any parcel.'::text)),
  ('delivery.handover_denied_title',        to_jsonb('Not allowed'::text)),
  ('delivery.handover_denied_msg',          to_jsonb('Only the assigned rider or warehouse staff can take this parcel.'::text)),
  ('delivery.handover_not_accepted_title',  to_jsonb('Not accepted yet'::text)),
  ('delivery.handover_not_accepted_msg',    to_jsonb('Accept this delivery before taking the parcel.'::text)),
  ('delivery.handover_already_title',       to_jsonb('Already collected'::text)),
  ('delivery.handover_already_msg',         to_jsonb('This parcel was handed over on {when}.'::text)),
  ('delivery.handover_ok_title',            to_jsonb('Parcel collected'::text)),
  ('delivery.handover_ok_msg',              to_jsonb('Custody recorded for {who}. The stop is now out for delivery.'::text)),
  ('delivery.handover_required_title',      to_jsonb('Scan the parcel first'::text)),
  ('delivery.handover_required_msg',        to_jsonb('Scan the parcel at the warehouse to take custody before completing this delivery.'::text)),
  ('delivery.handover_button',              to_jsonb('Scan parcel'::text)),
  ('delivery.handover_pending_chip',        to_jsonb('Not collected'::text)),
  ('delivery.handover_done_chip',           to_jsonb('Collected'::text)),
  ('delivery.handover_section_title',       to_jsonb('Parcel custody'::text)),
  ('delivery.handover_scan_hint',           to_jsonb('Scan the QR on the parcel, or enter the code printed under it.'::text)),
  ('delivery.handover_manual_label',        to_jsonb('Parcel code'::text)),
  ('delivery.handover_submit',              to_jsonb('Take custody'::text)),

  -- (2) SLA / promise
  ('delivery.promise_label',                to_jsonb('Promised by'::text)),
  ('delivery.promise_ontime_chip',          to_jsonb('On time'::text)),
  ('delivery.promise_breached_chip',        to_jsonb('Late'::text)),
  ('delivery.promise_due_soon_chip',        to_jsonb('Due soon'::text)),
  ('delivery.promise_none',                 to_jsonb('No promise set'::text)),

  -- (3) delivery charge
  ('delivery.charge_line_label',            to_jsonb('Delivery charge'::text)),
  ('delivery.charge_free_label',            to_jsonb('Free delivery'::text)),
  ('delivery.charge_free_note',             to_jsonb('Free on orders above {threshold}'::text)),
  ('delivery.charge_note',                  to_jsonb('Add {shortfall} more for free delivery'::text)),

  -- (4) payouts
  ('admin.delivery.payout_title',           to_jsonb('Rider payouts'::text)),
  ('admin.delivery.payout_empty',           to_jsonb('No payout periods yet. Open a period to start collecting drops.'::text)),
  ('admin.delivery.payout_open_btn',        to_jsonb('Open period'::text)),
  ('admin.delivery.payout_pay_btn',         to_jsonb('Mark paid'::text)),
  ('admin.delivery.payout_paid_chip',       to_jsonb('Paid'::text)),
  ('admin.delivery.payout_unpaid_chip',     to_jsonb('Unpaid'::text)),
  ('admin.delivery.payout_already_paid',    to_jsonb('This payout is already paid — nothing was charged twice.'::text)),
  ('admin.delivery.payout_statement_title', to_jsonb('Statement'::text)),

  -- (5) serviceability
  ('checkout.serviceable_ok',               to_jsonb('We deliver to your pincode.'::text)),
  ('checkout.serviceable_warn_title',       to_jsonb('Outside our usual delivery area'::text)),
  ('checkout.serviceable_warn_msg',         to_jsonb('We do not normally deliver to {pincode}. You can still order — we will call to confirm.'::text)),
  ('checkout.serviceable_blocked_title',    to_jsonb('We do not deliver here yet'::text)),
  ('checkout.serviceable_blocked_msg',      to_jsonb('{pincode} is outside our delivery area. Please contact us before ordering.'::text)),
  ('checkout.serviceable_no_pincode',       to_jsonb('Add a pincode to your profile so we can check delivery.'::text)),
  ('admin.delivery.service_title',          to_jsonb('Pincode serviceability'::text)),
  ('admin.delivery.service_empty',          to_jsonb('No pincodes listed. Unlisted pincodes follow the default rule.'::text)),
  ('admin.delivery.service_add_btn',        to_jsonb('Add pincode'::text)),

  -- (6) document expiry
  ('admin.delivery.docs_title',             to_jsonb('Rider documents'::text)),
  ('admin.delivery.docs_empty',             to_jsonb('No expiry dates recorded yet.'::text)),
  ('delivery.doc_expired_chip',             to_jsonb('Expired'::text)),
  ('delivery.doc_expiring_chip',            to_jsonb('Expiring'::text)),
  ('delivery.doc_ok_chip',                  to_jsonb('Valid'::text)),
  ('delivery.doc_blocked_title',            to_jsonb('Documents expired'::text)),
  ('delivery.doc_blocked_msg',              to_jsonb('{name} cannot be assigned — {docs} expired.'::text)),
  ('delivery.doc_remind_msg',               to_jsonb('{docs} expires on {date}. Please renew.'::text)),
  ('delivery.doc_dl_label',                 to_jsonb('Driving licence'::text)),
  ('delivery.doc_insurance_label',          to_jsonb('Insurance'::text)),
  ('delivery.doc_rc_label',                 to_jsonb('Registration (RC)'::text)),

  -- (7) rating
  ('delivery.rate_title',                   to_jsonb('How was the delivery?'::text)),
  ('delivery.rate_hint',                    to_jsonb('Your rating helps us keep good riders on your route.'::text)),
  ('delivery.rate_submit',                  to_jsonb('Submit rating'::text)),
  ('delivery.rate_thanks',                  to_jsonb('Thanks — rating recorded.'::text)),
  ('delivery.rate_already',                 to_jsonb('You have already rated this delivery.'::text)),
  ('delivery.rate_not_delivered',           to_jsonb('You can rate once the order is delivered.'::text)),
  ('delivery.rate_comment_hint',            to_jsonb('Anything we should know? (optional)'::text)),
  ('admin.delivery.rating_col',             to_jsonb('Rating'::text)),
  ('admin.delivery.rating_none',            to_jsonb('—'::text)),

  -- (8) damage / short claim
  ('delivery.claim_title',                  to_jsonb('Report damage or shortage'::text)),
  ('delivery.claim_qty_label',              to_jsonb('Affected quantity'::text)),
  ('delivery.claim_photo_required',         to_jsonb('A photo of the damage or the short parcel is required.'::text)),
  ('delivery.claim_submit',                 to_jsonb('Raise claim'::text)),
  ('delivery.claim_raised',                 to_jsonb('Claim raised — a credit note will follow on the bill.'::text)),
  ('delivery.claim_kind_damaged',           to_jsonb('Damaged'::text)),
  ('delivery.claim_kind_short',             to_jsonb('Short supplied'::text)),
  ('delivery.claim_kind_missing',           to_jsonb('Missing'::text)),
  ('admin.delivery.claims_title',           to_jsonb('Doorstep claims'::text)),
  ('admin.delivery.claims_empty',           to_jsonb('No open claims.'::text)),
  ('admin.delivery.claim_approve_btn',      to_jsonb('Approve credit'::text)),
  ('admin.delivery.claim_reject_btn',       to_jsonb('Reject'::text)),
  ('bill.credit_note_label',                to_jsonb('Less: Credit note'::text)),

  -- (9) geofence
  ('delivery.arrived_chip',                 to_jsonb('Arrived'::text)),
  ('delivery.arriving_now_title',           to_jsonb('Your delivery is arriving'::text)),
  ('delivery.arriving_now_msg',             to_jsonb('{rider} is at your door with order {order}.'::text)),

  -- (10) cold chain
  ('delivery.cold_chain_badge',             to_jsonb('Cold chain'::text)),
  ('delivery.cold_chain_note',              to_jsonb('Keep in the cold box. Photo proof required on delivery.'::text)),
  ('delivery.cold_chain_photo_required',    to_jsonb('This parcel is temperature-sensitive — a photo is required to complete it.'::text)),
  ('pack.cold_chain_badge',                 to_jsonb('Cold chain'::text)),

  -- admin ops screen shell
  ('admin.delivery.ops_title',              to_jsonb('Delivery operations'::text)),
  ('admin.delivery.ops_entry',              to_jsonb('Delivery operations'::text)),
  ('admin.delivery.ops_subtitle',           to_jsonb('Payouts, serviceability, documents, ratings and claims'::text)),
  ('admin.delivery.sla_title',              to_jsonb('On-time performance'::text)),
  ('admin.delivery.sla_ontime',             to_jsonb('On time'::text)),
  ('admin.delivery.sla_breached',           to_jsonb('Late'::text)),
  ('admin.delivery.sla_pending',            to_jsonb('In flight'::text)),
  ('admin.delivery.ops_error',              to_jsonb('Could not load delivery operations.'::text)),
  ('admin.delivery.ops_retry',              to_jsonb('Retry'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();
