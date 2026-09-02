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

/// One `customer_nav_slot` row, as the migrations wrote it.
///
/// CHANGE #630 — the bottom bar's order and its audience are registry data, so
/// the fixture for both is the migration that seeds the table, exactly as the
/// customer_shop route list above is derived from the migrations that register
/// it. Reading the rows here is what keeps this test honest when the sequence
/// changes again: it will change in SQL, and this will read the new SQL.
class _NavSlot {
  final int pageIndex;
  final int sortOrder;
  final String visibility;
  const _NavSlot(this.pageIndex, this.sortOrder, this.visibility);
}

String _navMigrationSource() {
  final f = File('supabase/migrations/20260902_c630_nav_visibility.sql');
  expect(f.existsSync(), isTrue,
      reason: 'the nav visibility migration must exist');
  return f.readAsStringSync();
}

Map<String, _NavSlot> _navSlotRows() {
  final dir = Directory('supabase/migrations');
  expect(dir.existsSync(), isTrue, reason: 'run this from the package root');
  final rows = <String, _NavSlot>{};
  //   ('home', 'home_shell.home', 'home', 0, 10),
  final seed = RegExp(
      r"""\(\s*'([a-z_]+)'\s*,\s*'home_shell\.[a-z_]+'\s*,\s*'[a-z_]+'\s*,\s*(\d+)\s*,\s*(\d+)\s*\)""");
  //   set badge_key = 'shop', visibility = 'customer_only' ... slot_key = 'my_shop'
  final vis = RegExp(
      r"""visibility\s*=\s*'(always|customer_only)'[\s\S]{0,400}?slot_key\s*=\s*'([a-z_]+)'""");
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.sql')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final sql = f.readAsStringSync();
    if (!sql.contains('customer_nav_slot')) continue;
    for (final m in seed.allMatches(sql)) {
      rows[m.group(1)!] = _NavSlot(
          int.parse(m.group(2)!), int.parse(m.group(3)!), 'always');
    }
    for (final m in vis.allMatches(sql)) {
      final k = m.group(2)!;
      final r = rows[k];
      if (r != null) rows[k] = _NavSlot(r.pageIndex, r.sortOrder, m.group(1)!);
    }
  }
  expect(rows.length, greaterThanOrEqualTo(5),
      reason: 'expected the whole bottom bar, got ${rows.keys.toList()}');
  return rows;
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

/// Source with every `//` comment stripped.
///
/// CHANGE #536 QA round 3 — these files explain themselves at length, and the
/// explanations name the very identifiers this file counts. Counting
/// `pagesFor` over raw source would count the six times the comments say the
/// word, so the assertion would pass no matter how many real readers existed.
String _uncommented(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

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

    // CHANGE #536 QA round 3 — the registry can outrun the build.
    //
    // The two tests above read THIS checkout's migrations, so they were green
    // while three cshop_buying rows another command wrote at 15:56 UTC drew
    // three live tiles with no case in the shell. feature_registry is data: it
    // moves without a deploy, and no test of this repo can promise a deployed
    // build knows every key it will one day be handed. What the build CAN
    // promise is that an unknown key says so.
    test('an unrecognised route says so instead of falling through in silence',
        () {
      final src = _shellSource();
      expect(src.contains('default:'), isTrue,
          reason: 'the deep-link router must have a default arm — without one '
              'a registry row this build has never heard of is a tap that '
              'does nothing');
      final tail = src.substring(src.indexOf('default:'));
      expect(tail.contains("c('home_shell.route_unavailable')"), isTrue,
          reason: 'the sentence belongs to ui_copy, not to Dart');
      expect(tail.contains("RenderLog.write('c536_route_unknown'"), isTrue,
          reason: 'the render-log must name the key that had no door');
    });

    test('the cshop_buying trio is routed and self-gated', () {
      // Found live on CHANGE #983: registered onto customer_shop, drawn by the
      // tab, and every one of the three was a tap that did nothing.
      final src = _shellSource();
      for (final r in const [
        'cust_reorder_due',
        'cust_saved_lists',
        'cust_help_requests'
      ]) {
        expect(src.contains("case '$r':"), isTrue, reason: '$r has no case');
        expect(HomeShell.selfGatedRoutes.contains(r), isTrue,
            reason: '$r is parked for a pharmacy');
      }
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
      // and the assertion stays green while the door is gone.
      //
      // CHANGE #630 — Om moved the order (My Shop LAST) and ruled that
      // "registry sort_order owns it; do not hardcode the order in Dart". So
      // the slot->page map is no longer a Dart list to assert on; it is a
      // `customer_nav_slot` row, and the door is the row plus the two lines
      // that render it. All three are asserted here, and the Dart list is
      // asserted GONE — a change that quietly reinstates it fails.
      expect(_navSlotRows().containsKey('my_shop'), isTrue,
          reason: 'the registry must still carry a My Shop slot');
      expect(_navSlotRows()['my_shop']!.pageIndex, 11,
          reason: 'the My Shop slot must open page 11');
      expect(_uncommented(_barsSource()).contains('pagesFor'), isFalse,
          reason: 'the slot order is registry data now, not a Dart literal');
      expect(_uncommented(shell).contains('pagesFor'), isFalse,
          reason: 'the shell must not keep a copy of the slot map either');
      // QA round 3 (finding 301) — round 2's version asserted that the SHELL
      // also read the map. That was the bug, not the guard: two readers of one
      // map is a drift, and QA demonstrated it by forcing the bar's prop true
      // while the shell's own local kept the real value — the bar drew five
      // tabs, the shell mapped four, tapping My Shop opened Bulk upload, and
      // every test stayed green because both halves matched their own regex.
      // There is one reader now: `pageOf`, in the bar. It is declared once and
      // read exactly twice (the lit slot, and the tap), and nowhere else.
      expect('pageOf'.allMatches(_uncommented(_barsSource())).length, 3,
          reason: 'pageOf is declared once and read twice, in the bar');
      expect(_uncommented(shell).contains('pageOf'), isFalse,
          reason: 'the shell must not resolve a slot to a page itself');
      expect(
          RegExp(r'onTap:\s*\(i\)\s*\{\s*\n?\s*if\s*\(i\s*>=\s*0\s*&&\s*i\s*<\s*slots\.length\)\s*onPageTap\(pageOf\(slots\[i\]\)\)')
              .hasMatch(_barsSource()),
          isTrue,
          reason: 'the bar must resolve its own tap through the row it drew');
      expect(RegExp(r'onPageTap:\s*_setIndex').hasMatch(shell), isTrue,
          reason: 'the shell obeys the page the bar names, and computes none');
      expect(RegExp(r'valueListenable:\s*CustomerNav\.value').hasMatch(shell),
          isTrue,
          reason: 'the bar must be handed customer_nav()\'s own slots');
      expect(RegExp(r'slots:\s*slots').hasMatch(shell), isTrue,
          reason: 'and it must pass them through, not filter them here');

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
      // refuse them, and a signed-out visitor is not offered a tab whose only
      // possible answer is "sign in first".
      //
      // QA round 4 — this comment used to say anon holds no EXECUTE on
      // customer_shop_home(), so the tap "can only ever be a failed round
      // trip". #536 itself falsified that in round 3: finding 300 was that the
      // 42501 surfaced to a deep-linking visitor as "check your connection",
      // which is untrue, so anon was GRANTED execute and the function now
      // answers ok:false / not_signed_in with its own ui_copy sentence
      // (cshop.err_signed_out). The tab is still withheld — a visitor has
      // nothing to open — but the reason is that there is no shop to show,
      // not that the RPC would throw.
      expect(header.contains('isAuthenticated'), isTrue);
      expect(header.contains('!UserState.of(context).isAdmin'), isTrue);

      // QA round 2 — the mobile half of the SAME rule. Round 1 gated the
      // desktop header and left a comment claiming the mobile bar already did
      // it; the bar was picked on isAdmin alone, so an anonymous visitor was
      // shown the tab and got a blank page.
      //
      // CHANGE #630 — the mobile bar is registry-driven, and a bar that hides
      // a slot by position is exactly how a hole appears in a list the shell
      // also indexes. So the rule moved onto the ROW (`visibility`) and is
      // resolved inside customer_nav() against the caller. The Dart half is
      // asserted GONE and the SQL half is asserted PRESENT — the audience rule
      // cannot be deleted by either stack alone.
      expect(_uncommented(_shellSource()).contains('showMyShop'), isFalse,
          reason: 'the mobile audience rule is the row\'s, not the shell\'s');
      expect(_uncommented(_barsSource()).contains('showMyShop'), isFalse,
          reason: 'the bar renders the slots it is given, and gates none');
      final navSql = _navMigrationSource();
      expect(_navSlotRows()['my_shop']!.visibility, 'customer_only',
          reason: 'My Shop must not be offered to anon or to an admin');
      expect(navSql.contains('auth.uid() is not null'), isTrue,
          reason: 'customer_nav() must know whether the caller is signed in');
      expect(navSql.contains('_is_admin()'), isTrue,
          reason: 'customer_nav() must know whether the caller is an admin');
      expect(
          RegExp(r"visibility\s*=\s*'always'\s*\n?\s*or\s*\(\s*me\.signed_in\s+and\s+not\s+me\.is_admin\s*\)")
              .hasMatch(navSql),
          isTrue,
          reason: 'a customer_only slot needs BOTH conditions, not isAdmin alone');
    });

    // ── Om's placement decision (#630, superseding #536) ────────────────────
    test('the sequence is Home · Catalogue · Bulk · Orders · My Shop', () {
      // Om, live on #630: "customer bottom-nav SEQUENCE changes to exactly:
      // Home · Catalogue · Bulk · Orders · My Shop (My Shop LAST, Bulk moves
      // to third). Registry sort_order owns it; do not hardcode the order in
      // Dart." #536 put My Shop fourth and asserted the order by the position
      // of five `c('home_shell.*')` literals in the bar; those literals are
      // gone, and asserting on their order would only prove the bar had been
      // hardcoded again. The order is one column now, so that is what is read.
      final rows = _navSlotRows();
      for (final k in const ['home', 'catalogue', 'bulk', 'orders', 'my_shop']) {
        expect(rows.containsKey(k), isTrue, reason: 'no $k slot registered');
      }
      final order = rows.entries.toList()
        ..sort((a, b) => a.value.sortOrder.compareTo(b.value.sortOrder));
      expect(order.map((e) => e.key).toList(),
          const ['home', 'catalogue', 'bulk', 'orders', 'my_shop'],
          reason: 'Om: My Shop LAST, Bulk third');
      // And the bar must draw them in the order it was handed, with no sort of
      // its own — the whole point of moving the sequence into a column.
      expect(_uncommented(_barsSource()).contains('for (final s in slots)'),
          isTrue,
          reason: 'the bar renders the payload order verbatim');
      expect(RegExp(r'slots\s*\.\s*sort\(').hasMatch(_uncommented(_barsSource())),
          isFalse,
          reason: 'a client-side sort would take the order back off the row');
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
      // CHANGE #630 — #536 asserted here that hiding My Shop renumbered a Dart
      // list rather than leaving a hole. There is no list to renumber now: the
      // backend simply does not send the slot, and the bar finds the lit tab by
      // matching the row's own page_index instead of counting positions. That
      // is the same guarantee, stated where it now lives.
      expect(
          RegExp(r'slots\.indexWhere\(\(s\)\s*=>\s*pageOf\(s\)\s*==\s*index\)')
              .hasMatch(_barsSource()),
          isTrue,
          reason: 'the lit slot is found by page, never by a counted position');
      expect(_barsSource().contains('found < 0 ? 0 : found'), isTrue,
          reason: 'a page with no slot falls back to Home, never to a hole');
    });
  });
}
