-- ============================================================================
-- CHANGE #323 (part 4) — reachability.
--
-- A feature Om cannot tap does not exist (§11). This file is the door:
--   • the partner's own statement becomes a real tile on the partner home,
--     registered in feature_registry like every other partner surface, and
--     granted READ to every active partner — the statement is the partner's
--     OWN money, so it is not something an admin has to remember to unlock.
--     READ, never write: a partner reads their statement, they never edit it.
-- Idempotent by construction (#233).
-- ============================================================================

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order,
   owner, partner_eligible, default_access, is_active)
values
  ('partner.settlement', 'My settlement', 'Money', 'rupee', 'settlement', 90,
   'partner', true, 'read', true)
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      icon_key = excluded.icon_key, route_key = excluded.route_key,
      sort_order = excluded.sort_order, partner_eligible = excluded.partner_eligible,
      default_access = excluded.default_access, is_active = true;

-- Every active partner can read their own statement from day one.
insert into public.partner_permissions (partner_id, feature_key, access, updated_at, updated_by)
select rp.id, 'partner.settlement', 'read', now(), 'change-323'
  from public.region_partners rp
 where coalesce(rp.is_active, true)
on conflict (partner_id, feature_key) do nothing;

-- The word on the admin's door into settlement, from the partner console.
insert into public.ui_copy (key, value) values
  ('settlement.entry', to_jsonb('Partner settlement'::text))
on conflict (key) do nothing;
