// PROTECTED — CMD #1906. ONE search, for Home and for the Catalogue.
//
// Home used to call storefront_search_page (category chips, no suggestions,
// offset paging) and the Catalogue called catalogue_list(kind:'search')
// (a suggestion popup, pack/Rx/flag filters, a sort). Same query, two
// behaviours and two looks. This file holds down the single surface that
// replaced them — the model, the URL spelling and the four widgets both
// screens draw.
//
// What this holds down:
//
//   1. **ONE URL SPELLING.** Query, filters and page are one value
//      (SearchQueryState) with one set of parameter names. What Home writes
//      into the URL, the Catalogue reads back unchanged and vice versa — that
//      round trip is what makes moving between the two screens keep the
//      search. Defaults are ABSENT from the URL and from the filter payload,
//      never spelled out: 'All', 'relevance' and page 0 are the backend's own
//      defaults, and writing them would freeze today's defaults into links.
//
//   2. **THE FILTER SET IS THE BACKEND'S, IN THE BACKEND'S ORDER.** The chip
//      row draws the groups in payload order and never sorts them. The group
//      the payload marked `chip_row` is expanded inline (the category row);
//      every other group is ONE chip carrying its own label. Which group that
//      is, is a backend flag — not a key this file recognises.
//
//   3. **A GROUP'S MODE DECIDES WHAT A TAP MEANS.** Multi toggles, single
//      replaces. Tapping the selected Rx option clears it; tapping a category
//      or a sort option replaces it, because those two always carry a value.
//
//   4. **EVERY STRING IS PRINTED, NEVER BUILT.** header_label, the empty
//      sentence, its hint, its button words, more_label and end_label are
//      rendered verbatim. Nothing here pluralises, counts, or writes "N
//      results" — the header line is one backend field.
//
//   5. **THE EMPTY STATE IS THE SAME OBJECT ON BOTH SCREENS**, and its
//      buttons are drawn in the order the payload sent them, with the tone it
//      sent. A tap hands back the button's own `kind`, so what the button
//      DOES stays a backend decision too.
//
//   6. **THE IDLE RAIL IS `has`.** CMD #2010 deleted the recent strip with
//      the history behind it; the empty state is now the backend's own rail
//      ("Your last ordered", or that customer's zone top sellers). Which rail
//      it is, and what it is CALLED, are backend decisions: has:false draws
//      nothing and the title is never composed here.
//
//   7. **PAGING IS THE BACKEND'S.** Load more appears only while the payload
//      says has_more; when it stops, the backend's end_label prints instead.
//      Appending a page keeps the LATER payload's labels and counts, because
//      the server recomputed them for the page it answered.
//
// No network, no Supabase: fabricated payloads only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/search_page.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';
import 'package:pharma_b2b/widgets/search_surface.dart';

/// One `search_page().items[]` row — the `_search_cards()` shape, which is
/// what Product.fromHomeCard reads.
Map<String, dynamic> _card({
  int id = 900101,
  String name = 'Monticope Tablet',
}) =>
    {
      'id': id,
      'name': name,
      'company': 'MANKIND PHARMA LTD',
      'pack_label': 'Strip of 10 tablets',
      'form_chip': 'Strip',
      'pack_qty_label': '10.0 Tablets in 1 strip',
      'pack_type_label': 'Strip',
      'image': '',
      'category': 'RESPIRATORY',
      'salt': 'Levocetirizine (5mg) + Montelukast (10mg)',
      'has_offer': false,
      'offer_chip': '',
      'rx': {'has': true, 'is_rx': true, 'label': 'Rx'},
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
          'sale_label': 'Sale price:',
          'price_locked': false,
        },
      },
      'mrp_label': '₹174.38',
      'buyable': true,
    };

/// A whole `search_page()` answer. The filter groups are in the order the
/// backend sends them — category first, and only category marked chip_row.
Map<String, dynamic> _payload({
  int items = 2,
  bool hasMore = false,
  bool rail = false,
  bool filtersActive = false,
  String headerLabel = '4 products for “monticope”',
}) =>
    {
      'ok': true,
      'query': 'monticope',
      'has_query': true,
      'placeholder': 'Search medicines, salts, companies',
      'header_label': headerLabel,
      'total': 4,
      'filters_active': filtersActive,
      'filters': {
        'title': 'Filters',
        'clear_label': 'Clear all',
        'apply_label': 'Show results',
        'groups': [
          {
            'key': 'category',
            'label': 'Category',
            'mode': 'single',
            'chip_row': true,
            'options': [
              {'key': 'All', 'label': 'All', 'n': null, 'selected': true},
              {'key': 'RESPIRATORY', 'label': 'RESPIRATORY', 'n': 12, 'selected': false},
            ],
          },
          {
            'key': 'pack_type',
            'label': 'Pack type',
            'mode': 'multi',
            'chip_row': false,
            'options': [
              {'key': 'Strip', 'label': 'Strip', 'n': 9, 'selected': false},
              {'key': 'Bottle', 'label': 'Bottle', 'n': 2, 'selected': false},
            ],
          },
          {
            'key': 'rx',
            'label': 'Prescription',
            'mode': 'single',
            'chip_row': false,
            'options': [
              {'key': 'Rx', 'label': 'Rx only', 'n': null, 'selected': false},
              {'key': 'OTC', 'label': 'OTC only', 'n': null, 'selected': false},
            ],
          },
          {
            'key': 'sort',
            'label': 'Sort',
            'mode': 'single',
            'chip_row': false,
            'options': [
              {'key': 'relevance', 'label': 'Best match', 'n': null, 'selected': true},
              {'key': 'name', 'label': 'Name A–Z', 'n': null, 'selected': false},
            ],
          },
        ],
      },
      'empty': {
        'label': 'No product matches “monticope”.',
        'hint': 'Check the spelling, or try a shorter word.',
        'buttons': [
          {'kind': 'clear_filters', 'tone': 'primary', 'label': 'Clear all'},
          {'kind': 'request', 'tone': 'secondary', 'label': 'Request this product'},
        ],
      },
      'rail': {
        'has': rail,
        'kind': 'last_ordered',
        'title': 'Your last ordered',
        'items': rail ? [_card(id: 900301, name: 'Dolo 650 Tablet')] : const [],
      },
      'paging': {
        'page': 0,
        'page_size': 2,
        'returned': items,
        'has_more': hasMore,
        'next_page': 1,
        'more_label': 'Load more',
        'end_label': 'That is the whole list.',
      },
      'items': [
        for (int i = 0; i < items; i++)
          _card(id: 900101 + i, name: i == 0 ? 'Monticope Tablet' : 'Monticope-A Tablet SR'),
      ],
    };

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    ),
  );
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('1 — one URL spelling, shared by both screens', () {
    test('a full state survives the round trip Home → URL → Catalogue', () {
      const s = SearchQueryState(
        query: 'monticope',
        category: 'RESPIRATORY',
        packTypes: ['Strip', 'Bottle'],
        rx: 'Rx',
        flags: ['cold_chain'],
        sort: 'name',
        page: 2,
      );
      final back = SearchQueryState.fromLocation('/catalogue?${s.toQueryString()}');
      expect(back.query, 'monticope');
      expect(back.category, 'RESPIRATORY');
      expect(back.packTypes, ['Strip', 'Bottle']);
      expect(back.rx, 'Rx');
      expect(back.flags, ['cold_chain']);
      expect(back.sort, 'name');
      expect(back.page, 2);
    });

    test('the backend defaults are ABSENT from the URL, never spelled out', () {
      const s = SearchQueryState(query: 'dolo');
      final params = s.toParams();
      expect(params['q'], 'dolo');
      expect(params.containsKey('category'), isFalse);
      expect(params.containsKey('sort'), isFalse);
      expect(params.containsKey('page'), isFalse);
    });

    test('and they are absent from p_filters too', () {
      expect(const SearchQueryState(query: 'dolo').toFilters(),
          {'sort': 'relevance'});
      expect(
          const SearchQueryState(query: 'dolo', category: 'All').toFilters()
              .containsKey('category'),
          isFalse);
    });

    test('a URL with no search parses to the blank state, not to junk', () {
      final s = SearchQueryState.fromLocation('/');
      expect(s.hasQuery, isFalse);
      expect(s.category, 'All');
      expect(s.sort, 'relevance');
      expect(s.page, 0);
    });
  });

  group('3 — the group\'s own mode decides what a tap means', () {
    SearchFilterGroup group(String key) => SearchFilters.fromMap(
            Map<String, dynamic>.from(_payload()['filters'] as Map))
        .groups
        .firstWhere((g) => g.key == key);

    test('multi toggles: a second tap on pack type removes it', () {
      const s = SearchQueryState(query: 'q');
      final g = group('pack_type');
      final on = s.withOption(g, g.options.first);
      expect(on.packTypes, ['Strip']);
      expect(on.withOption(g, g.options.first).packTypes, isEmpty);
    });

    test('single replaces: sort moves from one option to the other', () {
      const s = SearchQueryState(query: 'q');
      final g = group('sort');
      expect(s.withOption(g, g.options[1]).sort, 'name');
    });

    test('Rx clears when the selected option is tapped again', () {
      const s = SearchQueryState(query: 'q', rx: 'Rx');
      final g = group('rx');
      expect(s.withOption(g, g.options.first).rx, '');
    });

    test('changing what is searched returns to page 0', () {
      const s = SearchQueryState(query: 'q', page: 3);
      final g = group('sort');
      expect(s.withOption(g, g.options[1]).page, 0);
    });

    test('"Clear all" clears the filters and keeps the query', () {
      const s = SearchQueryState(
          query: 'dolo', category: 'RESPIRATORY', packTypes: ['Strip'], rx: 'Rx');
      final c = s.cleared();
      expect(c.query, 'dolo');
      expect(c.category, 'All');
      expect(c.packTypes, isEmpty);
      expect(c.rx, '');
    });
  });

  // CMD #2037 — the INLINE CATEGORY ROW IS DELETED. "All / OTHERS / ANTI
  // INFECTIVES / CARDIAC" sat under the search bar on every home visit, ahead
  // of the feed, duplicating the Shop-by-category tiles one screen below it
  // and the Catalogue's Browse-by tiles. What this group held down — that the
  // row was the payload, in the payload's order — is held down for the SHEET
  // groups instead, which is all that draws here now.
  group('2 — the chip row is gone; the sheet groups are the payload', () {
    testWidgets('the chip_row group draws NOTHING, whatever the payload says',
        (tester) async {
      final p = SearchPagePayload.fromMap(_payload());
      // The payload still MARKS one: the backend contract is unchanged.
      expect(p.filters.chipRowGroup, isNotNull);
      await _pump(
          tester,
          SearchFilterChips(filters: p.filters, onPick: (_, __) {}));
      // ...and not one of its options is on screen.
      expect(find.text('All'), findsNothing);
      expect(find.text('RESPIRATORY'), findsNothing);
      // The other three are one chip each, carrying the group's own label.
      expect(find.text('Pack type'), findsOneWidget);
      expect(find.text('Prescription'), findsOneWidget);
      expect(find.text('Best match'), findsOneWidget); // sort's selection wins
      // And their OPTIONS are not on screen until the sheet is opened.
      expect(find.text('Strip'), findsNothing);
      expect(find.text('Rx only'), findsNothing);
    });

    testWidgets('a screen with no query yet draws no row at all',
        (tester) async {
      final p = SearchPagePayload.fromMap(_payload());
      await _pump(
          tester,
          SearchFilterChips(
              filters: p.filters, showSheetGroups: false, onPick: (_, __) {}));
      // No sheet groups and no category row: the widget takes no height, so
      // the feed starts directly under the search bar.
      expect(find.text('All'), findsNothing);
      expect(find.text('Pack type'), findsNothing);
      expect(tester.getSize(find.byType(SearchFilterChips)).height, 0);
    });

    testWidgets('a tap hands back the backend\'s group and option, untouched',
        (tester) async {
      SearchFilterGroup? g;
      SearchOption? o;
      final p = SearchPagePayload.fromMap(_payload());
      await _pump(
          tester,
          SearchFilterChips(
              filters: p.filters,
              onPick: (gg, oo) {
                g = gg;
                o = oo;
              }));
      // The sheet route is the only way a filter is picked now: open Pack type
      // and tap one of ITS options.
      await tester.tap(find.text('Pack type'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Strip'));
      await tester.pumpAndSettle();
      expect(g!.key, 'pack_type');
      expect(o!.key, 'Strip');
    });
  });

  group('4 & 7 — the result body prints the payload and pages on its word', () {
    testWidgets('header_label verbatim, one row per item, in payload order',
        (tester) async {
      final p = SearchPagePayload.fromMap(_payload());
      await _pump(
          tester,
          SearchResultsView(
            payload: p,
            onOpenProduct: (_) {},
            onLoadMore: () {},
            onEmptyAction: (_) {},
          ));
      expect(find.text('4 products for “monticope”'), findsOneWidget);
      expect(find.byType(CompactProductCard), findsNWidgets(2));
      expect(find.text('Monticope Tablet'), findsOneWidget);
      expect(find.text('MANKIND PHARMA LTD'), findsNWidgets(2));
      // The count line is ONE field: nothing here builds "4 results".
      expect(find.text('4 results'), findsNothing);
    });

    testWidgets('Load more only while the backend says has_more',
        (tester) async {
      await _pump(
          tester,
          SearchResultsView(
            payload: SearchPagePayload.fromMap(_payload(hasMore: true)),
            onOpenProduct: (_) {},
            onLoadMore: () {},
            onEmptyAction: (_) {},
          ));
      expect(find.text('Load more'), findsOneWidget);
      expect(find.text('That is the whole list.'), findsNothing);
    });

    testWidgets('and the backend\'s end_label when it does not', (tester) async {
      await _pump(
          tester,
          SearchResultsView(
            payload: SearchPagePayload.fromMap(_payload()),
            onOpenProduct: (_) {},
            onLoadMore: () {},
            onEmptyAction: (_) {},
          ));
      expect(find.text('That is the whole list.'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    });

    test('appending a page keeps the LATER payload\'s labels and counts', () {
      final first = SearchPagePayload.fromMap(
          _payload(items: 2, hasMore: true, headerLabel: '4 products for “m”'));
      final second = SearchPagePayload.fromMap(
          _payload(items: 2, headerLabel: '4 products for “m”'));
      final joined = first.appended(second);
      expect(joined.items.length, 4);
      expect(joined.paging.hasMore, isFalse); // the server's newer verdict
    });
  });

  group('5 — the empty state is one object, drawn in the payload\'s order', () {
    testWidgets('sentence, hint and both buttons, in order', (tester) async {
      final p = SearchPagePayload.fromMap(_payload(items: 0, filtersActive: true));
      await _pump(
          tester,
          SearchResultsView(
            payload: p,
            onOpenProduct: (_) {},
            onLoadMore: () {},
            onEmptyAction: (_) {},
          ));
      expect(find.text('No product matches “monticope”.'), findsOneWidget);
      expect(find.text('Check the spelling, or try a shorter word.'),
          findsOneWidget);
      // Clear all is the PRIMARY and comes first — the backend's order.
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(OutlinedButton), findsOneWidget);
      String labelOf(Finder button) => tester
          .widget<Text>(
              find.descendant(of: button, matching: find.byType(Text)))
          .data!;
      expect(labelOf(find.byType(FilledButton)), 'Clear all');
      expect(labelOf(find.byType(OutlinedButton)), 'Request this product');
    });

    testWidgets('a tap hands back the button\'s own kind', (tester) async {
      String? kind;
      await _pump(
          tester,
          SearchResultsView(
            payload: SearchPagePayload.fromMap(_payload(items: 0)),
            onOpenProduct: (_) {},
            onLoadMore: () {},
            onEmptyAction: (k) => kind = k,
          ));
      await tester.tap(find.text('Request this product'));
      await tester.pump();
      expect(kind, 'request');
    });

    testWidgets('an empty payload draws nothing rather than a sentence of its own',
        (tester) async {
      await _pump(tester,
          const SearchEmptyView(empty: SearchEmpty.empty, onAction: _noop));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('6 — the idle rail is the backend\'s `has`', () {
    testWidgets('has:false draws nothing, whatever else the payload carries',
        (tester) async {
      final p = SearchPagePayload.fromMap(_payload());
      await _pump(tester, SearchIdleRail(rail: p.rail, surface: 'test'));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('has:true prints the backend\'s own title, never one of ours',
        (tester) async {
      final p = SearchPagePayload.fromMap(_payload(rail: true));
      await _pump(tester, SearchIdleRail(rail: p.rail, surface: 'test'));
      expect(find.text('Your last ordered'), findsOneWidget);
      expect(find.text('Recent searches'), findsNothing);
    });
  });
}

void _noop(String _) {}
