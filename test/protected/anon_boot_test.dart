// CMD #633 — a raw copy template must never reach a reader, and an admin tab
// must never fetch admin data on an anonymous boot.
//
// The bug: opening https://medibo.in/<anything-unknown> signed out drew the
// storefront with a red banner reading "Failed to load: {e}" — the BACKEND
// TEMPLATE, placeholder and all. Two defects stacked:
//
//   1. HomeShell builds its admin pages as IndexedStack children, and an
//      IndexedStack builds every child, so AdminCustomerScreen.initState ran
//      for a signed-out visitor, called admin_customer_screen_data, was
//      refused, and showed its error toast on the public storefront.
//   2. That toast passed {'a': '$e'} to a template that says {e}, so nothing
//      substituted and the placeholder itself was printed.
//
// Both halves are held down here. The second is a pure function, so it is
// asserted directly; the first is a wiring fact about a 14k-line screen that
// cannot be pumped in a VM test, so it is asserted against the source — the
// same technique the design literal gate uses.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/ui_copy.dart';

void main() {
  group('cf() never prints a template at the reader', () {
    setUp(() {
      UiCopy.debugSet(const {
        'admin_customer.failed_to_load': 'Failed to load: {e}',
        'x.two_slots': 'Sent {n} of {total} messages',
        'x.plain': 'Nothing to substitute',
      });
    });

    test('a filled placeholder still substitutes, verbatim', () {
      expect(cf('admin_customer.failed_to_load', {'e': 'boom'}),
          'Failed to load: boom');
      expect(cf('x.two_slots', {'n': '3', 'total': '9'}),
          'Sent 3 of 9 messages');
    });

    test('the exact bug: a wrong variable name prints no placeholder', () {
      final out = cf('admin_customer.failed_to_load', {'a': 'boom'});
      expect(out.contains('{'), isFalse, reason: 'the template leaked: $out');
      expect(out.contains('{e}'), isFalse);
      // The wording is still the backend's; only the unfilled slot and the
      // separator it left dangling are gone.
      expect(out, 'Failed to load');
    });

    test('a half-filled template loses only the slot that was not filled', () {
      expect(cf('x.two_slots', {'n': '3'}), 'Sent 3 of messages');
    });

    test('copy with no slots is untouched, and an unknown key stays empty', () {
      expect(cf('x.plain', const {}), 'Nothing to substitute');
      expect(cf('x.nope', const {'e': 'x'}), '');
      expect(c('x.nope'), '');
    });
  });

  group('an admin tab does not fetch on an anonymous boot', () {
    late String src;

    setUpAll(() {
      src = File('lib/screens/admin/admin_customer_screen_web.dart')
          .readAsStringSync();
    });

    test('the first load is gated on the session, not fired from initState',
        () {
      final start = src.indexOf('  void initState() {');
      final initState =
          src.substring(start, src.indexOf('\n  }\n', start));
      expect(initState.contains('\n    _load();'), isFalse,
          reason: 'initState runs for every visitor — an IndexedStack builds '
              'every child — so the first fetch cannot live there');
      expect(src.contains('didChangeDependencies'), isTrue);
      expect(src.contains('UserState.of(context).isAdmin'), isTrue,
          reason: 'the gate must read the session, never assume one');
    });

    test('the refusal path names the variable its own template uses', () {
      // {'a': ...} against a {e} template is what shipped the placeholder.
      final calls = RegExp(r"cf\('admin_customer\.failed_to_load', \{'(\w+)'")
          .allMatches(src)
          .map((m) => m.group(1))
          .toList();
      expect(calls, isNotEmpty);
      expect(calls.every((v) => v == 'e'), isTrue, reason: 'saw $calls');
    });
  });

  // The QA round on #633: gating the ONE screen that toasted only fixed that
  // screen. A live anonymous boot still fired eight admin_* RPCs, because the
  // IndexedStack built all eight admin children. The shell now decides whether
  // those pages exist at all, which is the only place that closes the class for
  // admin screens nobody has written yet.
  group('the shell builds no admin page for a stranger', () {
    late String shell;

    setUpAll(() {
      shell = File('lib/screens/home_shell.dart').readAsStringSync();
    });

    test('every admin page in the IndexedStack is built behind the gate', () {
      final start = shell.indexOf('final pages = [');
      expect(start, greaterThan(0), reason: 'the pages list moved');
      final pages = shell.substring(start, shell.indexOf('\n        ];', start));

      // The eight admin screens at indices 3-10. Each must be constructed
      // through adminPage(), never listed bare.
      const adminScreens = [
        'AdminDashboardScreen',
        'AdminAddMedicineScreen',
        'AdminSupplierScreen',
        'AdminCustomerScreen',
        'AdminMrScreen',
        'AdminCompanyScreen',
        'AdminDeliveryPartnerScreen',
        'AdminFulfillmentScreen',
      ];
      for (final screen in adminScreens) {
        expect(pages.contains(screen), isTrue, reason: '$screen left the list');
        for (final line in pages.split('\n')) {
          if (!line.contains(screen)) continue;
          expect(line.contains('adminPage(') || line.trimLeft().startsWith('child:'),
              isTrue,
              reason: '$screen is built for anonymous visitors: $line');
        }
      }
      expect(pages.contains('adminPage(() =>'), isTrue);
    });

    test('the gate reads the session and keeps every index', () {
      expect(shell.contains('isAdmin ? build() : const SizedBox.shrink()'),
          isTrue,
          reason: 'a non-admin must still get a placeholder at that index — '
              'indices 3-10 are addressed by number from _handleAdminNav');
      final gate = shell.indexOf('Widget adminPage(');
      final read = shell.indexOf('final isAdmin = UserState.of(context).isAdmin;');
      expect(read, greaterThan(0));
      expect(read, lessThan(gate), reason: 'the gate must read a real session');
    });

    test('the two account entry probes need a credential first', () {
      final start = shell.indexOf('  void _loadPosEntry() {');
      expect(start, greaterThan(0));
      final body = shell.substring(start, shell.indexOf('\n  }\n', start));
      expect(body.contains('auth.currentUser == null'), isTrue,
          reason: 'pos_entry and stock_entry are account questions — asking '
              'them signed out is two guaranteed 401s per stranger');
      expect(body.indexOf('return;'), lessThan(body.indexOf('PosEntry.load()')),
          reason: 'the guard must come before the calls');
    });
  });
}
