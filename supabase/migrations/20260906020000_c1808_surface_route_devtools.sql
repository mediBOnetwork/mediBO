-- CHANGE #1808 — RG red after #1161: c570_surface_map reported `unrouted_feature`
-- (danger) for devtool.test_coverage, and devtool.journey_bot / its
-- devtool.order_pipeline alias were sitting inside the 90-minute grace window
-- about to become the same red.
--
-- The doors THEMSELVES already exist. `openDevTool()` in
-- lib/screens/admin/dev_queue/dev_queue_screen.dart has carried
-- `case 'test_coverage'` (TestCoverageScreen) and `case 'journey_bot'`
-- (JourneyBotScreen) since the commands that built those screens. What was
-- never written is the DECLARATION: surface_route is the table that says which
-- dispatcher owns a route_key, and R1 of surface_map_audit() reads it, not the
-- Dart switch. A tile registered without its surface_route row is therefore a
-- door that works but that the audit cannot see — and after the grace window it
-- is scored as drift, which is exactly the red this command was filed for.
--
-- Data only: no DDL, so PostgREST does not reload its schema cache.
insert into public.surface_route (route_key, feature_key, kind, handled_by, note)
values
  ('test_coverage', 'devtool.test_coverage', 'feature', 'dev_queue_screen',
   'Dev Queue -> Tools -> Test coverage (openDevTool case test_coverage)'),
  ('journey_bot', 'devtool.journey_bot', 'feature', 'dev_queue_screen',
   'Dev Queue -> Tools -> Journey bot (openDevTool case journey_bot)'),
  ('journey_bot', 'devtool.order_pipeline', 'feature', 'dev_queue_screen',
   'alias of devtool.journey_bot — same door, kept routed so R1 sees it')
on conflict (route_key, feature_key) do update
  set kind        = excluded.kind,
      handled_by  = excluded.handled_by,
      note        = excluded.note,
      is_active   = true,
      updated_at  = now();

-- R5 · the same registration got its audience wrong. devtool.journey_bot was
-- written with roles_allowed = {admin, super_admin} while surface `dev_tools`
-- serves [super_admin] only — every other devtool.* row is super-admin alone,
-- and the Dev Queue itself is super-admin gated. surface_map_audit() reports
-- that as `wrong_surface`, tone DANGER, the moment the row is older than the
-- 90-minute grace window: it was 75 minutes old and 15 minutes from turning the
-- guard red a second time. The row is what is wrong, not the surface.
update public.feature_registry
   set roles_allowed = array['super_admin']::text[]
 where feature_key = 'devtool.journey_bot'
   and roles_allowed <> array['super_admin']::text[];
