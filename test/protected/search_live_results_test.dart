// PROTECTED — CMD #2010. Search is ONE surface: the grid answers the
// keystroke, and nothing about the keystroke is kept.
//
// What this file holds down:
//
//   1. **THE GRID IS THE ANSWER.** From the second character the debounce
//      fires the host's own submit — the same path Enter takes — so the rows
//      under the box are the answer to what is in the box. There is no
//      suggestion list to tap through and no Enter to press. One character
//      asks nothing at all.
//
//   2. **ONE QUERY PER WORD, NOT ONE PER LETTER.** Four keystrokes inside the
//      debounce window are ONE `search_page()` call, and it carries the LAST
//      thing typed.
//
//   3. **NOTHING IS RECORDED.** No keystroke, no submit and no clear ever
//      calls a history or a suggestion RPC. `search_suggest`,
//      `suggest_medicines` and `search_recent_clear` do not exist any more;
//      this test fails the moment any call goes out under those names.
//
//   4. **THE IDLE RAIL IS THE BACKEND'S.** Focused with nothing typed, the
//      surface draws `search_page().rail` — its title verbatim (a title this
//      file deliberately makes nonsense, so a Dart-side "Your last ordered"
//      would fail), its items in PAYLOAD ORDER, and NOTHING at all when the
//      backend says `has:false`. Which rail it is — the customer's own last
//      ordered or the zone's top sellers — is `kind`, decided server-side and
//      never inferred here from whether a cart, an order or a zone exists.
//
//   5. **TYPING CLOSES THE RAIL, CLEARING RE-OPENS IT.** The rail belongs to
//      the empty box, so it is gone the moment a query is on screen and back
//      the moment the box is emptied — with no second RPC to fetch it again.
//
// No network, no Supabase: fabricated payloads only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/data/medicine_repository.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/search_page.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';
import 'package:pharma_b2b/widgets/search_surface.dart';

/// One `search_page().items[]` / `rail.items[]` row — the `_sf_cards()` shape
/// both the grid and the rail are built from.
Map<String, dynamic> _card(int id, String name) => {
      'id': id,
      'name': name,
      'company': 'MANKIND PHARMA LTD',
      'pack_label': 'Strip of 10 tablets',
      'form_chip': 'Strip',
      'pack_qty_label': '10.0 Tablets in 1 strip',
      'pack_type_label': 'Strip',
      'image': '',
      'category': 'RESPIRATORY',
      'has_offer': false,
      'offer_chip': '',
      'rx': {'has': false, 'is_rx': false, 'label': ''},
      'availability': {
        'is_available': true,
        'can_add': true,
        'cta_label': 'Add to cart',
        'cta_short': 'ADD',
      },
      'pricing': {
        'mrp': 174.38,
        'has_price': true,
        'mrp_display': '₹174.38',
        'price_display': '₹152.40',
        'card_price': {
          'has_mrp': true,
          'mrp_label': 'MRP',
          'mrp_display': '₹174.38',
          'price_display': '₹152.40',
          'price_locked': false,
        },
      },
      'mrp_label': '₹174.38',
      'buyable': true,
    };

/// A whole `search_page()` answer. The rail's title is deliberately not a
/// phrase any screen would invent.
Map<String, dynamic> _payload({
  Map<String, dynamic>? rail,
  String q = '',
}) =>
    {
      'ok': true,
      'query': q,
      'has_query': q.isNotEmpty,
      'placeholder': 'Search medicines, salts, companies',
      'header_label': q.isEmpty ? '' : '2 products for “$q”',
      'total': q.isEmpty ? 0 : 2,
      'filters': {'groups': const []},
      'filters_active': false,
      'empty': {'label': 'No product matches.', 'hint': '', 'buttons': const []},
      'empty_label': 'No product matches.',
      'rail': rail ?? {'has': false, 'kind': '', 'title': '', 'items': const []},
      'paging': {
        'page': 0,
        'page_size': 30,
        'returned': 0,
        'has_more': false,
        'next_page': 1,
        'more_label': 'Load more',
        'end_label': 'That is the whole list.',
      },
      'items': const [],
    };

Map<String, dynamic> _rail({
  String kind = 'last_ordered',
  String title = 'ZZ-RAIL-TITLE-FROM-BACKEND',
  bool has = true,
  List<Map<String, dynamic>>? items,
}) =>
    {
      'has': has,
      'kind': kind,
      'title': title,
      'items': items ??
          [_card(701, 'Zinc Tablet'), _card(702, 'Amoxy Cap'), _card(703, 'Bcomplex')],
    };

// ── harness ──────────────────────────────────────────────────────────────────

class _Rpc {
  _Rpc(this.answer);

  final Map<String, dynamic> Function(String fn, Map<String, dynamic> args) answer;
  final List<(String, Map<String, dynamic>)> calls = [];

  Future<dynamic> call(String fn, {Map<String, dynamic>? params}) async {
    final args = params ?? const <String, dynamic>{};
    calls.add((fn, args));
    return answer(fn, args);
  }

  List<Map<String, dynamic>> argsFor(String fn) =>
      calls.where((c) => c.$1 == fn).map((c) => c.$2).toList();
}

/// One [SearchChrome], driven exactly as a screen drives it: the host owns the
/// query and hands `hasQuery` back, which is what the real screens do.
class _Host extends StatefulWidget {
  const _Host({required this.repo, required this.submits});

  final MedicineRepository repo;
  final List<String> submits;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          SearchChrome(
            surface: 'test',
            controller: _ctrl,
            focusNode: _focus,
            repo: widget.repo,
            hasQuery: _query.isNotEmpty,
            payload: null,
            onSubmit: (q) {
              widget.submits.add(q);
              setState(() => _query = q.trim());
            },
            onFilterPick: (_, _) {},
            onClear: () => setState(() => _query = ''),
          ),
        ],
      );
}

Future<(_Rpc, List<String>)> _pump(
  WidgetTester tester, {
  Map<String, dynamic>? rail,
}) async {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final rpc = _Rpc((fn, args) {
    if (fn == 'search_page') {
      return _payload(rail: rail, q: (args['p_q'] ?? '').toString());
    }
    return {'ok': false};
  });
  final submits = <String>[];
  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: _Host(
            repo: MedicineRepository(null, rpc.call),
            submits: submits,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (rpc, submits);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('1 — the grid answers the keystroke', () {
    testWidgets('one character asks nothing', (t) async {
      final (_, submits) = await _pump(t);
      await _type(t, 'd');
      await t.pump(const Duration(milliseconds: 400));
      expect(submits, isEmpty);
    });

    testWidgets('the second character searches, after the debounce and not before',
        (t) async {
      final (_, submits) = await _pump(t);
      await _type(t, 'do');

      // Before the window closes nothing has been asked.
      await t.pump(const Duration(milliseconds: 150));
      expect(submits, isEmpty, reason: 'the debounce had not elapsed');

      await t.pump(const Duration(milliseconds: 150));
      expect(submits, ['do']);
    });

    testWidgets('no Enter is needed — and Enter changes nothing', (t) async {
      final (_, submits) = await _pump(t);
      await _type(t, 'dolo');
      await t.pump(const Duration(milliseconds: 300));
      expect(submits, ['dolo']);

      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pump();
      expect(submits, ['dolo', 'dolo'],
          reason: 'submit is the same path the debounce already took');
    });
  });

  group('2 — one query per word', () {
    testWidgets('four keystrokes inside the window are ONE search, for the last one',
        (t) async {
      final (rpc, submits) = await _pump(t);
      for (final s in ['do', 'dol', 'dolo', 'dolo6']) {
        await _type(t, s);
        await t.pump(const Duration(milliseconds: 60));
      }
      await t.pump(const Duration(milliseconds: 300));

      expect(submits, ['dolo6']);
      // The chrome load is the only other search_page() call in this widget.
      expect(rpc.argsFor('search_page').length, 1,
          reason: 'the host, not the header, fetches the result page');
    });
  });

  group('3 — nothing is recorded, nothing is suggested', () {
    testWidgets('no keystroke, submit or clear calls a suggest or history RPC',
        (t) async {
      final (rpc, _) = await _pump(t, rail: _rail());
      await _type(t, 'dol');
      await t.pump(const Duration(milliseconds: 300));
      await _type(t, '');
      await t.pump(const Duration(milliseconds: 300));

      final names = rpc.calls.map((c) => c.$1).toSet();
      expect(names.contains('search_suggest'), isFalse);
      expect(names.contains('suggest_medicines'), isFalse);
      expect(names.contains('search_recent_clear'), isFalse);
      expect(names, {'search_page'});
    });

    test('the payload has no history and no suggestion switch to read', () {
      final p = SearchPagePayload.fromMap(_payload(rail: _rail()));
      expect(p.rail.has, isTrue);
      // The model carries a rail and nothing else about what was typed before.
      expect(p.rail.kind, 'last_ordered');
    });
  });

  group('4 — the idle rail is the backend\'s', () {
    testWidgets('focused and empty: the backend\'s title, its items, its order',
        (t) async {
      final (_, _) = await _pump(t, rail: _rail());
      await t.tap(find.byType(TextField));
      await t.pumpAndSettle();

      expect(find.text('ZZ-RAIL-TITLE-FROM-BACKEND'), findsOneWidget);

      // The rail holds exactly what the payload sent, in its order. The row
      // scrolls, so only the cards that fit a 360px phone are BUILT — the
      // order is asserted on both: the payload the widget was handed, and the
      // cards it actually painted.
      final rail = t.widget<SearchIdleRail>(find.byType(SearchIdleRail));
      expect(rail.rail.items.map((e) => e['name']).toList(),
          ['Zinc Tablet', 'Amoxy Cap', 'Bcomplex'],
          reason: 'payload order, never a client sort');
      final painted = t
          .widgetList<CompactProductCard>(find.byType(CompactProductCard))
          .map((c) => c.product.name)
          .toList();
      expect(painted.isNotEmpty, isTrue);
      expect(painted, ['Zinc Tablet', 'Amoxy Cap'].sublist(0, painted.length));
    });

    testWidgets('top_sellers renders identically — the kind is not a layout switch',
        (t) async {
      await _pump(t,
          rail: _rail(kind: 'top_sellers', title: 'ZZ-TOP-SELLERS-TITLE'));
      await t.tap(find.byType(TextField));
      await t.pumpAndSettle();

      expect(find.text('ZZ-TOP-SELLERS-TITLE'), findsOneWidget);
      expect(find.byType(CompactProductCard), findsWidgets);
      expect(
          t.widget<SearchIdleRail>(find.byType(SearchIdleRail)).rail.kind,
          'top_sellers');
    });

    testWidgets('has:false draws nothing at all', (t) async {
      await _pump(t, rail: _rail(has: false));
      await t.tap(find.byType(TextField));
      await t.pumpAndSettle();

      expect(find.byType(SearchIdleRail), findsOneWidget);
      expect(find.byType(CompactProductCard), findsNothing);
      expect(find.byKey(const Key('c2010_rail_title')), findsNothing);
    });

    testWidgets('unfocused: no rail, even with a payload that has one', (t) async {
      await _pump(t, rail: _rail());
      // Never focused.
      expect(find.byKey(const Key('c2010_rail_title')), findsNothing);
    });
  });

  group('5 — typing closes the rail, clearing re-opens it', () {
    testWidgets('the rail is gone while a query is on screen and back when it is not',
        (t) async {
      final (rpc, _) = await _pump(t, rail: _rail());
      await t.tap(find.byType(TextField));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('c2010_rail_title')), findsOneWidget);

      await _type(t, 'dolo');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('c2010_rail_title')), findsNothing);

      await _type(t, '');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('c2010_rail_title')), findsOneWidget);
      expect(rpc.argsFor('search_page').length, 1,
          reason: 'the rail came back from the chrome already loaded');
    });
  });
}
