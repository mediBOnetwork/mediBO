-- CMD #1972 — RG red after #1329: the delivery OTP door is a rider door, not a zone ledger.
--
-- CHANGE #1329 landed CMD #1849's outbound chokepoint: every sending function was
-- renamed to a `_raw` core and re-published as a guarded wrapper. That mechanical
-- rename cost `delivery_send_otp` its grandfathered row in zone_scope_baseline
-- (its body changed) and created `delivery_send_otp_raw` as a brand-new unscoped
-- function, so c1094_staff_rpcs_are_zone_scoped went red with two blocking rows —
-- while the door's data exposure did not change by one row.
--
-- It is not scopeable. `delivery_send_otp_raw` authorises by IDENTITY, not by zone:
-- the caller must be the rider the delivery is assigned to
-- (delivery_partner_registrations.user_id = auth.uid()) or an admin/super_admin,
-- and it acts on ONE delivery addressed by its primary key. A rider has no
-- admin_active_zone() and no admin_active_date(); filtering this door by either
-- would not narrow an over-broad read — there is no read to narrow — it would
-- simply stop riders sending the OTP for the delivery in their hand.
--
-- So it takes the reasoned allow row the behaviour's own message offers, in the
-- same shape as delivery_track_public (CMD #1840): a door whose caller is not
-- staff browsing a zone.
--
-- Idempotent: the allow table is keyed by fn_pattern.

insert into public.zone_scope_allow (fn_pattern, dimension, reason, added_by)
values (
  'delivery_send_otp%',
  'both',
  'The rider''s own OTP door. delivery_send_otp / delivery_send_otp_raw act on ONE delivery by primary key and authorise by identity — the assigned rider (delivery_partner_registrations.user_id = auth.uid()) or an admin. A rider has no active zone or active date, so neither dimension can narrow anything here; it would only break the send. CHANGE #1329 flagged it by renaming the body, not by widening it.',
  'CMD #1972'
)
on conflict (fn_pattern) do update
  set dimension = excluded.dimension,
      reason    = excluded.reason,
      added_by  = excluded.added_by;
