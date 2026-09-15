-- CHANGE #713 (post-deploy fix 2/2) — the door was declared and then denied.
--
-- Found on the LIVE build, the same way the Scaffold bug was: the deep link
-- resolved (c325_deep_link_opened=order_threads), both RPCs answered, and the
-- screen still never opened — because CHANGE #653 refuses any route the access
-- matrix says View=off, and a NEW feature_registry row is seeded into
-- access_role_default with can_view=false for admin and partner. Only
-- super_admin is granted implicitly, so the office could open it and every
-- admin and partner could not.
--
-- That is precisely the "no orphans either way" failure: a tile with a
-- declared door, a working backend, and no grant. #707's partner.fulfil_tasks
-- carries admin=t/t and partner=t/t for the same reason; this is the row that
-- was missing.
--
-- Idempotent: (role, feature_key) is the primary key.
insert into public.access_role_default (role, feature_key, can_view, can_write)
values
  ('admin',       'partner.order_threads', true, true),
  ('partner',     'partner.order_threads', true, true),
  ('super_admin', 'partner.order_threads', true, true)
on conflict (role, feature_key) do update
  set can_view = excluded.can_view,
      can_write = excluded.can_write,
      updated_at = now();
