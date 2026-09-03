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
  final shardSrc = _read('lib/screens/shell/shell_extra_routes.dart');

  /// Every `case 'x':` the router handles directly.
  final shellCases = RegExp(r"case\s+'([a-z0-9_]+)'\s*:")
      .allMatches(shellSrc)
      .map((m) => m.group(1)!)
      .toSet();

  /// CHANGE #821 — the doors the shell does NOT hold a `case` for.
  ///
  /// This is the half that shipped the bug. `home_shell.dart` is capped at
  /// 2,000 lines by its own guard, so since #570 a screen is registered as an
  /// arm of `shellExtraRouteScreen` in shell/shell_extra_routes.dart and the
  /// shell keeps ONE `case _ when shellExtraRouteScreen(route) != null`
  /// lookup. This test only ever read `case` labels, so a shard-routed door
  /// read as no door at all: adding 'feedback' to the mirror failed the suite
  /// with "renders a tile that does nothing on tap" while
  /// `'feedback' => const AdminFeedbackScreen()` sat five lines away. A gate
  /// that punishes the correct wiring is a gate nobody can use, which is why
  /// the mirror was 31 routes behind the registry by #821 and the Feedback
  /// desk shipped through it.
  final shardArms = RegExp(r"'([a-z0-9_]+)'\s*=>")
      .allMatches(shardSrc)
      .map((m) => m.group(1)!)
      .toSet();

  /// ...and the routes whose door is DATA, not Dart: `shellOpenFulfillStage`
  /// sends them to AdminFulfillmentScreen on the stage the backend pairs them
  /// with, so there is deliberately no `case` and no arm to find. The list is
  /// generated from that same pairing (scripts/gen_registered_routes.sh).
  final handled = <String>{
    ...shellCases,
    ...shardArms,
    ...kFulfillRedirectedRoutes,
  };

  test('the router still has a switch (the regex still matches)', () {
    expect(shellCases, isNotEmpty,
        reason: 'no case labels found — _handleAdminNav changed shape');
  });

  test('every registered feature has a door', () {
    final orphans =
        kRegisteredAdminRoutes.toSet().difference(handled).toList()..sort();
    expect(orphans, isEmpty,
        reason: 'these registry routes render a tile that does nothing on '
            'tap: $orphans');
  });

  // ── CHANGE #821 ─────────────────────────────────────────────────────────
  // The three properties the Feedback desk needed and did not have. Om's
  // report named the symptom ("the tile has no door"); these hold the CLASS.

  test('CHANGE #821 — a shard-routed door counts as a door', () {
    // The regression this file shipped: 'feedback' is opened by
    // shellExtraRouteScreen, not by a case, and the gate called it a dead tap.
    expect(shardArms, contains('feedback'),
        reason: 'the Feedback desk (#697) is opened by shell_extra_routes.dart');
    expect(handled, contains('feedback'),
        reason: 'a door in the shard is still a door — this is the exact '
            'blindness that let #697 ship an unreachable tile');
    expect(kRegisteredAdminRoutes, contains('feedback'),
        reason: 'and the mirror must name it, or nothing is being checked');
    // The shell reaches the shard through one lookup. If that goes, every arm
    // in the shard becomes a dead tap at once.
    expect(shellSrc, contains('shellExtraRouteScreen(route) != null'),
        reason: 'the shell must keep its one lookup into the route shard');
  });

  test('CHANGE #821 — every shard arm and shell case is in the mirror', () {
    // The other direction of drift: a door written in Dart that the mirror
    // never hears about is a route no test can ever check. Only routes the
    // registry actually ships are required — the shell also switches on keys
    // that are not features (tabs, sub-screens), and those are not doors.
    final declared = kRegisteredAdminRoutes.toSet();
    final undeclaredArms = shardArms.difference(declared).toList()..sort();
    expect(undeclaredArms, isEmpty,
        reason: 'these shard routes open a screen that surface_route never '
            'declared — regenerate with scripts/gen_registered_routes.sh '
            'after adding the surface_route row: $undeclaredArms');
  });

  test('CHANGE #821 — the mirror is generated, not remembered', () {
    // It drifted 31 routes behind the registry while it was hand-maintained,
    // and that drift is what made the gate above vacuous. The header is the
    // instruction the next command needs; the rg payload target
    // c821_shell_doors is what makes the drift loud.
    final src = _read('test/protected/registered_routes.dart');
    expect(src, contains('scripts/gen_registered_routes.sh'),
        reason: 'the mirror must name the script that regenerates it');
    expect(src, contains('kFulfillRedirectedRoutes'),
        reason: 'the backend-paired doors must be listed, or every fulfill '
            'route reads as an orphan');
    // A mirror this small means somebody hand-trimmed it back.
    expect(kRegisteredAdminRoutes.length, greaterThan(60),
        reason: 'the registry ships ~80 shell doors — a short list is a stale '
            'list, and a stale list checks nothing');
    expect(kRegisteredAdminRoutes.toSet(), hasLength(kRegisteredAdminRoutes.length),
        reason: 'a duplicated route key means the file was hand-edited');
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
    expect(navSrc, isNot(contains('class AdminMoreNavMenu')),
        reason: 'the More popup was the second copy of that same list');

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

  test('CHANGE #325 — the nine screens that had no entry point now do', () {
    // Every one existed, worked, and was reachable only by typing its URL (or
    // not at all). Rule 11: a feature Om cannot tap does not exist.
    for (final route in const [
      'reorder', 'pnl', 'discount_slabs', 'loyalty', 'unmapped_companies',
      'delivery_ops', 'notify_cost', 'settlement', 'cron_health',
    ]) {
      expect(handled, contains(route),
          reason: '\$route is registered but the router cannot open it');
    }
  });

  test('CHANGE #325 — the identity row the dropdown fires is openable', () {
    // profile_menu ships route_key 'profile'. A row the sheet dispatches that
    // the router cannot open is a dead tap on the one surface every role sees.
    expect(handled, contains('profile'));
  });

  test('CHANGE #325 — every screen is addressable by URL', () {
    // Deep links (spec 6): a push notification, a WhatsApp button or the
    // palette must jump straight to a screen. feature_registry.deep_link
    // points every row at /admin/go/<route_key>.
    expect(_read('lib/main.dart'), contains('/admin/go/'),
        reason: 'main.dart must resolve the deep_link prefix the registry uses');
  });

  test('CHANGE #325 — the desktop popup no longer hand-writes feature rows', () {
    // The ~14 PopupMenuItems that made the dropdown thirty deep are gone; the
    // popup draws NavProfileMenu's registry rows plus Logout.
    for (final gone in const [
      "value: 'add_supplier'", "value: 'add_customer'", "value: 'add_medicine'",
      "value: 'bags'", "value: 'mr'", "value: 'companies'",
      "value: 'delivery_partners'", "value: 'wa_templates'",
      "value: 'wa_campaigns'", "value: 'manage_admins'", "value: 'payment_upi'",
    ]) {
      expect(shellSrc, isNot(contains(gone)),
          reason: '\$gone is a feature row — it belongs to a dashboard '
              'category, not the identity dropdown');
    }
  });
}
