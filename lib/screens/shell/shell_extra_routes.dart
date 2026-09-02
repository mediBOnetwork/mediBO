// lib/screens/shell/shell_extra_routes.dart — CHANGE #570
//
// A route table, not a screen. Four registry rows had promised doors that no
// dispatcher anywhere in the app actually opened:
//
//   admin.delivery_extras   the delivery programme (incentives, agency GST,
//                           training, the vehicle ledger) — CMD #407
//   admin.delivery_waves    auto-assignment waves — CHANGE #405
//   admin.returns_refunds   the returns and refunds console
//   admin.surface_map       the audit that found the other three
//
// The first three had been live tiles on the super-admin dashboard for weeks:
// the screens compiled, their RPCs answered, and tapping the tile fell through
// the shell's switch into the default branch and showed "route unavailable".
// That is the "built for X, missing from X" half of Om's report, and it is why
// surface_route now DECLARES every door and rg_check fails on a tile without
// one.
//
// WHY A SEPARATE FILE. home_shell.dart is held to one concern and under 2,000
// lines by its own protected guard (test/protected/god_file_guard_test.dart —
// four cases inline pushed it to 2,010 and turned that guard red). Registering
// a screen is now a row in this table plus a feature_registry INSERT, and the
// shell keeps one four-line lookup. It is also why two commands that each add
// a screen no longer collide on the shell.

import 'package:flutter/material.dart';

import '../admin/admin_delivery_extras_screen.dart';
import '../admin/admin_delivery_waves_screen.dart';
import '../admin/returns_refunds_screen.dart';
import '../admin/surface_map_screen.dart';

/// The screen a route_key opens, or null when this table does not own it —
/// null means "keep looking", never "broken", so the shell's own switch and
/// its backend-worded default branch stay in charge of an unknown route.
Widget? shellExtraRouteScreen(String routeKey) => switch (routeKey) {
      'delivery_extras' => const AdminDeliveryExtrasScreen(),
      'delivery_waves' => const AdminDeliveryWavesScreen(),
      'returns_refunds' => const ReturnsRefundsScreen(),
      'surface_map' => const SurfaceMapScreen(),
      _ => null,
    };
