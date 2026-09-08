-- replay-target: production
-- CMD #1824 — register the Build intelligence tool on PRODUCTION's
-- feature_registry, mirroring the control-plane row in
-- 20260906190000_c1824_build_intelligence.sql. Two rows in two projects on
-- purpose (the #1820 lesson): dev_tools() renders the CONTROL PLANE's
-- registry, while test/protected/dev_tools_registry_test.dart greps
-- supabase/migrations/ for the `'route_key', sort, 'medibo' … 'dev_tools'`
-- shape to prove every registered tool is one this build can open.
-- icon_key 'insights' — production's feature_registry.icon_key has an FK to
-- ui_icon, so the row falls back to a key that table holds when it must.
do $$
declare v_icon text := 'insights';
begin
  if to_regclass('public.feature_registry') is null then
    raise notice 'c1824: no feature_registry here — nothing to register';
    return;
  end if;
  if to_regclass('public.ui_icon') is not null
     and not exists (select 1 from public.ui_icon where icon_key = 'insights') then
    select icon_key into v_icon from public.ui_icon
     where icon_key in ('timeline','rupee','fact_check','cloud') order by 1 limit 1;
    v_icon := coalesce(v_icon, (select icon_key from public.ui_icon order by icon_key limit 1));
  end if;

  insert into public.feature_registry
    (feature_key, label, group_label, category, route_key, sort_order, owner,
     surface, is_active, roles_allowed, icon_key, description)
  values (
    'devtool.build_intelligence', 'Build intelligence', 'Runtime & health', 'more_system',
    'build_intelligence', 42, 'medibo', 'dev_tools', true, array['admin','super_admin'], v_icon,
    'What the registry has learned: calibrated ETAs, repeat causes now enforced as constraints, waste classes with their knobs, and lessons that earn their place.')
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
