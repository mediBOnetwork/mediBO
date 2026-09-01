// PROTECTED — CHANGE #536, hostile QA round 1 finding #273 (blocker).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes My Shop reachability, never to make an unrelated change
// go green.
//
// THE BUG THIS RETIRES, IN ITS OWN WORDS
//
// #536 moved the whole pharmacy suite onto a customer surface and gave it a
// fifth bottom-bar slot. The bottom bar only exists in `_buildMobile`.
// `_buildDesktop` renders the SAME IndexedStack from a header that offered
// Bulk Upload / Orders / Cart / Bell / Profile and nothing else — and the same
// change deleted the account-menu counter row and the four profile tiles. So a
// pharmacy on a laptop came out of the change with strictly FEWER doors into
// the suite than it went in with, and Counter POS is a laptop-at-the-till
// screen. The only path left at >=900px was hand-typing /admin/go/my_shop.
//
// The second half of the same class: `refill` had a route case, a screen and a
// registry tile, but was missing from `selfGatedRoutes` — so /admin/go/refill
// was parked for every pharmacy (who is not an admin) and landed on the
// storefront in silence. #432 and #440 each hit that once before.
//
// So this file does not test one door. It tests the INVARIANT both bugs broke:
//
//   Every feature registered on the customer_shop surface must be openable
//   from a customer account, in every layout the shell can render.
//
// It derives the feature list from the MIGRATIONS rather than repeating it —
// registering a twentieth tile is still one INSERT, but that INSERT now has to
// come with its route case and its self-gate or this test goes red.
//
// No network, no Supabase, no goldens: the shell's own source and the repo's
// own migrations are the fixtures.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/home_shell.dart';

/// Every route_key any migration registers onto surface='customer_shop'.
///
/// The rows are written one per line as
///   ('feature.key', 'Label', 'Caption', 'Group', 'icon', 'route_key', 10, ...
/// followed on the same line by 'customer_shop'. Reading them here is what
/// keeps this test honest as the registry grows.
Set<String> _registeredCustomerShopRoutes() {
  final dir = Directory('supabase/migrations');
  expect(dir.existsSync(), isTrue,
      reason: 'run this from the package root — supabase/migrations must exist');

  final routes = <String>{};
  // ('key', 'Label', 'Caption', 'Group', 'icon', 'route_key', <sort>,
  final row = RegExp(
      r"""\(\s*'[^']+'\s*,\s*'[^']*'\s*,\s*'[^']*'\s*,\s*'[^']*'\s*,\s*'[^']*'\s*,\s*'([a-z_0-9]+)'\s*,\s*\d+""");

  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.sql')) continue;
    final sql = f.readAsStringSync();
    if (!sql.contains("'customer_shop'")) continue;
    for (final line in sql.split('\n')) {
      if (!line.contains("'customer_shop'")) continue;
      final m = row.firstMatch(line);
      if (m != null) routes.add(m.group(1)!);
    }
  }
  return routes;
}

String _shellSource() {
  final f = File('lib/screens/home_shell.dart');
  expect(f.existsSync(), isTrue, reason: 'run this from the package root');
  return f.readAsStringSync();
}

String _headerSource() {
  final f = File('lib/screens/shell/shell_header_chrome.dart');
  expect(f.existsSync(), isTrue, reason: 'run this from the package root');
  return f.readAsStringSync();
}

void main() {
  group('My Shop reachability — the invariant #536 broke and then fixed', () {
    test('the migrations really do register a customer_shop suite', () {
      final routes = _registeredCustomerShopRoutes();
      // A parser that silently matched nothing would make every assertion
      // below vacuously true, which is how a regression guard becomes theatre.
      expect(routes.length, greaterThanOrEqualTo(19),
          reason: 'expected the whole pharmacy suite, got $routes');
      expect(routes, contains('pos'));
      expect(routes, contains('khata'));
      // Found by QA round 2: the spec names Purchase reports in Money and
      // PurchasesScreen (CMD #367) was built, but its only door was a button
      // buried inside Orders.
      expect(routes, contains('purchases'));
    });

    test('every registered tile has a route case in the shell', () {
      final src = _shellSource();
      final missing = <String>[];
      for (final r in _registeredCustomerShopRoutes()) {
        if (!src.contains("case '$r':")) missing.add(r);
      }
      expect(missing, isEmpty,
          reason: 'these tiles render and then do nothing when tapped: $missing');
    });

    test('every registered tile is self-gated, so its deep link opens', () {
      // A key missing here is re-parked for anyone who is not an admin — a
      // pharmacy — and /admin/go/<key> lands on the storefront in silence.
      // This is exactly what happened to `refill`.
      final missing = <String>[];
      for (final r in _registeredCustomerShopRoutes()) {
        if (!HomeShell.selfGatedRoutes.contains(r)) missing.add(r);
      }
      expect(missing, isEmpty,
          reason: 'deep links silently dead-end for a pharmacy: $missing');
    });

    test('my_shop itself is both routed and self-gated', () {
      expect(_shellSource(), contains("case 'my_shop':"));
      expect(HomeShell.selfGatedRoutes, contains('my_shop'));
    });

    test('BOTH layouts carry a door into the My Shop page', () {
      final shell = _shellSource();
      final header = _headerSource();

      // Mobile: the bottom bar's fifth slot.
      expect(shell.contains('onNavTap'), isTrue,
          reason: 'the mobile bottom bar is how a phone reaches My Shop');

      // Desktop: the header link added by QA round 1. Without it the desktop
      // shell rendered page 11 and offered no way to select it.
      expect(header.contains('onMyShop'), isTrue,
          reason: 'the desktop header lost its My Shop link — finding #273');
      expect(shell.contains('onMyShop:'), isTrue,
          reason: '_buildDesktop must pass the callback it declares');

      // And the door must actually land on the My Shop page, not merely exist.
      expect(RegExp(r'onMyShop:\s*\(\)\s*=>\s*_setIndex\(11\)').hasMatch(shell),
          isTrue,
          reason: 'the desktop link must select the My Shop page (index 11)');
    });

    test('the desktop door is offered to a pharmacy, not to an admin', () {
      final header = _headerSource();
      // Same rule the mobile bar uses. An admin browsing the storefront is not
      // offered a suite that would refuse them, and a signed-out visitor is
      // not offered a tab that cannot load.
      expect(header.contains('isAuthenticated'), isTrue);
      expect(header.contains('!UserState.of(context).isAdmin'), isTrue);
    });
  });
}
