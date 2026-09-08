-- CMD #992 — the two partner-scorecard TILES go live.
--
-- The last step of #693, and deliberately the last step of this change too:
-- applied by hand only after verify_live.sh was green on the build carrying
--   'partner_scorecards' => const AdminPartnerScorecardsScreen()
--   'partner_scorecard'  => const PartnerScorecardScreen()
-- in shellExtraRouteScreen(). A tile that draws before its door ships is how
-- a feature lands on "route unavailable" — the failure shell_extra_routes.dart
-- was created for and documents five times over.
--
-- #693 left both rows is_active=false behind an app_settings switch so the
-- activation would be one flip rather than a remembered UPDATE. Setting the
-- switch is therefore the whole change; the two UPDATEs below re-assert it for
-- a database that already ran 20260903_c693_partner_scorecard.sql, whose guard
-- reads the switch that did not exist yet.
--
-- roles_allowed is left exactly as #693 wrote it ({admin,super_admin} on both).
-- Widening it is an access change and not this command's to make; partner
-- .documents is already live with the same pair, and partner_scorecard()
-- resolves the partner from the CALLER — its partnerId argument is an operator
-- filter and never a way in.
insert into public.app_settings(key, value)
values ('c693_scorecard_tiles_live', 'true'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

update public.feature_registry
   set is_active = true
 where feature_key in ('admin.partner_scorecards', 'partner.scorecard');

update public.surface_route
   set is_active = true
 where route_key in ('partner_scorecards', 'partner_scorecard')
   and handled_by = 'home_shell';
