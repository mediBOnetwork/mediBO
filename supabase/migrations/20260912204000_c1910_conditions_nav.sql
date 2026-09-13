-- CMD #1910 — the door to the editor.
--
-- A screen nobody can reach does not exist (§11). The route key, the feature
-- row, the deep link and the test contract are DATA — the app's nav surfaces
-- and the autotest both read them, so this is the whole of "reachable".

insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values ('admin_conditions', 'admin.conditions', 'feature', 'home_shell',
        'CMD #1910 — opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart.',
        true)
on conflict (route_key, feature_key) do update
  set kind = excluded.kind,
      handled_by = excluded.handled_by, note = excluded.note, is_active = true;

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, roles_allowed,
   deep_link, description, canonical_key, tab_screen, test_entry, test_roles,
   test_steps, test_expect, test_automatable)
values
  ('admin.conditions', 'Uses & conditions', 'Catalogue & pricing', 'medication',
   'admin_conditions', 25, 'medibo', false, 'none', true, 'more_catalogue',
   'dashboard', '{admin,super_admin}', '/admin/go/admin_conditions',
   'CMD #1910 — the vocabulary behind the fourth browse door: a use''s name, the words shoppers search for it, and the products under it.',
   'admin.conditions', null, '/admin/go/admin_conditions', '{admin,super_admin}',
   '[{"kind": "auth", "role": "{role}"}, {"kind": "goto", "path": "/admin/go/admin_conditions"}, {"ms": 6000, "kind": "settle"}]'::jsonb,
   '{"key": "boot_status", "kind": "visible", "equals": "painted", "source": "render_log"}'::jsonb,
   true)
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      icon_key = excluded.icon_key, route_key = excluded.route_key,
      category = excluded.category, surface = excluded.surface,
      roles_allowed = excluded.roles_allowed, deep_link = excluded.deep_link,
      description = excluded.description, is_active = true;

insert into public.ui_copy (key, value) values
  ('condition.retry', to_jsonb('Retry'::text))
on conflict (key) do nothing;
