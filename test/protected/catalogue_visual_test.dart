// PROTECTED — CHANGE #799, the Catalogue tab's visual system.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour.
//
// #747 pinned the catalogue's DATA contract (nothing computed, payload order,
// the zone flag, the opaque cursor). This file pins the SHAPE Om asked for in
// #799 — and every one of the seven things below is a place where a screen is
// tempted to start deciding for itself:
//
//   1. THE THREE DOORS ARE THE PAYLOAD'S. Their labels, their counts and their
//      glyph letters arrive rendered; the fixture's counts deliberately do not
//      match any number the app could derive. A door the backend did not send
//      is not drawn, and a fourth door would be.
//
//   2. THE RECENTLY-VIEWED STRIP IS `has`, NOT `items.isNotEmpty`. The two are
//      different questions — an anonymous visitor gets `has:false` — and the
//      strip's title is the backend's word, never "Recently viewed" written in
//      Dart.
//
//   3. THE FILTER ROW IS A SENTENCE THE BACKEND WROTE. The lead word, the
//      chips, their order and which are selected all come from
//      `catalogue_sentence()`. The fixture puts a SELECTED chip second so a
//      screen that sorts selected-first fails, and the row prints the
//      backend's `all_label` only while nothing is selected.
//
//   4. A CHIP TAP IS THE PAYLOAD'S GROUP AND KEY. Tapping "Rx only" must send
//      `rx=Rx` to `catalogue_list`, not a word this file matched on.
//
//   5. THE A–Z RAIL IS A FIXED TRACK. Every letter the backend sent is drawn,
//      including the disabled ones, and picking one re-asks the backend with
//      `p_letter`. A rail that only drew letters with rows behind them would
//      change length as the list filtered.
//
//   6. REVERSED BY CMD #1903 — A LIST IS ROWS, AND IT ASKS FOR NOTHING ELSE.
//      The pack family is no longer a chip on a card: `catalogue_variants` is
//      not called from a list at all, and the family lives on the product page
//      as the "Other packs" strip under the price.
//
//   8. THE ERROR STATE IS THE BACKEND'S SENTENCE. A failed load prints
//      `catalogue.load_error` and a Retry labelled `catalogue.retry` — never
//      the exception. A live anon visit on 4 Sep painted
//      "PostgrestException(message: canceling statement due to statement
//      timeout, code: 57014 …)" across the middle of the screen, which is what
//      this pins shut.
//
//   7. THE EMPTY STATE TEACHES AND ACTS. Its sentence, its hint and both of
//      its buttons are the payload's `empty` block; `has:false` on an action
//      draws no button rather than a dead one.
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
import 'package:pharma_b2b/widgets/catalogue_alphabet_rail.dart';
import 'package:pharma_b2b/widgets/product_row_card.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _zone({bool has = true, bool on = true}) => {
      'has': has,
      'on': on,
      'label': 'Available in my zone',
      'zone_label': 'Raipur Zone',
      'note': 'Showing what suppliers in your zone can send.',
    };

/// The sentence. Note the ORDER: a selected chip sits SECOND on purpose, so a
/// screen that re-sorts selected chips to the front fails here.
Map<String, dynamic> _sentence({bool selection = true}) => {
      'lead': 'Showing',
      'separator': '·',
      'all_label': 'everything',
      'clear_label': 'Clear all',
      'has_selection': selection,
      'parts': [
        {'group': 'pack_type', 'key': 'Strip', 'label': 'Strip', 'selected': false, 'mode': 'multi'},
        if (selection)
          {'group': 'rx', 'key': 'Rx', 'label': 'Rx only', 'selected': true, 'mode': 'single'},
        {'group': 'zone', 'key': 'zone', 'label': 'In my zone', 'selected': true, 'mode': 'single'},
      ],
    };

Map<String, dynamic> _home({
  bool zoneHas = true,
  bool recentHas = true,
  List<Map<String, dynamic>>? doors,
}) => {
      'ok': true,
      'title': 'Catalogue',
      'subtitle': 'Browse the whole product list by class, company or salt.',
      'search_hint': 'Search a salt or a company',
      'search': {
        'placeholder': 'Search a medicine, salt or company',
        'hint': 'Search a salt or a company',
        'clear_label': 'Clear',
      },
      'zone': _zone(has: zoneHas),
      'doors_title': 'Browse by',
      'doors': doors ??
          [
            {'key': 'companies', 'kind': 'companies', 'tab': 'companies',
             'label': 'Company', 'icon_key': 'store', 'icon_letter': 'C',
             'count_label': '18,563 companies'},
            {'key': 'salts', 'kind': 'salts', 'tab': 'salts',
             'label': 'Salt', 'icon_key': 'science', 'icon_letter': 'S',
             'count_label': '1,06,571 salts'},
            {'key': 'browse', 'kind': 'tree', 'tab': 'browse',
             'label': 'Category', 'icon_key': 'book', 'icon_letter': 'K',
             'count_label': '3,35,273 products'},
          ],
      'recent_viewed': {
        'has': recentHas,
        'title': 'You looked at these',
        'items': recentHas ? [_card('9001', 'Dolo 650 Tablet')] : <Map<String, dynamic>>[],
      },
      'sentence': _sentence(),
      'tabs': [
        {'key': 'browse', 'label': 'Browse', 'kind': 'tree', 'count_label': '3,35,273 products'},
        {'key': 'cold_chain', 'label': 'Cold chain', 'kind': 'list',
         'list_kind': 'tab', 'list_key': 'cold_chain', 'count_label': '4,413 products'},
      ],
      'filters': _filterDefs(),
    };

Map<String, dynamic> _filterDefs() => {
      'title': 'Filters',
      'clear_label': 'Clear all',
      'apply_label': 'Show results',
      'groups': const <Map<String, dynamic>>[],
      'sort': {'label': 'Sort', 'options': const <Map<String, dynamic>>[]},
    };

Map<String, dynamic> _treeRoot() => {
      'ok': true,
      'title': 'Therapeutic class',
      'path': <String>[],
      'zone': _zone(),
      'home_label': 'All classes',
      'child_opens': 'level',
      'products_label': 'View products',
      'has_products': false,
      'empty_label': 'The catalogue has no classes in this view.',
      'count_label': '3,35,273 products',
      'rows': [
        {'key': 'ANTI INFECTIVES', 'label': 'ANTI INFECTIVES', 'count_label': '75,562 products'},
      ],
    };

/// The company list, with a rail whose track deliberately contains a letter
/// that has nothing behind it.
Map<String, dynamic> _companies() => {
      'ok': true,
      'title': 'Companies',
      'zone': _zone(),
      'search_hint': 'Search a company',
      'all_label': 'All',
      'letters': [
        {'key': 'A', 'label': 'A', 'n': 2243},
      ],
      'rail': {
        'label': 'Jump to a letter',
        'all_label': 'All',
        'letters': [
          {'key': 'A', 'label': 'A', 'n': 2243, 'enabled': true},
          {'key': 'Q', 'label': 'Q', 'n': 0, 'enabled': false},
          {'key': 'Z', 'label': 'Z', 'n': 41, 'enabled': true},
          {'key': '#', 'label': '#', 'n': 7, 'enabled': true},
        ],
      },
      'count_label': '18,563 companies',
      'empty_label': 'No company matches this view.',
      'has_more': false,
      'next_offset': 1,
      'rows': [
        {'key': 'abbott', 'label': 'ABBOTT', 'letter': 'A', 'count_label': '1,204 products'},
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
      },
      // The trade rate, already rendered. The card must print THIS and never
      // an MRP row beside it.
      'pricing': {
        'has_price': true, 'price_display': '₹99.00',
        'has_ptr': true, 'ptr_display': '₹82.50', 'ptr_caption': 'PTR',
        'has_struck_mrp': true, 'mrp_display': '₹117.19',
      },
      'mrp_label': '₹117.19',
      'has_offer': false,
      'offer_chip': '',
    };

Map<String, dynamic> _list({
  List<Map<String, dynamic>>? items,
  Map<String, dynamic>? empty,
}) => {
      'ok': true,
      'title': 'Cold chain',
      'subtitle': '',
      'count_label': '2 shown',
      'empty_label': 'Nothing here in this view.',
      'more_label': 'Load more',
      'end_label': 'That is the whole list.',
      'sort': 'name',
      'filters_active': false,
      'filters_active_label': '',
      'zone': _zone(),
      'filters': _filterDefs(),
      'sentence': _sentence(),
      'empty': empty ??
          {
            'label': 'No Cold chain in Raipur Zone yet.',
            'hint': 'Turn off "Available in my zone" to see the whole catalogue.',
            'action': {'has': true, 'kind': 'request', 'label': 'Request this product'},
            'clear': {'has': false, 'kind': 'clear_filters', 'label': 'Clear all'},
          },
      'items': items ?? [_card('101', 'Azithral 250mg DT Tablet')],
      'has_more': false,
      'next_cursor': null,
    };

/// `catalogue_variants()` — a two-pack family and a one-pack family. The
/// one-pack family arrives `has:false` and must draw nothing.
Map<String, dynamic> _variants() => {
      'ok': true,
      'title': 'Other packs',
      'map': {
        '101': {
          'has': true,
          'items': [
            {'product_id': '101', 'label': '250mg DT Tablet', 'selected': true},
            {'product_id': '102', 'label': 'JR Oral Suspension', 'selected': false},
          ],
        },
        '9001': {'has': false, 'items': <Map<String, dynamic>>[]},
      },
    };

// ── harness ──────────────────────────────────────────────────────────────────

class _Rpc {
  final List<(String, Map<String, dynamic>)> calls = [];
  final Map<String, List<Map<String, dynamic>>> queued;
  /// Functions that FAIL rather than answer — the real shape of a statement
  /// timeout, which arrives as a thrown PostgrestException, not `ok:false`.
  final Set<String> throwFor;
  _Rpc(this.queued, {this.throwFor = const {}});

  Future<Map<String, dynamic>> call(String fn, Map<String, dynamic> args) async {
    calls.add((fn, args));
    if (throwFor.contains(fn)) {
      throw Exception('PostgrestException(message: canceling statement due to '
          'statement timeout, code: 57014, details: , hint: null)');
    }
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
  CatalogueRoute? route,
  Set<String> throwFor = const {},
  Size size = const Size(430, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final rpc = _Rpc(queued, throwFor: throwFor);
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
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(const {
      'catalogue.load_error':
          "The catalogue didn't load. Check your connection and try again.",
      'catalogue.retry': 'Retry',
    });
  });

  group('the three doors are the payload\'s', () {
    testWidgets('label, count and glyph letter all print verbatim',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot()],
      });
      expect(find.text('Browse by'), findsOneWidget);
      expect(find.text('Company'), findsOneWidget);
      expect(find.text('Salt'), findsOneWidget);
      expect(find.text('Category'), findsOneWidget);
      // The counts are sentences, not numbers this screen could derive.
      expect(find.text('18,563 companies'), findsOneWidget);
      expect(find.text('1,06,571 salts'), findsOneWidget);
      expect(find.text('3,35,273 products'), findsWidgets);
    });

    testWidgets('a payload with no doors draws none, and does not throw',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home(doors: const [])],
        'catalogue_tree': [_treeRoot()],
      });
      expect(find.text('Browse by'), findsNothing);
      expect(find.text('Company'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a door opens THAT tab, by the payload\'s own key',
        (tester) async {
      final rpc = await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot()],
        'catalogue_companies': [_companies()],
      });
      await tester.tap(find.text('Company'));
      await tester.pumpAndSettle();
      expect(rpc.count('catalogue_companies'), 1,
          reason: 'the door carried tab:companies — the screen must not guess');
    });
  });

  group('the recently-viewed strip is a flag, not a length', () {
    testWidgets('has:true draws it with the BACKEND\'s title', (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot()],
      });
      expect(find.text('You looked at these'), findsOneWidget,
          reason: 'the heading is the payload\'s, never "Recently viewed" in Dart');
      expect(find.text('Dolo 650 Tablet'), findsOneWidget);
    });

    testWidgets('has:false draws nothing at all', (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home(recentHas: false)],
        'catalogue_tree': [_treeRoot()],
      });
      expect(find.text('You looked at these'), findsNothing);
    });
  });

  group('the filter row is a sentence the backend wrote', () {
    testWidgets('chips render in payload order, selected one NOT hoisted',
        (tester) async {
      await _pump(tester, size: const Size(1400, 900), queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot()],
      });
      final chips = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where((s) => const {'Strip', 'Rx only', 'In my zone'}.contains(s))
          .toList();
      // Payload order. "Rx only" is the SELECTED chip and sits second — a
      // screen that pulls selected chips to the front fails here.
      expect(chips, ['Strip', 'Rx only', 'In my zone']);
    });

    testWidgets('with nothing selected the row prints the backend\'s all_label',
        (tester) async {
      final home = _home();
      home['sentence'] = _sentence(selection: false);
      await _pump(tester, queued: {
        'catalogue_home': [home],
        'catalogue_tree': [_treeRoot()],
      });
      expect(find.text('Showing everything'), findsOneWidget);
      expect(find.text('Clear all'), findsNothing,
          reason: 'nothing is selected, so there is nothing to clear');
    });

    testWidgets('a chip tap sends the payload\'s own group and key',
        (tester) async {
      final rpc = await _pump(tester, size: const Size(1400, 900), queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [_treeRoot()],
        'catalogue_list': [_list()],
        'catalogue_variants': [_variants()],
      });
      await tester.tap(find.text('Strip'));
      await tester.pumpAndSettle();
      expect(rpc.lastArgs('catalogue_list')['p_filters'],
          containsPair('pack_type', ['Strip']),
          reason: 'the chip carried group:pack_type key:Strip — nothing was matched on the word');
    });
  });

  group('the A–Z rail is a fixed track', () {
    testWidgets('every letter is drawn, disabled ones included', (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_companies': [_companies()],
      }, route: const CatalogueRoute(tab: 'companies'));
      expect(find.byType(CatalogueAlphabetRail), findsOneWidget);
      // 'Q' has nothing behind it and is STILL on the track: a rail that
      // changed length as the list filtered could not be learned or dragged.
      expect(find.text('Q'), findsOneWidget);
      expect(find.text('#'), findsOneWidget);
    });

    testWidgets('picking a letter re-asks the backend with p_letter',
        (tester) async {
      final rpc = await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_companies': [_companies()],
      }, route: const CatalogueRoute(tab: 'companies'));
      await tester.tap(find.descendant(
          of: find.byType(CatalogueAlphabetRail), matching: find.text('Z')));
      await tester.pumpAndSettle();
      expect(rpc.lastArgs('catalogue_companies')['p_letter'], 'Z');
    });
  });

  group('CMD #1903 — a list is rows, and it never asks for a family', () {
    testWidgets('the list paints from catalogue_list ALONE', (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list()],
      }, route: const CatalogueRoute(listKind: 'tab', listKey: 'cold_chain'));
      expect(find.byType(ProductRowCard), findsOneWidget);
      expect(find.text('Azithral 250mg DT Tablet'), findsOneWidget);
    });

    testWidgets('catalogue_variants is never called, and no chip is drawn',
        (tester) async {
      // REVERSED BY CMD #1903. #799 asked for the pack family as a SECOND
      // call and drew it as chips on every card. The family now lives on the
      // product page ("Other packs", under the price), so a list must make
      // exactly one call and show exactly one row per product. The variant
      // payload is still queued here on purpose: if anything ever asks for it
      // again, the count assertion below catches it.
      final rpc = await _pump(tester, size: const Size(1400, 900), queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list()],
        'catalogue_variants': [_variants()],
      }, route: const CatalogueRoute(listKind: 'tab', listKey: 'cold_chain'));
      expect(rpc.count('catalogue_variants'), 0,
          reason: 'a list asks for products and nothing else');
      expect(find.text('JR Oral Suspension'), findsNothing,
          reason: 'a variant label must not appear on a list surface');
    });
  });

  group('the row is the five things Om asked for', () {
    testWidgets('trade rate AND the struck MRP above it', (tester) async {
      // REVERSED BY CMD #1895. #799 cut the MRP row from this card because a
      // struck ceiling beside a rate reads as a consumer discount. Om's 08-Sep
      // sketch answers that differently: the ceiling is shown to EVERYONE,
      // struck, and what sits under it is the trade amount for an approved
      // pharmacy and the word "PTR" for anyone else. Both lines come from the
      // SAME `pricing.card_price` the storefront card reads, which is what
      // makes the two tabs one card.
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list()],
      }, route: const CatalogueRoute(listKind: 'tab', listKey: 'cold_chain'));
      expect(find.text('₹82.50'), findsOneWidget,
          reason: 'the PTR is what a pharmacy buys on and it prints verbatim');
      expect(find.text('₹117.19'), findsOneWidget,
          reason: '#1895 — the printed ceiling is back, struck, on every card');
      expect(find.text('ABBOTT'), findsOneWidget);
      // CMD #1903 — the row prints BOTH decided pack strings on one line,
      // type then quantity, joined by the one separator this app uses. Each
      // is still its own backend key; nothing here falls back to pack_size.
      expect(find.text('Strip · 10.0 tablets in 1 strip'), findsOneWidget);
      expect(find.text('ADD'), findsOneWidget,
          reason: 'the add word is the payload\'s cta_short');
    });
  });

  group('the empty state teaches and acts', () {
    testWidgets('sentence, hint and the offered action are all the payload\'s',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_list(items: const [])],
      }, route: const CatalogueRoute(listKind: 'tab', listKey: 'cold_chain'));
      expect(find.text('No Cold chain in Raipur Zone yet.'), findsOneWidget);
      expect(
          find.text('Turn off "Available in my zone" to see the whole catalogue.'),
          findsOneWidget);
      expect(find.text('Request this product'), findsOneWidget);
      expect(find.text('Clear all'), findsNothing,
          reason: 'clear.has is false — a dead button teaches worse than none');
    });

    testWidgets('an action with has:false draws no button', (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [
          _list(items: const [], empty: {
            'label': 'Nothing matches these filters. Clear one and try again.',
            'hint': '',
            'action': {'has': false, 'kind': 'request', 'label': 'Request this product'},
            'clear': {'has': true, 'kind': 'clear_filters', 'label': 'Clear all'},
          }),
        ],
      }, route: const CatalogueRoute(listKind: 'tab', listKey: 'cold_chain'));
      expect(find.text('Request this product'), findsNothing);
      expect(find.text('Clear all'), findsOneWidget);
    });
  });

  group('the error state is the backend sentence, never the exception', () {
    testWidgets('a failed catalogue_home prints the copy and a labelled Retry',
        (tester) async {
      final rpc = await _pump(tester, queued: {
        'catalogue_tree': [_treeRoot()],
      }, throwFor: {'catalogue_home'});
      expect(
          find.text(
              "The catalogue didn't load. Check your connection and try again."),
          findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // The one thing that must never reach a customer's screen.
      expect(find.textContaining('PostgrestException'), findsNothing);
      expect(find.textContaining('statement timeout'), findsNothing);
      expect(find.textContaining('Exception'), findsNothing);

      // Retry re-asks the backend rather than clearing the message locally.
      final before = rpc.count('catalogue_home');
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(rpc.count('catalogue_home'), greaterThan(before));
    });

    testWidgets('the sentence is the copy map, not a Dart fallback',
        (tester) async {
      UiCopy.debugSet(const {
        'catalogue.load_error': 'Backend wrote this line.',
        'catalogue.retry': 'Try again',
      });
      addTearDown(() => UiCopy.debugSet(const {
            'catalogue.load_error':
                "The catalogue didn't load. Check your connection and try again.",
            'catalogue.retry': 'Retry',
          }));
      await _pump(tester, queued: {'catalogue_tree': [_treeRoot()]},
          throwFor: {'catalogue_home'});
      expect(find.text('Backend wrote this line.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}
