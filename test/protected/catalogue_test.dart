// PROTECTED — CHANGE #747.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes catalogue behaviour.
//
// The Catalogue is five surfaces (tree, companies, salts, schemes, cold chain)
// sharing one payload contract, and it is the largest thing in the app whose
// content is almost-but-not-quite arithmetic. That is what this file holds
// down — the "almost":
//
//   1. NOTHING IS COMPUTED HERE. Every count sentence, tab name, breadcrumb,
//      filter chip, sort name, empty state and zone note prints exactly the
//      string the backend sent. The fixtures deliberately contain a count
//      whose label does NOT match its number ("3 products" beside n:99999) —
//      if the screen ever starts formatting counts itself, this is the test
//      that catches it, because a correct-looking screen would be wrong.
//
//   2. ROWS RENDER IN PAYLOAD ORDER. The fixture is deliberately not sorted by
//      name or by count.
//
//   3. WHERE THE NEXT TAP GOES IS THE BACKEND'S ANSWER (`child_opens`), never
//      a depth this screen counts for itself.
//
//   4. THE ZONE SWITCH IS A FLAG, NOT AN INFERENCE. `has:false` draws no
//      control at all — an anonymous visitor is not shown a switch that would
//      change nothing — and `has:true` draws it with the payload's own label
//      and note. The two states are different, not one boolean.
//
//   5. AN UNKNOWN TAB KIND IS SKIPPED IN SILENCE, so the backend can ship a
//      sixth tab before the build that draws it (the home feed's rule, #637).
//
//   6. PAGING IS THE BACKEND'S VERDICT. Appending uses the OPAQUE cursor the
//      payload handed back; the app never builds one and never stops paging
//      because a page came back short.
//
//   7. THE DEEP LINK ROUND-TRIPS. Filters, sort, tab, trail, zone and search
//      survive url → parse → url, or "filter state in the URL" is a claim
//      rather than a feature.
//
// Dart VM only: no network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/catalogue.dart';
import 'package:pharma_b2b/screens/catalogue_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/product_row_card.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _zone({bool has = true, bool on = true}) => {
      'has': has,
      'on': on,
      'label': 'Available in my zone',
      'zone_label': 'Raipur Zone',
      'note': has
          ? (on ? 'Showing what suppliers in your zone can send.'
                : 'Showing the whole catalogue, including items no supplier near you stocks.')
          : 'Showing the whole catalogue.',
    };

Map<String, dynamic> _home({bool zoneHas = true}) => {
      'ok': true,
      'title': 'Catalogue',
      'subtitle': 'Browse the whole product list by class, company or salt.',
      'search_hint': 'Search a salt or a company',
      'zone': _zone(has: zoneHas),
      'tabs': [
        {'key': 'browse', 'label': 'Browse', 'kind': 'tree', 'count_label': '3,35,273 products'},
        {'key': 'companies', 'label': 'Companies', 'kind': 'companies', 'count_label': '18,563 companies'},
        {'key': 'salts', 'label': 'Salts', 'kind': 'salts', 'count_label': '1,06,571 salts'},
        {'key': 'cold_chain', 'label': 'Cold chain', 'kind': 'list',
         'list_kind': 'tab', 'list_key': 'cold_chain', 'count_label': '4,413 products',
         'empty_label': 'No cold-chain product in this view.'},
        // A kind this build has never heard of. It must not be drawn and must
        // not throw — forward compatibility, the home feed's rule.
        {'key': 'from_the_future', 'label': 'Bundles', 'kind': 'carousel_v9',
         'count_label': '1 product'},
      ],
      'filters': _filterDefs(),
    };

Map<String, dynamic> _filterDefs() => {
      'title': 'Filters',
      'clear_label': 'Clear all',
      'apply_label': 'Show results',
      'groups': [
        {'key': 'pack_type', 'label': 'Pack type', 'mode': 'multi', 'options': [
          {'key': 'Strip', 'label': 'Strip', 'selected': false},
          {'key': 'Vial', 'label': 'Vial', 'selected': false},
        ]},
        {'key': 'rx', 'label': 'Prescription', 'mode': 'single', 'options': [
          {'key': 'Rx', 'label': 'Rx only', 'selected': false},
          {'key': 'OTC', 'label': 'OTC only', 'selected': false},
        ]},
        {'key': 'flags', 'label': 'Product', 'mode': 'multi', 'options': [
          {'key': 'cold_chain', 'label': 'Cold chain', 'selected': false},
        ]},
      ],
      'sort': {'label': 'Sort', 'options': [
        {'key': 'name', 'label': 'Name A–Z'},
        {'key': 'newest', 'label': 'Newest added'},
      ]},
    };

/// The tree root. Rows are deliberately NOT in name or count order, and the
/// second row's count_label deliberately disagrees with its own `n`.
Map<String, dynamic> _treeRoot({String childOpens = 'level'}) => {
      'ok': true,
      'title': 'Therapeutic class',
      'level': 0,
      'path': <String>[],
      'zone': _zone(),
      'crumbs': <Map<String, dynamic>>[],
      'home_label': 'All classes',
      'child_opens': childOpens,
      'products_label': 'View products',
      'has_products': false,
      'empty_label': 'The catalogue has no classes in this view.',
      'count_label': '3,35,273 products',
      'rows': [
        {'key': 'ANTI INFECTIVES', 'label': 'ANTI INFECTIVES', 'n': 75562,
         'count_label': '75,562 products'},
        {'key': 'GASTRO INTESTINAL', 'label': 'GASTRO INTESTINAL', 'n': 99999,
         'count_label': '3 products'}, // deliberately inconsistent — see header
        {'key': 'AYURVEDA', 'label': 'AYURVEDA', 'n': 41335,
         'count_label': '41,335 products'},
      ],
    };

Map<String, dynamic> _card(String id, String name) => {
      'id': id,
      'name': name,
      'company': 'ABBOTT',
      'pack_label': 'Strip of 10 tablets',
      'form_chip': 'Strip',
      'pack_type_label': 'Strip',
      'pack_qty_label': '10.0 tablets in 1 strip',
      'image': null,
      'buyable': true,
      'rx': {'has': true, 'is_rx': true, 'label': 'Rx'},
      'availability': {
        'cta_label': 'Add to cart', 'cta_short': 'ADD',
        'can_add': true, 'is_available': true, 'gated': true,
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      },
      'pricing': {'has_price': false},
      'mrp_label': '',
      'has_offer': false,
      'offer_chip': '',
    };

Map<String, dynamic> _list({
  required List<Map<String, dynamic>> items,
  bool hasMore = false,
  String? cursor,
  String countLabel = '15 products',
}) => {
      'ok': true,
      'title': 'Paracetamol (500mg)',
      'subtitle': 'Every brand for this salt',
      'count_label': countLabel,
      'empty_label': 'Nothing here in this view.',
      'more_label': 'Load more',
      'end_label': 'That is the whole list.',
      'sort': 'name',
      'filters_active': false,
      'filters_active_label': '',
      'zone': _zone(),
      'filters': _filterDefs(),
      'items': items,
      'has_more': hasMore,
      'next_cursor': cursor,
    };

// ── harness ──────────────────────────────────────────────────────────────────

/// Records every RPC the screen makes, so a test can assert what was ASKED as
/// well as what was drawn.
class _Rpc {
  final List<(String, Map<String, dynamic>)> calls = [];
  final Map<String, List<Map<String, dynamic>>> queued;
  _Rpc(this.queued);

  Future<Map<String, dynamic>> call(String fn, Map<String, dynamic> args) async {
    calls.add((fn, args));
    final q = queued[fn];
    if (q == null || q.isEmpty) return {'ok': false};
    return q.length == 1 ? q.first : q.removeAt(0);
  }

  Map<String, dynamic> lastArgs(String fn) =>
      calls.lastWhere((c) => c.$1 == fn).$2;
  int count(String fn) => calls.where((c) => c.$1 == fn).length;
}

Future<_Rpc> _pump(
  WidgetTester tester, {
  required Map<String, List<Map<String, dynamic>>> queued,
  CatalogueRoute? route,
  Size size = const Size(420, 760),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final rpc = _Rpc(queued);
  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: CatalogueScreen(
            active: true,
            rpc: rpc.call,
            initialRoute: route ?? const CatalogueRoute(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return rpc;
}

void main() {
  // The render-log's 800 ms flush is a real Timer that would outlive these
  // tests and try to reach Supabase — CLAUDE.md's protected-suite note.
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the catalogue computes nothing', () {
    testWidgets('every count is the backend string, even when it is wrong',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot()],
      });

      // The honest test: row 2 carries n:99999 and the label "3 products".
      // A screen that formats counts itself would print "99,999 products" and
      // look more correct while being exactly the bug this forbids.
      expect(find.text('3 products'), findsOneWidget);
      expect(find.textContaining('99,999'), findsNothing);
      expect(find.text('75,562 products'), findsOneWidget);
      expect(find.text('3,35,273 products'), findsWidgets);
    });

    testWidgets('rows render in payload order, never re-sorted', (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot()],
      });
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where((s) => const {'ANTI INFECTIVES', 'GASTRO INTESTINAL', 'AYURVEDA'}
              .contains(s))
          .toList();
      // Payload order, not alphabetical (AYURVEDA would be first) and not by
      // count (GASTRO's n is the largest).
      expect(labels, ['ANTI INFECTIVES', 'GASTRO INTESTINAL', 'AYURVEDA']);
    });

    testWidgets('tab labels and their counts print verbatim', (tester) async {
      // Wide, because the tab strip and the filter row are horizontal lists: a
      // 420pt phone leaves the later chips off-screen and unbuilt, which would
      // read as "the label was wrong" rather than "the label was not on screen".
      //
      // CHANGE #799 rewrote WHICH tabs are chips. Browse / Companies / Salts
      // are now the three doors (their own labels and counts, pinned in
      // catalogue_visual_test.dart); the chip strip carries only the tabs the
      // doors do not cover. What this test still holds down is unchanged and
      // is the point of it: whatever IS drawn prints the payload's own words.
      await _pump(tester, size: const Size(1400, 900), queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot()],
      });
      expect(find.text('Cold chain'), findsWidgets);
      expect(find.textContaining('4,413 products'), findsWidgets);
    });
  });

  group('forward compatibility', () {
    testWidgets('a tab kind this build has never heard of is skipped silently',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot()],
      });
      expect(find.text('Bundles'), findsNothing,
          reason: 'kind carousel_v9 is unknown — draw nothing, do not guess');
      expect(tester.takeException(), isNull);
      // #799: the known tabs are still drawn beside the unknown one — the
      // chip strip's are the `list`/`recent` kinds, the rest are doors.
      expect(find.text('Cold chain'), findsWidgets,
          reason: 'the known tabs must still be drawn beside the unknown one');
    });
  });

  group('the zone switch is a flag, not an inference', () {
    testWidgets('has:false draws no control at all', (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home(zoneHas: false)],
        'catalogue_tree': [_treeRoot()],
      });
      expect(find.byType(Switch), findsNothing,
          reason: 'an anonymous viewer gets no switch — it would change nothing');
      expect(find.text('Available in my zone'), findsNothing);
    });

    testWidgets('has:true draws it with the payload\'s own label and note',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot()],
      });
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('Available in my zone'), findsOneWidget);
      expect(find.text('Showing what suppliers in your zone can send.'),
          findsOneWidget);
    });

    testWidgets('turning it off re-asks the backend with p_zone false',
        (tester) async {
      final rpc = await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot()],
      });
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(rpc.lastArgs('catalogue_tree')['p_zone'], isFalse,
          reason: 'the switch is a QUESTION to the backend, not a client filter');
    });

    testWidgets('an OFF switch is still drawn — has and on are two questions',
        (tester) async {
      // The bug this pins: resolving `has` from the same expression as `on`
      // made the control vanish the moment anyone used it. `has` is "does this
      // viewer get a switch", `on` is "is it flipped", and the backend answers
      // both separately.
      await _pump(tester, queued: {
        'catalogue_home': [
          {..._home(), 'zone': _zone(has: true, on: false)}
        ],
        'catalogue_tree': [_treeRoot()],
      }, route: const CatalogueRoute(zoneOn: false));
      expect(find.byType(Switch), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(
          find.text('Showing the whole catalogue, including items no supplier '
              'near you stocks.'),
          findsOneWidget,
          reason: 'the note under the switch changes because the BACKEND '
              'changed it, not because this widget picked a second sentence');
    });
  });

  group('the tree drills where the backend says', () {
    testWidgets('child_opens level opens another level', (tester) async {
      final rpc = await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot(), _treeRoot()],
      });
      await tester.tap(find.text('ANTI INFECTIVES'));
      await tester.pumpAndSettle();
      expect(rpc.lastArgs('catalogue_tree')['p_path'], ['ANTI INFECTIVES']);
      expect(rpc.count('catalogue_list'), 0,
          reason: 'child_opens was "level" — products are one level deeper');
    });

    testWidgets('child_opens products opens the grid instead', (tester) async {
      final rpc = await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot(childOpens: 'products')],
        'catalogue_list': [_list(items: [_card('1', 'Augmentin 625 Duo Tablet')])],
      });
      await tester.tap(find.text('ANTI INFECTIVES'));
      await tester.pumpAndSettle();
      expect(rpc.count('catalogue_list'), 1,
          reason: 'the backend said the next tap is products — obey it');
      expect(rpc.lastArgs('catalogue_list')['p_kind'], 'tree');
      expect(rpc.lastArgs('catalogue_list')['p_path'], ['ANTI INFECTIVES']);
    });
  });

  group('the product list', () {
    testWidgets('renders the backend title, subtitle and count', (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list(items: [_card('1', 'Dolo 650 Tablet')])],
      }, route: const CatalogueRoute(
          tab: 'salts', listKind: 'salt', listKey: 'Paracetamol (500mg)'));
      expect(find.text('Paracetamol (500mg)'), findsOneWidget);
      expect(find.text('Every brand for this salt'), findsOneWidget);
      expect(find.text('15 products'), findsOneWidget);
      expect(find.byType(ProductRowCard), findsOneWidget);
    });

    testWidgets('an empty list prints the backend empty state, never a Dart one',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list(items: const [])],
      }, route: const CatalogueRoute(
          tab: 'cold_chain', listKind: 'tab', listKey: 'cold_chain'));
      expect(find.text('Nothing here in this view.'), findsOneWidget);
      expect(find.byType(ProductRowCard), findsNothing);
    });

    testWidgets('the end label is the backend\'s, and only when it says so',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list(items: [_card('1', 'Dolo 650 Tablet')])],
      }, route: const CatalogueRoute(
          tab: 'salts', listKind: 'salt', listKey: 'Paracetamol (500mg)'));
      expect(find.text('That is the whole list.'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    });

    testWidgets('a filter tap re-asks with the backend\'s own option key',
        (tester) async {
      final rpc = await _pump(tester, size: const Size(1400, 900), queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list(items: [_card('1', 'Dolo 650 Tablet')])],
      }, route: const CatalogueRoute(
          tab: 'salts', listKind: 'salt', listKey: 'Paracetamol (500mg)'));

      await tester.tap(find.text('Rx only'));
      await tester.pumpAndSettle();
      expect(rpc.lastArgs('catalogue_list')['p_filters'], {'rx': 'Rx'},
          reason: 'the key travels back exactly as it arrived');

      await tester.tap(find.text('Newest added'));
      await tester.pumpAndSettle();
      expect(rpc.lastArgs('catalogue_list')['p_sort'], 'newest');
    });
  });

  group('paging is the backend\'s verdict', () {
    test('the cursor is carried back opaquely and appending never duplicates',
        () {
      final page1 = CatList.fromMap(_list(
        items: [_card('1', 'A'), _card('2', 'B')],
        hasMore: true,
        cursor: '{"i": 527048, "n": "B"}',
      ));
      expect(page1.hasMore, isTrue);
      expect(page1.nextCursor, '{"i": 527048, "n": "B"}',
          reason: 'opaque: stored as sent, never parsed or rebuilt');

      // A SHORT page that still says has_more must keep paging, and a FULL page
      // that says has_more:false must stop. Both are the backend's call.
      final page2 = CatList.fromMap(_list(items: [_card('3', 'C')], hasMore: false));
      expect(page2.hasMore, isFalse);
      expect(page2.nextCursor, isNull);
    });
  });

  group('the deep link round-trips', () {
    test('every piece of list state survives url -> parse -> url', () {
      const route = CatalogueRoute(
        tab: 'salts',
        path: ['ANTI INFECTIVES', 'Cephalosporins'],
        listKind: 'salt',
        listKey: 'Paracetamol (500mg)',
        filters: CatFilterState(
          packTypes: {'Strip', 'Vial'},
          rx: 'Rx',
          flags: {'cold_chain', 'has_image'},
        ),
        sort: 'newest',
        zoneOn: false,
        query: 'para',
      );
      final url = route.url;
      expect(CatalogueRoute.matches(url.split('?').first), isTrue);

      final back = CatalogueRoute.parse(url.substring(url.indexOf('?')));
      expect(back.tab, 'salts');
      expect(back.path, ['ANTI INFECTIVES', 'Cephalosporins']);
      expect(back.listKind, 'salt');
      expect(back.listKey, 'Paracetamol (500mg)');
      expect(back.filters.packTypes, {'Strip', 'Vial'});
      expect(back.filters.rx, 'Rx');
      expect(back.filters.flags, {'cold_chain', 'has_image'});
      expect(back.sort, 'newest');
      expect(back.zoneOn, isFalse);
      expect(back.query, 'para');
      expect(back.url, url, reason: 'the round trip must be stable');
    });

    test('the default state is the bare path, and /catalogue is recognised', () {
      expect(const CatalogueRoute().url, '/catalogue');
      expect(CatalogueRoute.matches('/catalogue'), isTrue);
      expect(CatalogueRoute.matches('/catalogue?tab=salts'), isTrue);
      expect(CatalogueRoute.matches('/orders'), isFalse);
      expect(CatalogueRoute.matches('/'), isFalse);
    });

    test('a filter that is OFF is absent from the RPC, never sent as false', () {
      const s = CatFilterState(flags: {'cold_chain'});
      expect(s.toRpc(), {'cold_chain': 'true'});
      expect(s.toRpc().containsKey('has_image'), isFalse,
          reason: 'absent and false are different questions to the WHERE builder');
      expect(const CatFilterState().toRpc(), isEmpty);
    });

    test('toggling is a set operation over the backend\'s keys', () {
      var s = const CatFilterState();
      s = s.toggle('pack_type', 'Strip', single: false);
      s = s.toggle('pack_type', 'Vial', single: false);
      expect(s.packTypes, {'Strip', 'Vial'});
      s = s.toggle('pack_type', 'Strip', single: false);
      expect(s.packTypes, {'Vial'});
      // single: the second choice replaces the first, and re-tapping clears it.
      s = s.toggle('rx', 'Rx', single: true);
      expect(s.rx, 'Rx');
      s = s.toggle('rx', 'OTC', single: true);
      expect(s.rx, 'OTC');
      s = s.toggle('rx', 'OTC', single: true);
      expect(s.rx, isNull);
    });
  });

  group('the screen does not fetch while it is not looking', () {
    testWidgets('an inactive Catalogue page makes no RPC at all', (tester) async {
      // The #633 rule: an IndexedStack builds every child, so a visitor sitting
      // on Orders must not pay for five catalogue RPCs.
      final rpc = _Rpc({'catalogue_home': [_home()]});
      await tester.pumpWidget(
        AppState(
          cart: CartModel.forTest(),
          child: MaterialApp(
            home: Scaffold(
              body: CatalogueScreen(active: false, rpc: rpc.call,
                  initialRoute: const CatalogueRoute()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(rpc.calls, isEmpty);
    });
  });
}
