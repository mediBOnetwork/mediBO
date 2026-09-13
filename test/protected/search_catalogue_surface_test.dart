// PROTECTED — CMD #1906, spec items 2, 4, 5 and 6, on the CATALOGUE side.
//
// `search_one_surface_test.dart` holds down the shared widgets and the URL
// codec in isolation. This file holds down the thing that kept drifting: the
// CATALOGUE actually mounting them. Before this command the Catalogue had its
// own hero field, its own typeahead panel and its own
// `catalogue_list(kind:'search')` grid — the same query, answered by a
// different RPC and drawn by different widgets from the one Home used.
//
// What this holds down:
//
//   1. **A SEARCH ON THE CATALOGUE IS `search_page()`.** Not catalogue_list.
//      The rows, the header line, the paging labels and the empty state are
//      that one payload, rendered by the shared [SearchResultsView].
//
//   2. **ONE URL, BOTH SCREENS.** `/catalogue?q=…` carries the SAME parameter
//      names Home writes (`SearchQueryState.toParams`), and round-trips
//      through `CatalogueRoute`. That round trip is what makes moving between
//      the two tabs keep query, filters and page.
//
//   3. **`q=` WITH A LIST SCOPE IS STILL A BROWSE NARROWING.** `lk=salt&q=para`
//      is the catalogue's own idea and predates the shared search; it must not
//      be swallowed by it, or every deep link into a narrowed salt list breaks.
//
//   4. **THE SHELL IS TOLD.** A search made on the Catalogue is handed back
//      through `onSearchChanged`, which is how Home shows the same one when
//      the shopper switches tab.
//
//   5. **THE RECENT STRIP AND THE EMPTY STATE ARE THE PAYLOAD'S, HERE TOO.**
//      Same `has` flag, same buttons, same words as on Home — because it is
//      literally the same widget reading the same fields.
//
// No network, no Supabase: fabricated payloads only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/search_page.dart';
import 'package:pharma_b2b/screens/catalogue_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/product_row_card.dart';
import 'package:pharma_b2b/widgets/search_surface.dart';
import 'package:pharma_b2b/widgets/search_typeahead.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _catHome() => {
      'ok': true,
      'title': 'Catalogue',
      'search': {
        'placeholder': 'Search a medicine, salt or company',
        'hint': '',
        'clear_label': 'Clear',
      },
      'zone': {'has': false},
      'doors_title': '',
      'doors': <Map<String, dynamic>>[],
      'tabs': <Map<String, dynamic>>[],
      'sentence': {'has_selection': false, 'parts': <Map<String, dynamic>>[]},
    };

Map<String, dynamic> _card(String id, String name) => {
      'id': id,
      'name': name,
      'company': 'Micro Labs',
      'pack': '15 tablets',
      'price_display': '₹28.50',
      'mrp_display': '₹34.00',
      'can_add': true,
      'add_label': 'ADD',
    };

Map<String, dynamic> _searchPage({
  List<Map<String, dynamic>>? items,
  bool hasMore = false,
  Map<String, dynamic>? recent,
  Map<String, dynamic>? empty,
  bool suggestEnabled = false,
}) =>
    {
      'ok': true,
      'suggest_enabled': suggestEnabled,
      'query': 'dolo',
      'has_query': true,
      'placeholder': 'Search a medicine, salt or company',
      'header_label': '41 matches for "dolo"',
      'total': 41,
      'filters_active': false,
      'filters': {
        'title': 'Narrow it down',
        'clear_label': 'Clear all',
        'apply_label': 'Apply',
        'groups': [
          {
            'key': 'category',
            'label': 'Category',
            'mode': 'single',
            'chip_row': true,
            'options': [
              {'key': 'All', 'label': 'All', 'n': 41, 'selected': true},
              {'key': 'Pain', 'label': 'Pain relief', 'n': 12, 'selected': false},
            ],
          },
          {
            'key': 'sort',
            'label': 'Sort',
            'mode': 'single',
            'chip_row': false,
            'options': [
              {'key': 'relevance', 'label': 'Best match', 'n': null, 'selected': true},
              {'key': 'price_asc', 'label': 'Price: low to high', 'n': null, 'selected': false},
            ],
          },
        ],
      },
      'empty': empty ??
          {
            'label': '',
            'hint': '',
            'buttons': <Map<String, dynamic>>[],
          },
      'recent': recent ?? {'has': false},
      'paging': {
        'page': 0,
        'page_size': 20,
        'returned': (items ?? const []).length,
        'has_more': hasMore,
        'next_page': 1,
        'more_label': 'Load more',
        'end_label': "That's everything",
      },
      'items': items ?? [_card('p1', 'Dolo 650'), _card('p2', 'Dolopar')],
    };

// ── harness ──────────────────────────────────────────────────────────────────

class _Rpc {
  final List<(String, Map<String, dynamic>)> calls = [];
  final Map<String, Map<String, dynamic>> answers;
  _Rpc(this.answers);

  Future<Map<String, dynamic>> call(String fn, Map<String, dynamic> args) async {
    calls.add((fn, args));
    return answers[fn] ?? {'ok': false};
  }

  bool called(String fn) => calls.any((c) => c.$1 == fn);
  Map<String, dynamic> lastArgs(String fn) =>
      calls.lastWhere((c) => c.$1 == fn).$2;
}

Future<_Rpc> _pump(
  WidgetTester tester, {
  required Map<String, Map<String, dynamic>> answers,
  CatalogueRoute? route,
  SearchQueryState shellSearch = SearchQueryState.blank,
  void Function(SearchQueryState)? onSearchChanged,
}) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final rpc = _Rpc(answers);
  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: CatalogueScreen(
            active: true,
            rpc: rpc.call,
            initialRoute: route ?? const CatalogueRoute(),
            shellSearch: shellSearch,
            onSearchChanged: onSearchChanged,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return rpc;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  // ── 2. one URL, both screens ───────────────────────────────────────────────

  group('2 — the URL is the same on both screens', () {
    test('a shared search round-trips through the catalogue route', () {
      const state = SearchQueryState(
        query: 'dolo',
        category: 'Pain',
        packTypes: ['Strip', 'Vial'],
        rx: 'Rx',
        flags: ['cold_chain'],
        sort: 'price_asc',
        page: 2,
      );
      const route = CatalogueRoute(search: state, query: 'dolo');
      final url = route.url;

      // The string after `?` is what Home writes — the same codec, not a
      // catalogue spelling that happens to look similar.
      expect(url, '/catalogue?${state.toQueryString()}');

      final back = CatalogueRoute.parse(url.substring(url.indexOf('?')));
      expect(back.showsSearch, isTrue);
      expect(back.search.query, 'dolo');
      expect(back.search.category, 'Pain');
      expect(back.search.packTypes, ['Strip', 'Vial']);
      expect(back.search.rx, 'Rx');
      expect(back.search.flags, ['cold_chain']);
      expect(back.search.sort, 'price_asc');
      expect(back.search.page, 2);
      expect(back.url, url, reason: 'the round trip must be stable');
    });

    test('a Home URL opens the same search on the Catalogue', () {
      // Exactly what home_shell appends to `/`.
      const home = SearchQueryState(query: 'dolo', sort: 'name');
      final back = CatalogueRoute.parse('?${home.toQueryString()}');
      expect(back.search.toQueryString(), home.toQueryString());
    });

    test('defaults never reach the URL', () {
      const blank = CatalogueRoute(search: SearchQueryState(query: 'dolo'));
      expect(blank.url, '/catalogue?q=dolo');
    });
  });

  // ── 3. the browse narrowing survives ───────────────────────────────────────

  group('3 — `q=` beside a list scope is still the browse narrowing', () {
    test('lk=salt&q=para is not swallowed by the shared search', () {
      final r = CatalogueRoute.parse('?lk=salt&k=Paracetamol&q=para&sort=newest');
      expect(r.showsSearch, isFalse);
      expect(r.showsList, isTrue);
      expect(r.listKind, 'salt');
      expect(r.query, 'para');
      expect(r.sort, 'newest');
    });
  });

  // ── 1 & 5. the catalogue mounts the shared surface ─────────────────────────

  group('1 — a search on the Catalogue is search_page()', () {
    testWidgets('it calls search_page, never catalogue_list', (tester) async {
      final rpc = await _pump(
        tester,
        answers: {'catalogue_home': _catHome(), 'search_page': _searchPage()},
        route: const CatalogueRoute(
            search: SearchQueryState(query: 'dolo'), query: 'dolo'),
      );

      expect(rpc.called('search_page'), isTrue);
      expect(rpc.called('catalogue_list'), isFalse,
          reason: 'the duplicate search path is retired');
      expect(rpc.lastArgs('search_page')['p_q'], 'dolo');
    });

    testWidgets('the rows are the shared row card, in payload order',
        (tester) async {
      await _pump(
        tester,
        answers: {'catalogue_home': _catHome(), 'search_page': _searchPage()},
        route: const CatalogueRoute(
            search: SearchQueryState(query: 'dolo'), query: 'dolo'),
      );

      expect(find.byType(SearchResultsView), findsOneWidget);
      expect(find.byType(ProductRowCard), findsNWidgets(2));
      // The header line is the backend's sentence, printed verbatim.
      expect(find.text('41 matches for "dolo"'), findsOneWidget);
    });

    testWidgets('the header is the shared SearchChrome, not a hero of its own',
        (tester) async {
      await _pump(
        tester,
        answers: {'catalogue_home': _catHome(), 'search_page': _searchPage()},
        route: const CatalogueRoute(
            search: SearchQueryState(query: 'dolo'), query: 'dolo'),
      );

      expect(find.byType(SearchChrome), findsOneWidget);
      // One field on the screen — the shared one.
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('the backend says Load more, and only then', (tester) async {
      await _pump(
        tester,
        answers: {
          'catalogue_home': _catHome(),
          'search_page': _searchPage(hasMore: true),
        },
        route: const CatalogueRoute(
            search: SearchQueryState(query: 'dolo'), query: 'dolo'),
      );
      expect(find.text('Load more'), findsOneWidget);
      expect(find.text("That's everything"), findsNothing);
    });
  });

  group('5 — the recent strip and the empty state are the payload\'s', () {
    testWidgets('has:true draws the backend\'s title and entries',
        (tester) async {
      await _pump(
        tester,
        answers: {
          'catalogue_home': _catHome(),
          'search_page': _searchPage(recent: {
            'has': true,
            'title': 'Recent searches',
            'clear_label': 'Clear',
            'items': [
              {'q': 'dolo', 'label': 'dolo'},
              {'q': 'azee', 'label': 'azee'},
            ],
          }),
        },
        route: const CatalogueRoute(
            search: SearchQueryState(query: 'dolo'), query: 'dolo'),
      );
      expect(find.text('Recent searches'), findsOneWidget);
      expect(find.text('azee'), findsOneWidget);
    });

    testWidgets('an empty result prints the backend\'s sentence and buttons',
        (tester) async {
      await _pump(
        tester,
        answers: {
          'catalogue_home': _catHome(),
          'search_page': _searchPage(items: const [], empty: {
            'label': 'No medicine matched "dolo".',
            'hint': 'Check the spelling, or ask us to add it.',
            'buttons': [
              {'kind': 'clear_filters', 'tone': 'primary', 'label': 'Clear filters'},
              {'kind': 'request', 'tone': 'secondary', 'label': 'Request this medicine'},
            ],
          }),
        },
        route: const CatalogueRoute(
            search: SearchQueryState(query: 'dolo'), query: 'dolo'),
      );
      expect(find.text('No medicine matched "dolo".'), findsOneWidget);
      expect(find.text('Check the spelling, or ask us to add it.'), findsOneWidget);
      expect(find.text('Clear filters'), findsOneWidget);
      expect(find.text('Request this medicine'), findsOneWidget);
    });
  });

  // ── 4. the shell is told ───────────────────────────────────────────────────

  group('4 — the search travels between the two tabs', () {
    testWidgets('the shell\'s search opens the Catalogue already searching',
        (tester) async {
      final rpc = await _pump(
        tester,
        answers: {'catalogue_home': _catHome(), 'search_page': _searchPage()},
        shellSearch: const SearchQueryState(query: 'dolo', sort: 'price_asc'),
      );
      expect(rpc.called('search_page'), isTrue);
      expect(rpc.lastArgs('search_page')['p_q'], 'dolo');
      expect((rpc.lastArgs('search_page')['p_filters'] as Map)['sort'],
          'price_asc');
      expect(find.byType(SearchResultsView), findsOneWidget);
    });

    testWidgets('a search made here is handed back to the shell',
        (tester) async {
      SearchQueryState? reported;
      await _pump(
        tester,
        answers: {'catalogue_home': _catHome(), 'search_page': _searchPage()},
        onSearchChanged: (s) => reported = s,
      );

      await tester.enterText(find.byType(TextField), 'dolo');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(reported, isNotNull);
      expect(reported!.query, 'dolo');
    });
  });

  // ── 6. the typeahead panel is the BACKEND's to offer ──────────────────────

  /// CMD #1906, Om's call on 2026-09-13, from a phone screenshot of Home:
  /// "dont give this suggestion". He had typed a brand and the ONLY thing the
  /// keystrokes produced was one card offering to search for the word already
  /// in the box — the page behind it had not moved.
  ///
  /// Nothing was deleted for that. The panel, the chip and #1905's suggestion
  /// navigation all still work; what changed is that the panel is only OFFERED
  /// when `search_page()` says so, via app_settings.search_suggest_enabled.
  /// That is the difference between a preference Om can change with an UPDATE
  /// and one that needs a deploy, and this test is what keeps it that way:
  /// the same keystrokes, the same stubbed `search_suggest()` answer, and the
  /// panel appears or does not appear PURELY on the backend's flag.
  group("6 — the typeahead panel is the backend's to offer", () {
    setUp(() {
      SearchSuggestController.rpcTransport = (fn, params) async => {
            'ready': true,
            'clear_label': 'Clear',
            'groups': [
              {
                'key': 'products',
                'label': 'Products',
                'items': [
                  {
                    'label': 'Monticope Tablet',
                    'sub': 'by MANKIND PHARMA LTD',
                    'meta': '3 variants',
                    'q': 'Monticope',
                  },
                ],
              },
            ],
          };
    });
    tearDown(() => SearchSuggestController.rpcTransport = null);

    Future<void> typeInto(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), 'monticope');
      // Past the controller's own 180 ms debounce, then let the future land.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('suggest_enabled:false — typing draws no panel', (tester) async {
      await _pump(
        tester,
        answers: {
          'catalogue_home': _catHome(),
          'search_page': _searchPage(),
        },
        route: const CatalogueRoute(
            search: SearchQueryState(query: 'dolo'), query: 'dolo'),
      );

      await typeInto(tester);

      expect(find.byType(SearchSuggestions), findsNothing);
      expect(find.text('Monticope Tablet'), findsNothing);
    });

    testWidgets('suggest_enabled:true — the same keystrokes draw it',
        (tester) async {
      await _pump(
        tester,
        answers: {
          'catalogue_home': _catHome(),
          'search_page': _searchPage(suggestEnabled: true),
        },
        route: const CatalogueRoute(
            search: SearchQueryState(query: 'dolo'), query: 'dolo'),
      );

      await typeInto(tester);

      expect(find.byType(SearchSuggestions), findsOneWidget);
      expect(find.text('Monticope Tablet'), findsOneWidget);
    });

    test('the flag is the payload\'s, and absent means off', () {
      expect(SearchPagePayload.fromMap(_searchPage()).suggestEnabled, isFalse);
      expect(
          SearchPagePayload.fromMap(_searchPage(suggestEnabled: true))
              .suggestEnabled,
          isTrue);
      // A backend that has not been taught the key yet must not light it up.
      expect(
          SearchPagePayload.fromMap(const {'ok': true}).suggestEnabled, isFalse);
    });
  });
}
