-- CHANGE #710 — the returns tile gets a DOOR.
--
-- The bug this closes is the one shell_extra_routes.dart was created for and
-- warns about in its own comments: #710 wired route_key 'supplier_returns'
-- into partnerDestination() in partner_home_screen.dart, and #653 retired the
-- last caller of that resolver when it merged the partner surface into the
-- shared shell. So feature_registry shipped the tile, access_role_default
-- granted it to admin / super_admin / partner, PartnerReturnsScreen compiled,
-- every RPC answered — and the tap fell through _handleAdminNav into "route
-- unavailable". Proven live on change #1074: /admin/go/supplier_returns
-- silently rendered the storefront home instead of the returns console.
--
-- The reachability gate (test/protected/admin_nav_reachability_test.dart) did
-- not catch it because its route mirror is GENERATED from this table
-- (scripts/gen_registered_routes.sh). A route with no surface_route row is a
-- route the gate never looks at, so declaring the door here is what arms the
-- test — the Dart arm alone would ship the same blind spot to the next change.
insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values
  ('supplier_returns', 'partner.supplier_returns', 'feature', 'home_shell',
   'CHANGE #710 — send wrong, damaged, short or near-expiry stock back to a '
   'supplier and raise the debit note that reduces their bill. Opened by '
   'shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart, '
   'which home_shell reaches through its one '
   '`case _ when shellExtraRouteScreen(route) != null` lookup. Authorisation '
   'is not the door: partner_return_console() zone-clamps a partner and '
   'refuses anyone who is neither office nor partner with its own sentence.',
   true)
on conflict (route_key, feature_key) do update
  set kind        = excluded.kind,
      handled_by  = excluded.handled_by,
      note        = excluded.note,
      is_active   = true,
      updated_at  = now();
