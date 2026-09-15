// PROTECTED — CMD #1909, the catalogue's two availability groups.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour.
//
// #747's "Available in my zone" switch FILTERED. A customer in Raipur opening
// a therapeutic class saw a short list and had no way of knowing the catalogue
// held ten times as much — the empty state's own hint ("Turn off 'Available in
// my zone'…") was the app admitting it was hiding things. Om's call: never
// hide. Show the whole scope, ordered, with the two groups named and counted
// by the backend.
//
// Six things, and every one of them is a place a list screen starts deciding:
//
//   1. THE DIVIDER IS A ROW'S OWN STRING. It arrives on `divider_label` of the
//      row that OPENS a group. The screen draws it where it finds it and
//      nowhere else — it never compares two rows, never counts a group and
//      never assembles "Available in your zone" + " (" + n.
//
//   2. PAYLOAD ORDER, ALWAYS. The fixture is deliberately NOT alphabetical
//      inside its groups. A screen that sorts, or that pulls the available
//      group to the front by itself, fails here.
//
//   3. PAGE TWO DOES NOT REPEAT A HEADER, OR LOSE ONE. The backend decides,
//      from the cursor, whether a page continues a group or opens one. Page
//      two of the SAME group arrives with every divider empty; the page that
//      crosses into the second group carries exactly one.
//
//   4. THE CURSOR IS OPAQUE. It is handed back verbatim. The app never reads
//      inside it and never builds one, which is the only reason the backend
//      could add `g` to it without a deploy of this screen.
//
//   5. AN UNAVAILABLE ROW IS STILL A ROW. It shows its price, it opens the
//      PDP, and its ADD is dead with the BACKEND's reason on it. It is not
//      greyed out by a rule written here, and it is not dropped.
//
//   6. UNGROUPED IS A FLAG, NOT AN ABSENCE. An anonymous visitor gets
//      `grouped:false` and empty divider labels, and draws ONE flat list —
//      which is what it always was.
//
// Dart VM only: no network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/catalogue.dart';
import 'package:pharma_b2b/screens/catalogue_screen.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _zoneSwitchGone() => {
      'has': false,
      'on': false,
      'zone_id': null,
      'label': 'Available in my zone',
      'note': 'Showing the whole catalogue.',
    };

Map<String, dynamic> _filterDefs() => {
      'title': 'Filters',
      'clear_label': 'Clear all',
      'apply_label': 'Show results',
      'groups': const <Map<String, dynamic>>[],
      'sort': {'label': 'Sort', 'options': const <Map<String, dynamic>>[]},
    };

Map<String, dynamic> _sentence() => {
      'lead': '',
      'separator': '',
      'all_label': '',
      'clear_label': '',
      'has_selection': false,
      'parts': const <Map<String, dynamic>>[],
    };

Map<String, dynamic> _home() => {
      'ok': true,
      'title': 'Catalogue',
      'search_placeholder': 'Search a medicine',
      'search_clear_label': 'Clear',
      'doors_title': 'Browse by',
      'doors': const <Map<String, dynamic>>[],
      'recent_viewed': {'has': false, 'title': '', 'items': <Map<String, dynamic>>[]},
      'sentence': _sentence(),
      'zone': _zoneSwitchGone(),
      'tabs': const <Map<String, dynamic>>[],
      'filters': _filterDefs(),
    };

/// One card. [canAdd] false carries the backend's OWN reason — this file never
/// writes "Not available in your zone" as an expectation it derived, it writes
/// it as the string the fixture put on the wire.
Map<String, dynamic> _card(
  String id,
  String name, {
  bool canAdd = true,
  String divider = '',
  String group = 'in',
}) =>
    {
      'id': id,
      'name': name,
      'company': 'ABBOTT',
      'pack_label': 'Strip of 10 tablets',
      'form_chip': 'Strip',
      'pack_type_label': 'Strip',
      'pack_qty_label': '10.0 tablets in 1 strip',
      'image': null,
      'buyable': true,
      'group': group,
      'divider_label': divider,
      'rx': {'has': false, 'is_rx': false, 'label': ''},
      'availability': canAdd
          ? {
              'cta_label': 'Add to cart', 'cta_short': 'ADD',
              'can_add': true, 'is_available': true, 'gated': true,
            }
          : {
              'cta_label': 'Not available in your zone',
              'cta_short': 'Not in your zone',
              'can_add': false, 'is_available': false, 'gated': true,
              'blocked_by': 'not_in_zone',
              'note': 'Not available in your zone',
            },
      'pricing': {
        'has_price': true, 'price_display': '₹99.00',
        'has_ptr': false, 'ptr_display': '', 'ptr_caption': '',
        'has_struck_mrp': false, 'mrp_display': '',
      },
      'mrp_label': '₹117.19',
      'has_offer': false,
      'offer_chip': '',
    };

Map<String, dynamic> _list({
  required List<Map<String, dynamic>> items,
  bool grouped = true,
  bool hasMore = false,
  String? cursor,
}) =>
    {
      'ok': true,
      'title': 'CARDIAC',
      'subtitle': '',
      'count_label': '300 products',
      'empty_label': 'Nothing here in this view.',
      'more_label': 'Load more',
      'end_label': 'That is the whole list.',
      'sort': 'name',
      'filters_active': false,
      'filters_active_label': '',
      'zone': _zoneSwitchGone(),
      'grouped': grouped,
      'groups': grouped
          ? [
              {'key': 'in', 'label': 'Available in your zone (5)', 'count': 5},
              {'key': 'out', 'label': 'Not available in your zone (295)', 'count': 295},
            ]
          : const <Map<String, dynamic>>[],
      'filters': _filterDefs(),
      'sentence': _sentence(),
      'empty': {
        'label': 'Nothing here in this view.',
        'hint': '',
        'action': {'has': false, 'kind': 'request', 'label': ''},
        'clear': {'has': false, 'kind': 'clear_filters', 'label': ''},
      },
      'items': items,
      'has_more': hasMore,
      'next_cursor': cursor,
      'limit': 3,
    };

/// Page one: the two available packs, then the first unavailable one. The
/// names are deliberately out of alphabetical order INSIDE each group.
List<Map<String, dynamic>> _page1() => [
      _card('101', 'Telexia-AM Tablet', divider: 'Available in your zone (5)'),
      _card('102', 'Amlovas T Tablet'),
      _card('201', 'Zensartan-AM Tablet',
          canAdd: false, group: 'out', divider: 'Not available in your zone (295)'),
    ];

/// Page two: still inside the second group, so NOT ONE divider comes with it.
List<Map<String, dynamic>> _page2() => [
      _card('202', 'Macsart AM Tablet', canAdd: false, group: 'out'),
      _card('203', 'Telride AM Tablet', canAdd: false, group: 'out'),
    ];

// ── harness ──────────────────────────────────────────────────────────────────

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

  Map<String, dynamic> lastArgs(String fn) => calls.lastWhere((c) => c.$1 == fn).$2;
  int count(String fn) => calls.where((c) => c.$1 == fn).length;
}

Future<_Rpc> _pump(
  WidgetTester tester, {
  required Map<String, List<Map<String, dynamic>>> queued,
  Size size = const Size(430, 1400),
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
            initialRoute: const CatalogueRoute(listKind: 'tree', path: ['CARDIAC']),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return rpc;
}

/// Every Text on screen, in paint order — the only honest way to assert that a
/// divider sits BETWEEN two specific rows rather than merely existing.
List<String> _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data)
    .whereType<String>()
    .toList();

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(const {});
  });

  group('the divider is the backend\'s row, in the backend\'s place', () {
    testWidgets('both group headers print verbatim, each above its own row',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list(items: _page1())],
      });

      final t = _texts(tester);
      expect(t, contains('Available in your zone (5)'));
      expect(t, contains('Not available in your zone (295)'));

      // Order is the whole point: header, its two rows, then the second
      // header, then the row it opens.
      expect(
        [
          t.indexOf('Available in your zone (5)'),
          t.indexOf('Telexia-AM Tablet'),
          t.indexOf('Amlovas T Tablet'),
          t.indexOf('Not available in your zone (295)'),
          t.indexOf('Zensartan-AM Tablet'),
        ],
        orderedEquals([
          t.indexOf('Available in your zone (5)'),
          t.indexOf('Telexia-AM Tablet'),
          t.indexOf('Amlovas T Tablet'),
          t.indexOf('Not available in your zone (295)'),
          t.indexOf('Zensartan-AM Tablet'),
        ]),
      );
      final idx = [
        t.indexOf('Available in your zone (5)'),
        t.indexOf('Telexia-AM Tablet'),
        t.indexOf('Amlovas T Tablet'),
        t.indexOf('Not available in your zone (295)'),
        t.indexOf('Zensartan-AM Tablet'),
      ];
      for (var i = 1; i < idx.length; i++) {
        expect(idx[i], greaterThan(idx[i - 1]),
            reason: 'the list is painted in payload order, dividers included');
      }
    });

    testWidgets('exactly one divider per group — never one per row',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list(items: _page1())],
      });
      final t = _texts(tester);
      expect(t.where((s) => s == 'Available in your zone (5)').length, 1);
      expect(t.where((s) => s == 'Not available in your zone (295)').length, 1);
      expect(find.byType(CompactProductCard), findsNWidgets(3));
    });

    testWidgets('a row the backend gave no divider gets none', (tester) async {
      // Same three cards, every divider_label blank: the screen must not fill
      // one in from `group`, which is exactly the inference this pins shut.
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [
          _list(items: [
            _card('101', 'Telexia-AM Tablet'),
            _card('201', 'Zensartan-AM Tablet', canAdd: false, group: 'out'),
          ])
        ],
      });
      final t = _texts(tester);
      expect(t.where((s) => s.startsWith('Available in your zone')), isEmpty);
      expect(t.where((s) => s.startsWith('Not available in your zone')), isEmpty);
      expect(find.byType(CompactProductCard), findsNWidgets(2));
    });
  });

  group('paging keeps the order and the headers', () {
    testWidgets('page two appends, repeats no header and loses none',
        (tester) async {
      // A short viewport on purpose: the next page is fetched when the SCROLL
      // reaches the end, so a list that fits on screen never asks for one.
      final rpc = await _pump(tester, size: const Size(430, 620), queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [
          _list(items: _page1(), hasMore: true, cursor: '{"g":1,"i":201,"n":"Zensartan-AM Tablet"}'),
          _list(items: _page2()),
        ],
      });

      await tester.drag(find.byType(CustomScrollView).last, const Offset(0, -2000));
      await tester.pumpAndSettle();

      expect(rpc.count('catalogue_list'), 2,
          reason: 'scrolling to the end asks for the next page once');
      expect(rpc.lastArgs('catalogue_list')['p_cursor'],
          '{"g":1,"i":201,"n":"Zensartan-AM Tablet"}',
          reason: 'the cursor is opaque — handed back exactly as it arrived, '
              'which is the only reason the backend could add `g` to it');

      // Scroll back to the top so every built row is asserted on, not only
      // the tail the viewport happens to be showing.
      await tester.drag(find.byType(CustomScrollView).last, const Offset(0, 4000));
      await tester.pumpAndSettle();
      final t = _texts(tester);
      expect(t.where((s) => s == 'Not available in your zone (295)').length, 1,
          reason: 'page two continues the group, so it carries no header and '
              'the screen must not invent a second one');
      expect(t, contains('Available in your zone (5)'));
    });

    testWidgets('no list call ever carries p_zone', (tester) async {
      final rpc = await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list(items: _page1())],
      });
      expect(rpc.lastArgs('catalogue_list').containsKey('p_zone'), isFalse);
      expect(rpc.lastArgs('catalogue_home').containsKey('p_zone'), isFalse);
    });
  });

  group('an unavailable row is still a row', () {
    testWidgets('it shows its price and its ADD is dead with the backend word',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list(items: _page1())],
      });

      // Three cards, three prices — the out-of-zone one is NOT price-less.
      expect(find.text('₹99.00'), findsNWidgets(3));

      final rows = tester.widgetList<CompactProductCard>(find.byType(CompactProductCard)).toList();
      final blocked = rows.firstWhere((r) => r.product.id == '201');
      expect(blocked.product.availability?.canAdd, isFalse);
      expect(blocked.product.availability?.note, 'Not available in your zone',
          reason: 'the reason is the payload\'s. A sentence written in Dart '
              'here could not be changed without a deploy');
      expect(blocked.onTap, isNotNull,
          reason: 'unavailable still opens the product page');
    });
  });

  group('ungrouped is a flag, not an absence', () {
    testWidgets('grouped:false draws one flat list and no divider at all',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [
          _list(grouped: false, items: [
            _card('101', 'Telexia-AM Tablet', group: ''),
            _card('102', 'Amlovas T Tablet', group: ''),
          ])
        ],
      });
      final t = _texts(tester);
      expect(t.where((s) => s.contains('in your zone')), isEmpty);
      expect(find.byType(CompactProductCard), findsNWidgets(2));
    });
  });

  group('the model reads the payload and nothing else', () {
    test('CatList carries the groups and the per-row divider verbatim', () {
      final l = CatList.fromMap(_list(items: _page1()));
      expect(l.grouped, isTrue);
      expect(l.groups.map((g) => g.key), ['in', 'out']);
      expect(l.groups.first.label, 'Available in your zone (5)');
      expect(l.groups.first.count, 5);
      expect(l.rows.map((r) => r.group), ['in', 'in', 'out']);
      expect(l.rows.map((r) => r.dividerLabel), [
        'Available in your zone (5)',
        '',
        'Not available in your zone (295)',
      ]);
      expect(l.rows.map((r) => r.product.name),
          ['Telexia-AM Tablet', 'Amlovas T Tablet', 'Zensartan-AM Tablet'],
          reason: 'payload order, never a sort');
    });

    test('an ungrouped payload is empty groups, not a missing key', () {
      final l = CatList.fromMap(_list(grouped: false, items: _page2()));
      expect(l.grouped, isFalse);
      expect(l.groups, isEmpty);
      expect(l.rows.every((r) => r.dividerLabel.isEmpty), isTrue);
    });
  });
}
