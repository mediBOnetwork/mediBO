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

String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    // Thrown, not expect()ed: this runs at load time, outside any test body.
    throw StateError('$path is missing — did it move?');
  }
  return f.readAsStringSync();
}

/// The `route_key` of every ACTIVE admin row in `feature_registry` as of
/// CHANGE #325. Registering a screen means adding its key here too — that is
/// deliberate friction, and it is cheaper than a tile that silently does
/// nothing on a phone.
const kRegisteredAdminRoutes = <String>[
  // Orders & Fulfilment
  'fulfillment', 'order_alerts', 'order_closure', 'bags', 'reorder',
  // Customers & Suppliers
  'customers', 'suppliers', 'add_customer', 'add_supplier', 'mr', 'companies',
  'unmapped_companies', 'deletion_requests',
  // Catalogue & Pricing
  'add_medicine', 'pricing_backfill', 'discount_slabs', 'loyalty',
  // Delivery
  'delivery_partners', 'delivery_ops',
  // Communication
  'whatsapp', 'wa_templates', 'wa_campaigns', 'wa_segments', 'wa_drips',
  'wa_ops', 'wa_diagnosis', 'notify_center', 'admin_push', 'notify_cost',
  // Money
  'bill_pipeline', 'gst', 'pnl', 'settlement', 'payment_upi',
  // Admin & System
  'manage_admins', 'dev_queue', 'scope_audit', 'feature_gaps', 'cron_health',
  // Identity — the only two rows the dropdown may hold
  'profile', 'logout',
];

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

  test('the shell sheet does not re-add feature rows around the registry rows',
      () {
    // The sheet used to hand-write View Profile, Bags and Logout around the
    // generated block. Bags is a feature — it belongs to a category on the
    // dashboard, not to the identity dropdown.
    final sheet = shellSrc.substring(
        shellSrc.indexOf('void _showAdminSheet'),
        shellSrc.indexOf('void _showAdminSheet') + 3000);
    expect(sheet, isNot(contains('BagsScreen')),
        reason: 'Bags is a registered feature (Orders & Fulfilment), not an '
            'identity row');
    expect(sheet, contains('AdminProfileMenuTiles'),
        reason: 'the sheet renders the registry rows and nothing else');
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
    // Every one of these existed, worked, and was reachable only by typing its
    // URL (or not at all). Rule 11: a feature Om cannot tap does not exist.
    for (final route in const [
      'reorder', 'pnl', 'discount_slabs', 'loyalty', 'unmapped_companies',
      'delivery_ops', 'notify_cost', 'settlement', 'cron_health',
    ]) {
      expect(handled, contains(route),
          reason: '$route is registered but the router cannot open it');
    }
  });

  test('CHANGE #325 — every screen is addressable by URL', () {
    // Deep links (spec 6): a push notification, a WhatsApp button or the
    // command palette must be able to jump straight to a screen.
    expect(_read('lib/main.dart'), contains('/admin/go/'),
        reason: 'the registry\'s deep_link column points at /admin/go/<route>, '
            'so main.dart must resolve that prefix');
  });
}
