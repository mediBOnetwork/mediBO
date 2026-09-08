-- CHANGE #697 — the Feedback desk was registered but not GRANTED.
--
-- feature_registry puts a door on the map; access_role_default is what decides
-- who may walk through it. #697 shipped the first without the second, so
-- access_boot() returned v:false for every non-super login and the live proof
-- came back `c653_nav_denied=feedback` — deployed, and unreachable for exactly
-- the two roles the spec named. That is rule 11's failure, not a permissions
-- nicety.
--
-- The desk is REPORTING: an NPS trend, dimension averages, and the recent
-- orders that need a callback. Nothing on it writes, and order_feedback_screen()
-- pins a partner to their own zone by itself (my_partner_id() -> zone_locked,
-- no picker), so read for admin and partner is the whole grant. Write stays
-- super-admin only, matching every other admin.* screen.

insert into public.access_role_default (role, feature_key, can_view, can_write) values
  ('super_admin', 'admin.feedback', true,  true),
  ('admin',       'admin.feedback', true,  false),
  ('partner',     'admin.feedback', true,  false)
on conflict (role, feature_key) do update
  set can_view = excluded.can_view, can_write = excluded.can_write;
