-- CMD #1820 — the Token dashboard's door.
--
-- Registered on BOTH planes on purpose, and with the column set both actually
-- have: dev_tools() renders the CONTROL PLANE's feature_registry, while the
-- protected gate test/protected/dev_tools_registry_test.dart reads this file
-- to prove that every tool the registry admits is one the build can open. A
-- tool registered in only one of those places is either unreachable or a dead
-- row, which is the #349/#468 defect.
--
-- Column order matters, not just the values: the gate matches the shape
-- (route_key, sort_order, 'medibo', … 'dev_tools') inside ONE values row.
-- icon_key is 'rupee' because production's feature_registry.icon_key has a
-- foreign key into ui_icon, and 'rupee' is one of the ten keys that table holds.
do $$
begin
  if to_regclass('public.feature_registry') is null then
    raise notice 'c1820: no feature_registry here — nothing to register';
    return;
  end if;

  insert into public.feature_registry
    (feature_key, label, group_label, category, route_key, sort_order, owner,
     surface, is_active, roles_allowed, icon_key, description)
  values (
    'devtool.token_dashboard', 'Token dashboard', 'Runtime & health', 'more_system',
    'token_dashboard', 41, 'medibo', 'dev_tools', true, array['admin','super_admin'], 'rupee',
    'Where every token and rupee went — spend, waste, the same file twice, and when the weekly quota runs out.')
  on conflict (feature_key) do update
    set label        = excluded.label,
        group_label  = excluded.group_label,
        route_key    = excluded.route_key,
        sort_order   = excluded.sort_order,
        surface      = excluded.surface,
        icon_key     = excluded.icon_key,
        description  = excluded.description,
        roles_allowed= excluded.roles_allowed,
        is_active    = true;
end $$;
