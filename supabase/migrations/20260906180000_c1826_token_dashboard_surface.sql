-- CMD #1826 — carried fix for the regression guard's c570_surface_map red.
--
-- CMD #1833's earlier migration gave devtool.token_dashboard its test contract
-- (c634 green) but the surface audit still reported two DANGER findings on
-- the same feature, which turned every runner's rgcheck red and would have
-- blocked this command's finish gate:
--   unrouted_feature — route_key "token_dashboard" had no surface_route row,
--                      so tapping the tile landed in the shell's default branch;
--   wrong_surface    — surface dev_tools serves [super_admin] but the registry
--                      row admitted [admin, super_admin].
-- home_shell.dart already opens 'token_dashboard' through openDevTool()
-- (kDevToolKeys), the same door every other dev tool uses, so the route row
-- below describes a door that really exists. Idempotent: replayed on live by
-- the merge worker, safe on a build branch that already carries it.
do $c1826$
declare v_n int := 0;
begin
  if to_regclass('public.surface_route') is null
     or to_regclass('public.feature_registry') is null then
    raise notice 'c1826: no surface map here — nothing to route';
    return;
  end if;

  insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
  values ('token_dashboard', 'devtool.token_dashboard', 'feature', 'dev_queue_screen',
          'CMD #1826 — openDevTool() -> TokenDashboardScreen; /admin/go/token_dashboard', true)
  on conflict (route_key) do update
    set feature_key = excluded.feature_key,
        kind        = excluded.kind,
        handled_by  = excluded.handled_by,
        is_active   = true,
        updated_at  = now()
    where surface_route.feature_key is distinct from excluded.feature_key
       or not surface_route.is_active;

  update public.feature_registry f
     set roles_allowed = array['super_admin']::text[]
   where f.feature_key = 'devtool.token_dashboard'
     and f.surface = 'dev_tools'
     and f.roles_allowed is distinct from array['super_admin']::text[];
  get diagnostics v_n = row_count;
  raise notice 'c1826: token dashboard registry rows narrowed to super_admin: %', v_n;
end
$c1826$;
