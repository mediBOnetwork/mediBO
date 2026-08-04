// WhatsApp Templates / Campaigns must be reachable from the running app.
//
// #645 and #646 shipped both screens, but the nav entries went into
// lib/screens/admin/admin_shell.dart — a file whose AdminShell widget is never
// instantiated anywhere. The entries are in the source and never render. The
// live shell is home_shell.dart, which has two nav surfaces:
//
//   wide   (>= 900 px, and what medibo.in serves mobile Chrome):
//          top row + "Hello <user>" profile dropdown
//   narrow (< 900 px, installed PWA): 5-tab bottom bar + profile sheet
//
// What this holds down:
//
//   1. Both labels are reachable at a PHONE width AND a desktop width — from
//      the profile menu (every viewport) and from the wide row's More popup.
//   2. Tapping each hands the RIGHT route key to nav(). The key is what
//      connects a row to _handleAdminNav's switch; a typo renders a row that
//      looks fine and silently does nothing. That switch had no case for
//      either key at all, which is why menu entries alone would not have been
//      enough.
//   3. The bottom bar still has EXACTLY five tabs. A sixth wraps every label
//      at 360 px, so new destinations go in the profile sheet instead.
//   4. No existing nav item was lost from either surface.
//   5. Neither entry is gated on isSuperAdmin — the backend RPCs gate on
//      get_my_role() and the screens render not_authorized themselves.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Deliberately NOT home_shell.dart: it transitively imports web-only libraries
// and cannot load on the Dart VM. The nav surfaces were extracted here so this
// test can exist at all.
import 'package:pharma_b2b/screens/admin/admin_nav_entries.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The wide shell starts at 900 px; mobile Chrome on medibo.in lands in it.
const _phone = Size(390, 844);
const _desktop = Size(1440, 900);

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Pumps the profile menu as a PUSHED route, mirroring the real sheet: every
/// row calls Navigator.pop() before nav(), so a route must sit beneath it.
Future<List<String>> _pumpProfileMenu(
  WidgetTester tester, {
  required Size size,
  bool isSuperAdmin = false,
  String? tapLabel,
}) async {
  _setViewport(tester, size);
  final fired = <String>[];

  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  body: SingleChildScrollView(
                    child: AdminProfileMenuTiles(
                      isSuperAdmin: isSuperAdmin,
                      nav: fired.add,
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  if (tapLabel != null) {
    await tester.tap(find.text(tapLabel));
    await tester.pumpAndSettle();
  }
  return fired;
}

/// Opens the wide top row's "More" popup.
Future<List<String>> _pumpMoreMenu(
  WidgetTester tester, {
  required Size size,
  String? tapLabel,
}) async {
  _setViewport(tester, size);
  final fired = <String>[];

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topRight,
        child: AdminMoreNavMenu(onNav: fired.add),
      ),
    ),
  ));

  await tester.tap(find.text('More'));
  await tester.pumpAndSettle();

  if (tapLabel != null) {
    await tester.tap(find.text(tapLabel));
    await tester.pumpAndSettle();
  }
  return fired;
}

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test
    // and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  // ── the surface that must work on every viewport ─────────────────────────

  for (final vp in [('phone', _phone), ('desktop', _desktop)]) {
    testWidgets('profile menu shows both WhatsApp entries at ${vp.$1} width',
        (tester) async {
      await _pumpProfileMenu(tester, size: vp.$2);

      expect(find.text('WhatsApp Templates'), findsOneWidget);
      expect(find.text('WhatsApp Campaigns'), findsOneWidget);
    });

    testWidgets('More popup shows both WhatsApp entries at ${vp.$1} width',
        (tester) async {
      await _pumpMoreMenu(tester, size: vp.$2);

      expect(find.text('WhatsApp Templates'), findsOneWidget);
      expect(find.text('WhatsApp Campaigns'), findsOneWidget);
    });
  }

  // ── the keys _handleAdminNav switches on ─────────────────────────────────

  testWidgets('profile menu: Templates fires wa_templates', (tester) async {
    final fired = await _pumpProfileMenu(
        tester, size: _phone, tapLabel: 'WhatsApp Templates');
    expect(fired, ['wa_templates']);
  });

  testWidgets('profile menu: Campaigns fires wa_campaigns', (tester) async {
    final fired = await _pumpProfileMenu(
        tester, size: _phone, tapLabel: 'WhatsApp Campaigns');
    expect(fired, ['wa_campaigns']);
  });

  testWidgets('More popup: Templates fires wa_templates', (tester) async {
    final fired = await _pumpMoreMenu(
        tester, size: _desktop, tapLabel: 'WhatsApp Templates');
    expect(fired, ['wa_templates']);
  });

  testWidgets('More popup: Campaigns fires wa_campaigns', (tester) async {
    final fired = await _pumpMoreMenu(
        tester, size: _desktop, tapLabel: 'WhatsApp Campaigns');
    expect(fired, ['wa_campaigns']);
  });

  // ── nothing lost, nothing added where it must not be ─────────────────────

  test('the bottom bar still has EXACTLY five tabs', () {
    expect(kAdminBottomNav.length, 5);
    expect(
      kAdminBottomNav.map((e) => e.label).toList(),
      ['Dashboard', 'WhatsApp', 'Customers', 'Suppliers', 'Fulfill'],
    );
    // The WhatsApp screens must NOT have been pushed into the bottom bar.
    expect(kAdminBottomNav.any((e) => e.label.contains('Templates')), isFalse);
    expect(kAdminBottomNav.any((e) => e.label.contains('Campaigns')), isFalse);
  });

  test('the wide top row keeps its five sections, in order', () {
    expect(
      kAdminTopNav.map((e) => e.label).toList(),
      ['Dashboard', 'WhatsApp', 'Customers', 'Suppliers', 'Fulfillment'],
    );
  });

  test('the overflow menu carries exactly the two new destinations', () {
    expect(
      kAdminOverflowNav.map((e) => e.route).toList(),
      ['wa_templates', 'wa_campaigns'],
    );
  });

  testWidgets('no existing profile-menu item was lost', (tester) async {
    await _pumpProfileMenu(tester, size: _desktop, isSuperAdmin: true);

    for (final label in const [
      'Manage Admins',
      'Payment and Partner',
      'Add Supplier',
      'Add Customer',
      'Add Medicine',
      'MR Registrations',
      'Company Registrations',
      'Delivery Partners',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '$label went missing');
    }
  });

  // ── not gated on isSuperAdmin ────────────────────────────────────────────

  testWidgets('a plain admin sees both WhatsApp entries', (tester) async {
    await _pumpProfileMenu(tester, size: _phone, isSuperAdmin: false);

    expect(find.text('WhatsApp Templates'), findsOneWidget);
    expect(find.text('WhatsApp Campaigns'), findsOneWidget);
    // ...while the genuinely super-only rows stay hidden, proving the WhatsApp
    // rows sit outside the guard rather than the whole menu being ungated.
    expect(find.text('Manage Admins'), findsNothing);
    expect(find.text('Payment and Partner'), findsNothing);
  });
}
