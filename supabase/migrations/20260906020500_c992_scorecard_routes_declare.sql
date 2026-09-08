-- CMD #992 — declare the two partner-scorecard doors, in the same change that
-- ships them.
--
-- #693 wrote both surface_route rows and then set is_active=false, because a
-- DECLARED route whose Dart door has not shipped turns the next regeneration of
-- test/protected/registered_routes.dart — anybody's — into a red build. That was
-- correct while shellExtraRouteScreen() did not know the keys.
--
-- It knows them now: the same commit that carries this file adds
--   'partner_scorecards' => const AdminPartnerScorecardsScreen()
--   'partner_scorecard'  => const PartnerScorecardScreen()
-- so the declaration and the door land together and the mirror regenerated from
-- this table is true the moment it is written.
--
-- The TILES are deliberately NOT activated here. surface_route is a declaration
-- and audit table — only surface_map_audit() and the #821 mirror read it, no
-- nav surface does — so activating it draws nothing. feature_registry.is_active
-- is what puts the tile on a dashboard, and that flips in
-- 20260906021500_c992_scorecard_tiles_live.sql only after verify_live.sh is
-- green on the build carrying the doors. A tile can therefore never appear
-- before the door it opens.
update public.surface_route
   set is_active = true
 where route_key in ('partner_scorecards', 'partner_scorecard')
   and handled_by = 'home_shell';
