-- CMD #1833 — the two newest dev tools declare their door and their audience.
--
-- THIRD (and last) half of the same red. c634 wanted a test contract and got
-- one; c570_surface_map wants the other two halves of a registered feature and
-- has been raising DANGER on both of them:
--
--   R1 unrouted_feature — 'route_key "token_dashboard" is not declared in
--   surface_route, so tapping the tile lands in the shell's default branch.'
--   R5 wrong_surface    — 'surface dev_tools serves [super_admin] but the row
--   admits [admin, super_admin].'
--
-- Both are true of devtool.token_dashboard (registered 08:26 by CMD #1820) AND
-- of devtool.build_intelligence (registered 09:45 by CMD #1824). Only the first
-- is red today because R1/R5 hold every row inside surface_map_grace_min before
-- counting it (CHANGE #902/#978) — build_intelligence is the SAME miss with a
-- younger clock, so fixing only the one that is currently red buys about an
-- hour and then files the identical critical again. Both are fixed here.
--
-- A behaviour failure is never rebaselined. And neither of these is a missing
-- screen: dev_queue_screen.dart already carries 'token_dashboard' and
-- 'build_intelligence' in kDevToolKeys, and openDevTool() already pushes
-- TokenDashboardScreen / BuildIntelligenceScreen. The doors exist in the shell;
-- what was missing is the backend DECLARING them, which is the only thing the
-- audit can see. So this is a data fix, and it makes the map honest rather than
-- silencing it.
--
-- Audience: dev_tools serves [super_admin] (surface_audience), the Dev Queue is
-- super-admin only, and all eighteen sibling devtool.* rows are {super_admin}.
-- The rows are narrowed to match the surface; the surface is not widened.
--
-- DML only — no DDL, so PostgREST does not reload its schema cache. Idempotent:
-- the insert upserts on (route_key, feature_key) and the update is fenced.
insert into public.surface_route (route_key, feature_key, kind, handled_by, note)
values
  ('token_dashboard', 'devtool.token_dashboard', 'feature', 'dev_queue_screen',
   'CMD #1820 tile. kDevToolKeys carries the key; openDevTool() pushes TokenDashboardScreen.'),
  ('build_intelligence', 'devtool.build_intelligence', 'feature', 'dev_queue_screen',
   'CMD #1824 tile. kDevToolKeys carries the key; openDevTool() pushes BuildIntelligenceScreen.')
on conflict (route_key, feature_key) do update
   set kind       = excluded.kind,
       handled_by = excluded.handled_by,
       note       = excluded.note,
       is_active  = true,
       updated_at = now();

update public.feature_registry
   set roles_allowed = array['super_admin']::text[]
 where feature_key in ('devtool.token_dashboard', 'devtool.build_intelligence')
   and roles_allowed is distinct from array['super_admin']::text[];
