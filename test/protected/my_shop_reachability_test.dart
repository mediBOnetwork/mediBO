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

String _barsSource() {
  final f = File('lib/screens/shell/shell_bottom_bars.dart');
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

      // Mobile: the bottom bar's My Shop slot.
      //
      // QA round 2 — this used to be `shell.contains('onNavTap')`, which is
      // true of any shell that has ANY bottom bar: repoint the slot at page 3
      // and the assertion stays green while the door is gone. The mobile door
      // is now the slot->page map the bar exports and the shell obeys, so the
      // assertion is on the map itself, and on the shell reading it rather
      // than hand-rolling a second copy that can drift.
      expect(
          RegExp(r'pagesFor\(bool\s+showMyShop\)\s*=>\s*\n?\s*showMyShop\s*\?\s*const\s*\[0,\s*0,\s*1,\s*11,\s*2\]')
              .hasMatch(_barsSource()),
          isTrue,
          reason: 'Om: Home - Catalogue - Orders - My Shop - Bulk');
      expect(shell.contains('_MobileBottomBar.pagesFor('), isTrue,
          reason: 'the shell must navigate by the bar\'s own map, not a copy');
      expect(RegExp(r'onNavTap:\s*\(i\)\s*\{\s*\n?\s*if\s*\(i\s*>=\s*0\s*&&\s*i\s*<\s*slots\.length\)\s*_setIndex\(slots\[i\]\)')
              .hasMatch(shell),
          isTrue,
          reason: 'a mobile tap must open the page its own slot map names');

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

    test('BOTH doors are offered to a pharmacy, not to an admin or a visitor',
        () {
      final header = _headerSource();
      // An admin browsing the storefront is not offered a suite that would
      // refuse them, and a signed-out visitor is not offered a tab that cannot
      // load — customer_shop_home() has no EXECUTE for anon, so that tap can
      // only ever be a failed round trip.
      expect(header.contains('isAuthenticated'), isTrue);
      expect(header.contains('!UserState.of(context).isAdmin'), isTrue);

      // QA round 2 — the mobile half of the SAME rule. Round 1 gated the
      // desktop header and left a comment claiming the mobile bar already did
      // it; the bar was picked on isAdmin alone, so an anonymous visitor was
      // shown the tab and got a blank page. The shell must compute showMyShop
      // from BOTH conditions and hand it to the bar, and the bar must drop the
      // slot when it is false.
      expect(
          RegExp(r'showMyShop\s*=\s*UserState\.of\(ctx\)\.isAuthenticated\s*&&\s*\n?\s*!UserState\.of\(ctx\)\.isAdmin')
              .hasMatch(_shellSource()),
          isTrue,
          reason: 'the mobile door must use the desktop rule, not isAdmin alone');
      expect(_barsSource().contains('if (showMyShop)'), isTrue,
          reason: 'the My Shop slot must not be drawn when it is not offered');
    });

    // ── Om's placement decision (#536) ───────────────────────────────────────
    test('My Shop is the FIFTH tab, between Orders and Bulk', () {
      final bars = _barsSource();
      // The ITEM order must match the slot map, or the tab a thumb presses is
      // not the page it opens. Orders' receipt icon comes before the storefront
      // icon, and Bulk's upload icon after it.
      final orders = bars.indexOf("c('home_shell.orders')");
      final myShop = bars.indexOf("c('home_shell.my_shop')");
      final bulk = bars.indexOf("c('home_shell.bulk')");
      expect(orders, greaterThan(-1));
      expect(myShop, greaterThan(-1));
      expect(bulk, greaterThan(-1));
      expect(orders, lessThan(myShop),
          reason: 'Orders keeps the position its thumbs know');
      expect(myShop, lessThan(bulk), reason: 'My Shop sits before Bulk');
    });

    // Om: "The storefront home stays exactly as it is — do not insert shop
    // tiles into it." The suite lives on its own page and is reached by its own
    // tab; a future change that drops it into the storefront feed fails here.
    test('the shop surface is a page of its own, never folded into the home',
        () {
      final shell = _shellSource();
      expect(RegExp('MyShopScreen').allMatches(shell).length, 1,
          reason: 'exactly one construction, in the pages list — a second one '
              'means the suite has been folded into another page');
      expect(shell.contains("case 'my_shop':"), isTrue);
      // And it is page 11, the slot the map and both doors agree on.
      expect(RegExp(r"case 'my_shop':\s*\n\s*setState\(\(\) \{ _index = 11;")
              .hasMatch(shell),
          isTrue);
    });

    test('the tab badge is the backend answer, never a count computed here',
        () {
      final bars = _barsSource();
      // `show` is the flag. A bar that drew the badge on `count > 0` would be
      // deciding "where meaningful" for itself — Om gave that to the backend.
      expect(bars.contains('ShopBadge.show'), isTrue);
      expect(bars.contains('ShopBadge.label'), isTrue);

      // Scoped to the badge helper: the sticky cart bar below it has its own
      // unrelated `> 0` arithmetic, and a whole-file match would report that.
      final from = bars.indexOf('static Widget _shopBadge(');
      expect(from, greaterThan(-1));
      final helper = bars.substring(from, bars.indexOf('\n\n', from));
      expect(helper.contains('isLabelVisible: ShopBadge.show'), isTrue,
          reason: 'the bar must not decide a badge is meaningful');
      expect(RegExp(r'[><]\s*0').hasMatch(helper), isFalse,
          reason: 'no count arithmetic in the badge — the backend sent show');

      // And the number is printed, not formatted: the 99+ cap lives in SQL.
      final api = File('lib/services/customer_shop_api.dart').readAsStringSync();
      expect(api.contains("value.value['count_label']"), isTrue);
      // The LITERAL, not the word: the doc comment explains where the cap
      // lives, and explaining it is the opposite of re-implementing it.
      expect(api.contains("'99+'"), isFalse,
          reason: 'the badge cap is a backend decision, not a Dart literal');
      expect(
          RegExp(r'showMyShop\s*\?\s*const\s*\[0,\s*0,\s*1,\s*11,\s*2\]\s*:\s*const\s*\[0,\s*0,\s*1,\s*2\]')
              .hasMatch(_barsSource()),
          isTrue,
          reason: 'hiding the slot must renumber the map, never leave a hole');
    });
  });
}
