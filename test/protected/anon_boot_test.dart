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
}
