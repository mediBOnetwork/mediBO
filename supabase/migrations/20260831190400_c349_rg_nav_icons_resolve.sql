-- CHANGE #349 — the guard that makes "a tile with no icon" a build blocker.
--
-- Om's second defect was invisible to every existing gate: a registry row could
-- name any string as its icon_key and the app quietly drew a neutral square.
-- This behaviour runs inside rg_check(), so an unresolvable icon_key turns the
-- guard red — and a red guard blocks every dev_cmd_complete.
insert into public.rg_behavior_tests (name, body, enabled, note) values (
'nav_icons_resolve',
$body$
do $rg$
declare v jsonb; v_bad int; v_first text;
begin
  select public.nav_icon_audit() into v;
  v_bad := coalesce((v->>'unresolved')::int, -1);
  if v_bad < 0 then
    raise exception 'RG_FAIL: nav_icon_audit() returned no unresolved count';
  end if;
  if v_bad > 0 then
    v_first := coalesce(v->'items'->0->>'key','?') || ' -> icon_key ' ||
               coalesce(nullif(v->'items'->0->>'icon_key',''),'(none)');
    raise exception 'RG_FAIL: % registry rows name an icon the app cannot draw (first: %). A tile with an unresolvable icon_key renders as a blank pale square (CHANGE #349). Add the key to ui_icon AND to kNavIcons in lib/screens/admin/nav_registry_view.dart.', v_bad, v_first;
  end if;

  if not exists (select 1 from public.ui_icon) then
    raise exception 'RG_FAIL: ui_icon catalogue is empty — every icon_key would be unresolvable';
  end if;

  if not exists (select 1 from public.feature_registry
                  where surface = 'dev_tools' and is_active) then
    raise exception 'RG_FAIL: no Dev Queue tool is registered — the labelled tools sheet would be empty and the tools unreachable (CHANGE #349)';
  end if;
  raise exception 'RG_ROLLBACK';
end
$rg$;
$body$,
true,
'CHANGE #349 - every active feature_registry / nav_category row must name an icon_key that exists in ui_icon, and the Dev Queue tools must stay registered. Red here turns rg_check red, which blocks every dev_cmd_complete.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;
