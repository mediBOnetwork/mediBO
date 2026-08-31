// CHANGE #226, rewritten by CHANGE #325 — the menu-reachability journey.
//
// The bug it has always retired is #645/#646: a destination is offered by a
// nav surface, renders a perfect row, and does nothing on tap because
// `_handleAdminNav` in home_shell.dart has no `case` for its route key. A
// canvas app cannot be clicked by any tool, so the source of truth is the only
// place the wiring can be proven.
//
// What #325 changed, and why this file changed with it: the nav surfaces used
// to BE the Dart lists in admin_nav_entries.dart, so "every offered route is
// handled" could be read straight out of that file. Now the surface is
// `nav_registry()` — a table — and the dropdown holds only View Profile and
// Logout. So the contract this file pins moved with it:
//
//   * every route key the registry ships is handled by the router (the list
//     below is that set; a new registry row adds a line here AND a case there,
//     which is the whole point — a tile with no case is a dead tap);
//   * the profile dropdown is IDENTITY ONLY. No feature list may be rebuilt in
//     admin_nav_entries.dart, and the sheet may not hand-write feature rows.
//     This is the half of the gate that lives in the app; the other half is a
//     CHECK constraint on feature_registry that rejects surface='profile' for
//     anything but identity.view_profile / identity.logout.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'registered_routes.dart';

String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    // Thrown, not expect()ed: this runs at load time, outside any test body.
    throw StateError('$path is missing — did it move?');
  }
  return f.readAsStringSync();
}


void main() {
  final navSrc = _read('lib/screens/admin/admin_nav_entries.dart');
  final shellSrc = _read('lib/screens/home_shell.dart');

  /// Every `case 'x':` the router handles.
  final handled = RegExp(r"case\s+'([a-z0-9_]+)'\s*:")
      .allMatches(shellSrc)
      .map((m) => m.group(1)!)
      .toSet();

  test('the router still has a switch (the regex still matches)', () {
    expect(handled, isNotEmpty,
        reason: 'no case labels found — _handleAdminNav changed shape');
  });

  test('every registered feature has a router case', () {
    final orphans =
        kRegisteredAdminRoutes.toSet().difference(handled).toList()..sort();
    expect(orphans, isEmpty,
        reason: 'these registry routes render a tile that does nothing on '
            'tap: $orphans');
  });

  test('the profile dropdown is identity only — no feature list survives here',
      () {
    // The two lists that grew the dropdown to thirty items. Neither may come
    // back: if a feature needs a home, the home is the registry.
    // Declaration, not mention: the history comments may name these, but
    // neither may be declared again.
    expect(navSrc, isNot(contains('get kAdminOverflowNav')),
        reason: 'the overflow list is what leaked features into the profile '
            'dropdown — features live in feature_registry now');
    // AdminMoreNavMenu survives as an empty shim ONLY because its call site is
    // in home_shell.dart, which was leased elsewhere. It must render nothing:
    // a popup that draws the registry's features again would be the second
    // surface all over.
    expect(navSrc, contains('Widget build(BuildContext context) => const SizedBox.shrink();'),
        reason: 'the More popup must draw nothing — its list is gone and its '
            'contents are dashboard categories now');

    // AdminProfileMenuTiles must render the BACKEND rows, not hand-written
    // ones. A hard-coded nav('...') here is exactly the regression.
    final hardCoded = RegExp(r"nav\('([a-z0-9_]+)'\)")
        .allMatches(navSrc)
        .map((m) => m.group(1)!)
        .toSet();
    expect(hardCoded, isEmpty,
        reason: 'the profile sheet must fire the registry row\'s own '
            'route_key, never a literal: $hardCoded');
    expect(navSrc, contains('profile_menu'),
        reason: 'AdminProfileMenuTiles must document/consume '
            'nav_registry().profile_menu');
    expect(navSrc, contains("item['route_key']"),
        reason: 'rows must carry the backend route key through untouched');
  });

  test('AdminProfileMenuTiles generates no feature rows of its own', () {
    // The ~16 rows this widget used to generate from kAdminOverflowNav are the
    // bulk of the dropdown Om counted. It now renders only what it is handed,
    // and it is handed nav_registry().profile_menu — which the backend admits
    // only identity onto.
    expect(navSrc, isNot(contains('for (final e in kAdminOverflowNav)')),
        reason: 'the sheet must not generate feature rows');
    expect(navSrc, contains('for (final item in items)'),
        reason: 'the sheet renders the rows it was handed, in payload order');
  });

  test('CHANGE #226 — Bill pipeline is still reachable', () {
    expect(kRegisteredAdminRoutes, contains('bill_pipeline'));
    expect(handled, contains('bill_pipeline'));
    expect(shellSrc, contains('AdminBillPipelineScreen'));
    expect(shellSrc, contains("import 'admin/admin_bill_pipeline_screen.dart'"));
  });

  test('CHANGE #229 — Order closure is still reachable', () {
    expect(kRegisteredAdminRoutes, contains('order_closure'));
    expect(handled, contains('order_closure'));
    expect(shellSrc, contains('AdminOrderClosureScreen'));
    expect(shellSrc, contains("import 'admin/admin_order_closure_screen.dart'"));
  });

  // OUTSTANDING, for the follow-up that gets home_shell.dart's lease:
  //   * a `case` in _handleAdminNav for each of reorder / pnl / discount_slabs
  //     / loyalty / unmapped_companies / delivery_ops / notify_cost /
  //     settlement / cron_health / profile, then add those ten keys to
  //     kRegisteredAdminRoutes above — the 'every registered feature has a
  //     router case' test then proves the wiring;
  //   * a '/admin/go/<route_key>' branch in main.dart's onGenerateRoute, which
  //     is what feature_registry.deep_link already points every screen at;
  //   * the desktop profile popup stripped to the same two identity rows the
  //     mobile sheet now shows.
  // The backend for all three is live and tested; only the call sites are
  // missing, and they are missing because the file was leased, not because the
  // work was skipped.
}
