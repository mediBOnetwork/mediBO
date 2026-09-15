-- CHANGE #536 QA round 2 — the Money section gets its Purchase reports tile.
--
-- The spec names three Money tiles: Khata book, GST pack and Purchase reports.
-- The first two shipped in the first pass; the third did not, and the hostile
-- QA round called it a genuine coverage gap rather than a naming one.
--
-- It was never missing UI. `PurchasesScreen` (CMD #367, feature_gaps row 174)
-- is the pharmacy's own purchase analytics — summary tiles, month bars, two
-- leaderboards and a server-generated purchase register — and it has been
-- built and live for a month. Its ONLY door was a button buried inside the
-- Orders screen, so it is the exact failure this whole command exists to end:
-- a feature built FOR the customer that the customer cannot find. Registering
-- it is a data fix (#325), and the route case that gives it an address is the
-- same one-line pattern every other My Shop route already uses.
--
-- Sort order puts it where the spec lists it — Khata book (10), GST pack (20),
-- Purchase reports (25), Price check (30).
--
-- Idempotent: re-applying it is a no-op.

insert into feature_registry (
  feature_key, label, description, group_label, icon_key, route_key, sort_order,
  owner, partner_eligible, default_access, is_active, category, surface, roles_allowed
) values
  ('shop.purchases', 'Purchase reports', 'What you bought, month by month', 'Money', 'timeline', 'purchases', 25, 'medibo', false, 'read', true, 'cshop_money', 'customer_shop', array['customer','super_admin'])
on conflict (feature_key) do update set
  label            = excluded.label,
  description      = excluded.description,
  group_label      = excluded.group_label,
  icon_key         = excluded.icon_key,
  route_key        = excluded.route_key,
  sort_order       = excluded.sort_order,
  partner_eligible = excluded.partner_eligible,
  is_active        = excluded.is_active,
  category         = excluded.category,
  surface          = excluded.surface,
  roles_allowed    = excluded.roles_allowed;
