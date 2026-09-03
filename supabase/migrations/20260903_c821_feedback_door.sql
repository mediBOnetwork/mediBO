-- CHANGE #821 — "the tile has no door", retired as a class.
--
-- THE BUG OM REPORTED. The Feedback desk (#697) shipped its screen, its RPCs
-- and its feature_registry row, and the tile did nothing. The half that was
-- actually missing by the time this command ran was not the door — #697 step 7
-- put `'feedback' => const AdminFeedbackScreen()` in
-- lib/screens/shell/shell_extra_routes.dart and #810 declared the surface_route
-- row. What was missing was the GUARD: the protected test that exists to prove
-- "every registry tile has a door" could not see a shard-routed door at all,
-- and its offline mirror of the registry had drifted 31 routes behind.
--
-- Measured before this migration:
--   * test/protected/admin_nav_reachability_test.dart read `handled` from
--     `case 'x':` labels in home_shell.dart ONLY. Adding 'feedback' to the
--     mirror failed the suite with "renders a tile that does nothing on tap"
--     while the door was five lines away in the shard. So the gate punished
--     the correct wiring, which is why nobody ever added the route.
--   * 31 active registry routes were absent from kRegisteredAdminRoutes
--     (feedback, delivery_extras, delivery_waves, returns_refunds,
--     surface_map, exceptions, ops_board, pricing, demand_engine, …), so the
--     gate had nothing to check them against and stayed green through the bug.
--   * fulfill.order_timeline was live with NO surface_route row and 83 minutes
--     into surface_map_audit()'s 90-minute grace window — seven minutes from
--     turning rg_check red for every runner on the box, which is the outage
--     the bug report describes.
--
-- WHAT THIS MIGRATION DOES.
--   1. Declares the missing door (fulfill.order_timeline) and corrects the
--      feedback row's note, which named home_shell when the door is the shard.
--   2. Adds the rg payload target `c821_shell_doors`: the sorted list of doors
--      the shell must answer. Any registry or surface_route change moves that
--      hash and turns rg_check RED for the next runner, whose fix is named in
--      the diff — regenerate the offline mirror with
--      scripts/gen_registered_routes.sh, commit it, then rebaseline. Silent
--      drift is what shipped this bug; this makes drift loud.
--   3. Implements journey bug-821 (`_journey_bug821`), which arrived as a
--      TODO stub and would otherwise have reported "skipped — browser runner
--      needs 2 more run(s)" forever: no browser can prove a statement about a
--      registry row.

-- ── 1. the doors themselves ────────────────────────────────────────────────
insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values ('order_timeline', 'fulfill.order_timeline', 'feature', 'home_shell',
        'CHANGE #689 — case ''order_timeline'' in _handleAdminNav calls '
        || 'shellOpenOrderTimeline(); declared here by CHANGE #821',
        true)
on conflict (route_key, feature_key) do update
   set is_active = true, handled_by = excluded.handled_by, note = excluded.note;

update public.surface_route
   set note = 'CHANGE #697 — the screen is opened by shellExtraRouteScreen() in '
              || 'lib/screens/shell/shell_extra_routes.dart, which home_shell '
              || 'reaches through its one `case _ when shellExtraRouteScreen(route) '
              || '!= null` lookup. Declared #810, note corrected #821.'
 where route_key = 'feedback' and feature_key = 'admin.feedback';

-- ── 2. drift becomes a red rg_check, not a silent green ────────────────────
-- The set of doors the Flutter shell is responsible for, plus the routes whose
-- door is the BACKEND's fulfill pairing rather than a line of Dart. This is
-- exactly what scripts/gen_registered_routes.sh writes into
-- test/protected/registered_routes.dart, so the payload moving and the mirror
-- going stale are the same event — and rg_check reports it.
insert into public.rg_payload_targets (name, sql, enabled) values (
  'c821_shell_doors',
  $q$
  select jsonb_build_object(
    'shell_doors', coalesce((select jsonb_agg(distinct r.route_key order by r.route_key)
                               from public.surface_route r
                              where r.is_active and r.handled_by = 'home_shell'), '[]'::jsonb),
    'fulfill_redirected', coalesce((
      select jsonb_agg(distinct f.route_key order by f.route_key)
        from public.feature_registry f
       where f.is_active and coalesce(f.route_key,'') <> ''
         and exists (select 1 from public.feature_registry f2
                      where f2.is_active and f2.surface = 'fulfill_tab'
                        and coalesce(f2.canonical_key, f2.feature_key)
                            = coalesce(f.canonical_key, f.feature_key))), '[]'::jsonb))
  $q$, true)
on conflict (name) do update set sql = excluded.sql, enabled = true;

-- ── 3. the journey ─────────────────────────────────────────────────────────
create or replace function public._journey_bug821()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_doorless   jsonb;
  v_grace      int;
  v_pending    int;
  v_unknown    jsonb;
  v_feedback   record;
  v_has_reg    boolean := false;
  v_target     record;
  v_has_target boolean := false;
  v_baselined  boolean;
  v_orphan     jsonb;
  v_fail       text[] := array[]::text[];
begin
  v_grace := coalesce((select (value #>> '{}')::int from public.app_settings
                        where key = 'surface_map_grace_min'), 90);

  -- A1 · no live tile is doorless past the grace window. This is the bug's own
  --      shape: a feature_registry row with a route_key and nothing in
  --      surface_route to open it.
  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', f.feature_key, 'route_key', f.route_key,
           'age_min', (extract(epoch from (now() - f.created_at)) / 60)::int)
         order by f.feature_key), '[]'::jsonb)
    into v_doorless
    from public.feature_registry f
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active
   where f.is_active and coalesce(f.route_key,'') <> '' and r.route_key is null
     and f.created_at < now() - make_interval(mins => v_grace);
  if jsonb_array_length(v_doorless) > 0 then
    v_fail := v_fail || array['a live tile has no door past the ' || v_grace
                         || '-minute grace window: ' || v_doorless::text];
  end if;

  -- ...and the ones inside it are reported, never counted — a door that has
  -- not landed yet is a build in progress, not a defect (surface_map_audit's
  -- own rule, asserted here so the two can never disagree).
  select count(*) into v_pending
    from public.feature_registry f
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active
   where f.is_active and coalesce(f.route_key,'') <> '' and r.route_key is null;

  -- A2 · every declared door names a handler this app actually has. A row that
  --      says handled_by='some_screen_nobody_wrote' is a door on paper only,
  --      and it is what turns the guard green while the button stays dead.
  select coalesce(jsonb_agg(distinct r.handled_by), '[]'::jsonb) into v_unknown
    from public.surface_route r
   where r.is_active
     and r.handled_by not in ('home_shell','partner_home_screen','dev_queue_screen',
                              'admin_dashboard_screen','admin_fulfillment_screen',
                              'customer_menu','admin_customer_screen',
                              'admin_supplier_screen','supplier_shell');
  if jsonb_array_length(v_unknown) > 0 then
    v_fail := v_fail || array['surface_route names handlers that do not exist: ' || v_unknown::text];
  end if;

  -- A3 · no declared door points at a feature that is gone or switched off.
  select coalesce(jsonb_agg(r.route_key order by r.route_key), '[]'::jsonb) into v_orphan
    from public.surface_route r
   where r.is_active and r.kind = 'feature'
     and not exists (select 1 from public.feature_registry f
                      where f.is_active and f.feature_key = r.feature_key);
  if jsonb_array_length(v_orphan) > 0 then
    v_fail := v_fail || array['doors point at features that no longer exist: ' || v_orphan::text];
  end if;

  -- A4 · the row Om reported, specifically: the Feedback desk is registered,
  --      active, admitted to the roles that own it, and its door is declared.
  select f.is_active as reg_active, f.roles_allowed, f.route_key,
         r.route_key is not null as has_door, r.handled_by
    into v_feedback
    from public.feature_registry f
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active
   where f.feature_key = 'admin.feedback';
  v_has_reg := found;
  if not v_has_reg then
    v_fail := v_fail || array['feature_registry has no admin.feedback row at all'];
  else
    if not v_feedback.reg_active then
      v_fail := v_fail || array['admin.feedback is registered but switched off'];
    end if;
    if v_feedback.route_key <> 'feedback' then
      v_fail := v_fail || array['admin.feedback route_key is "' || v_feedback.route_key || '", not "feedback"'];
    end if;
    if not v_feedback.has_door then
      v_fail := v_fail || array['admin.feedback has no active surface_route row — the tile has no door'];
    end if;
    if not ('super_admin' = any (v_feedback.roles_allowed)) then
      v_fail := v_fail || array['admin.feedback does not admit super_admin'];
    end if;
  end if;

  -- A5 · and the alarm that keeps the offline mirror honest is ARMED. The
  --      protected suite runs on the Dart VM with no network, so its copy of
  --      the door list is a checked-in file; this payload target is what makes
  --      that file going stale a RED rg_check instead of a quiet green.
  select t.name, t.enabled into v_target
    from public.rg_payload_targets t where t.name = 'c821_shell_doors';
  v_has_target := found;
  if not v_has_target or not v_target.enabled then
    v_fail := v_fail || array['rg payload target c821_shell_doors is missing or disabled — '
                        || 'door-list drift would go unreported again'];
  else
    select exists (select 1 from public.rg_baseline b
                    where b.kind = 'payload' and b.name = 'c821_shell_doors')
      into v_baselined;
    if not v_baselined then
      v_fail := v_fail || array['c821_shell_doors has no rg_baseline row — the alarm is installed but not set'];
    end if;
  end if;

  return jsonb_build_object(
    'ok', cardinality(v_fail) = 0,
    'evidence', jsonb_build_object(
      'doorless_past_grace', v_doorless,
      'doors_still_in_grace', v_pending,
      'grace_min', v_grace,
      'unknown_handlers', v_unknown,
      'orphan_doors', v_orphan,
      'feedback_door', case when not v_has_reg then 'no registry row'
                            else coalesce(v_feedback.handled_by, 'NO DOOR') end,
      'drift_alarm_armed', coalesce(v_baselined, false),
      'doors_declared', (select count(*) from public.surface_route where is_active),
      'shell_doors', (select count(*) from public.surface_route
                       where is_active and handled_by = 'home_shell')),
    'failures', to_jsonb(v_fail));
end
$fn$;

revoke all on function public._journey_bug821() from public, anon, authenticated;

-- the journey itself: it arrived as a TODO stub with no assertions, which is
-- the shape that reports 'skipped' forever.
update public.dev_journeys
   set kind = 'api',
       area = 'admin',
       steps = jsonb_build_array(
         'A screen ships with its RPCs and a feature_registry row carrying a route_key (#697 shipped admin.feedback / "feedback" exactly this way).',
         'The route is opened by lib/screens/shell/shell_extra_routes.dart rather than by a `case` in home_shell.dart, because the shell is held under 2,000 lines by its own guard.',
         'surface_route must declare that door, and the protected reachability test must be able to SEE it.',
         'A registry row whose door is never declared is drift: surface_map_audit reports it while it is young and counts it after the grace window, which turns rg_check red for every runner on the box.',
         'The offline mirror the Dart VM checks against is regenerated from surface_route, so the two can never disagree in silence.'),
       assertions = jsonb_build_array(
         'no active feature_registry row with a route_key is missing an active surface_route row past surface_map_grace_min',
         'every active surface_route names a handler that exists in the app',
         'no active door points at a feature that is gone or switched off',
         'admin.feedback is active on route_key feedback, admits super_admin, and its door is declared',
         'rg payload target c821_shell_doors is enabled AND baselined, so the checked-in mirror going stale is a red rg_check rather than a quiet green'),
       enabled = true
 where name = 'bug-821';

-- ── 4. wire it into the probe ──────────────────────────────────────────────
-- Rewritten by re-inserting one dispatch line ahead of the bug-683 branch,
-- rather than pasting a 900-line function into this file: the probe is edited
-- by many commands and a full-body copy here would silently revert whichever
-- of them landed last.
do $wire$
declare v_src text; v_new text;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dev_journey_probe';
  if v_src is null then
    raise exception 'dev_journey_probe is missing — cannot wire journey bug-821';
  end if;
  if position('_journey_bug821()' in v_src) > 0 then
    return; -- idempotent: a resumed worker re-applies this file
  end if;
  v_new := replace(v_src,
    '  if p_name = ''bug-683'' then return public._journey_bug683(); end if;',
    '  -- CHANGE #821 — "the tile has no door", as a class: a registry row with'
 || E'\n  -- a route_key and nothing in surface_route to open it, plus the drift alarm'
 || E'\n  -- that keeps the protected suite''s offline mirror honest.'
 || E'\n  if p_name = ''bug-821'' then return public._journey_bug821(); end if;'
 || E'\n  if p_name = ''bug-683'' then return public._journey_bug683(); end if;');
  if v_new = v_src then
    raise exception 'could not find the bug-683 dispatch line in dev_journey_probe — wire bug-821 by hand';
  end if;
  execute 'create or replace function public.dev_journey_probe(p_name text) '
       || 'returns jsonb language plpgsql security definer set search_path to ''public'' as '
       || quote_literal(v_new);
end $wire$;

revoke all on function public.dev_journey_probe(text) from public, anon, authenticated;
