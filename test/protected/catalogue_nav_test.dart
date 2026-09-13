// CMD #1908 — catalogue NAVIGATION: one trail, one letter strip, one search
// bar, and no narrowing chips inside a drill-down.
//
// What this file holds down, and why each one was a bug worth a permanent test:
//
//   1. THE TRAIL IS THE PAYLOAD'S, WORDS AND DESTINATION BOTH. `catalogue_trail()`
//      sends each step's label AND the four values the route is made of. The
//      screen copies them. A screen that counted a depth instead could not put
//      "Company" above a company page, because a company page has no depth.
//   2. IT NEVER DISAPPEARS. It lives outside the scroll view, and the last
//      trail is KEPT when the next payload carries none — the "sticky" in the
//      spec means "still there while the next screen is loading", not "pinned".
//   3. ONE STRIP, THREE LISTS. Companies, salts and classes all send a `rail`
//      and all re-ask their own RPC with `p_letter`. The strip is horizontal
//      and builds every letter, so the whole alphabet is reachable.
//   4. "All" CLEARS. The letter is part of the ROUTE, so it round-trips
//      through the URL and the back button.
//   5. NO PACK CHIPS IN A DRILL-DOWN. The backend sends an empty sentence and
//      empty filter groups for company/salt/class lists; the SORT options
//      still arrive and still draw. The screen renders what it is given — it
//      must not resurrect the home page's sentence on a list.
//   6. ONE SEARCH BAR PER SCREEN. The salt list's own "Search a salt…" field
//      is gone; the hero field is the only TextField on the screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/screens/catalogue_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/catalogue_alphabet_rail.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _zone() => {
      'has': true,
      'on': true,
      'label': 'Available in my zone',
      'zone_label': 'Raipur Zone',
      'note': 'Showing what suppliers in your zone can send.',
    };

/// The trail exactly as `catalogue_trail()` builds it — every step carries its
/// own route, and only the last is `current`.
Map<String, dynamic> _trail(List<Map<String, dynamic>> items) => {
      'label': 'You are here',
      'separator': '›',
      'items': items,
    };

Map<String, dynamic> _crumb(String label,
        {required String tab,
        List<String> path = const [],
        String? listKind,
        String? listKey,
        bool current = false}) =>
    {
      'label': label,
      'current': current,
      'route': {
        'tab': tab,
        'path': path,
        'list_kind': listKind,
        'list_key': listKey,
      },
    };

/// A–Z track: 'Q' is deliberately empty and still on it.
Map<String, dynamic> _rail() => {
      'label': 'Jump to a letter',
      'all_label': 'All',
      'letters': [
        {'key': 'A', 'label': 'A', 'n': 2243, 'enabled': true},
        {'key': 'Q', 'label': 'Q', 'n': 0, 'enabled': false},
        {'key': 'Z', 'label': 'Z', 'n': 41, 'enabled': true},
        {'key': '#', 'label': '#', 'n': 7, 'enabled': true},
      ],
    };

Map<String, dynamic> _home() => {
      'ok': true,
      'title': 'Catalogue',
      'search': {
        'placeholder': 'Search a medicine, salt or company',
        'hint': 'Search a salt or a company',
        'clear_label': 'Clear',
      },
      'zone': _zone(),
      'doors_title': 'Browse by',
      'doors': <Map<String, dynamic>>[],
      'recent_viewed': {'has': false, 'title': '', 'items': <Map<String, dynamic>>[]},
      // The front page keeps its sentence — it is not a drill-down.
      'sentence': {
        'lead': 'Showing',
        'separator': '·',
        'all_label': 'everything',
        'clear_label': 'Clear all',
        'has_selection': false,
        'parts': [
          {'group': 'pack_type', 'key': 'Strip', 'label': 'Strip',
           'selected': false, 'mode': 'multi'},
        ],
      },
      'tabs': <Map<String, dynamic>>[],
      'filters': _defs(groups: const []),
    };

Map<String, dynamic> _defs({
  required List<Map<String, dynamic>> groups,
  List<Map<String, dynamic>> sort = const [
    {'key': 'name', 'label': 'Name A–Z'},
    {'key': 'newest', 'label': 'Newest added'},
  ],
}) =>
    {
      'title': 'Filters',
      'clear_label': 'Clear all',
      'apply_label': 'Show results',
      'groups': groups,
      'sort': {'label': 'Sort', 'options': sort},
    };

Map<String, dynamic> _companies({Map<String, dynamic>? trail}) => {
      'ok': true,
      'title': 'Companies',
      'zone': _zone(),
      'all_label': 'All',
      'rail': _rail(),
      'trail': trail ??
          _trail([
            _crumb('Catalogue', tab: 'browse'),
            _crumb('Company', tab: 'companies', current: true),
          ]),
      'count_label': '18,563 companies',
      'empty_label': 'No company matches this view.',
      'has_more': false,
      'next_offset': 1,
      'rows': [
        {'key': 'abbott', 'label': 'ABBOTT', 'letter': 'A', 'count_label': '1,204 products'},
      ],
    };

Map<String, dynamic> _salts() => {
      'ok': true,
      'title': 'Salts',
      'zone': _zone(),
      'all_label': 'All',
      'rail': _rail(),
      'trail': _trail([
        _crumb('Catalogue', tab: 'browse'),
        _crumb('Salt', tab: 'salts', current: true),
      ]),
      'search_hint': 'Search a salt, e.g. Paracetamol',
      'lead_label': 'Biggest salts first — search to narrow.',
      'count_label': '1,06,571 salts',
      'empty_label': 'No salt matches this search in this view.',
      'has_more': false,
      'next_offset': 1,
      'rows': [
        {'key': 'Ofloxacin (200mg)', 'label': 'Ofloxacin (200mg)', 'count_label': '44 brands'},
      ],
    };

Map<String, dynamic> _tree({
  List<String> path = const [],
  Map<String, dynamic>? trail,
  bool withTrail = true,
}) =>
    {
      'ok': true,
      'title': 'Therapeutic class',
      'path': path,
      'zone': _zone(),
      'rail': _rail(),
      if (withTrail)
        'trail': trail ??
            _trail([
              _crumb('Catalogue', tab: 'browse'),
              _crumb('Category', tab: 'browse', current: path.isEmpty),
              for (var i = 0; i < path.length; i++)
                _crumb(path[i],
                    tab: 'browse',
                    path: path.sublist(0, i + 1),
                    current: i == path.length - 1),
            ]),
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

/// A drill-down product list: the backend sent an EMPTY sentence and EMPTY
/// filter groups, and kept the sort options.
Map<String, dynamic> _drillList() => {
      'ok': true,
      'title': 'SUN PHARMA',
      'subtitle': 'Products from this company',
      'count_label': '1,204 products',
      'empty_label': 'Nothing here in this view.',
      'more_label': 'Load more',
      'end_label': 'That is the whole list.',
      'sort': 'name',
      'filters_active': false,
      'filters_active_label': '',
      'zone': _zone(),
      'filters': _defs(groups: const []),
      'sentence': {
        'lead': '', 'separator': '', 'all_label': '', 'clear_label': '',
        'has_selection': false, 'parts': <Map<String, dynamic>>[],
      },
      'trail': _trail([
        _crumb('Catalogue', tab: 'browse'),
        _crumb('Company', tab: 'companies'),
        _crumb('SUN PHARMA',
            tab: 'companies', listKind: 'company', listKey: 'SUN PHARMA', current: true),
      ]),
      'empty': {
        'label': 'Nothing here in this view.',
        'hint': '',
        'action': {'has': false, 'kind': 'request', 'label': ''},
        'clear': {'has': false, 'kind': 'clear_filters', 'label': ''},
      },
      'items': <Map<String, dynamic>>[],
      'has_more': false,
      'next_cursor': null,
    };

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
  bool called(String fn) => calls.any((c) => c.$1 == fn);
}

Future<_Rpc> _pump(
  WidgetTester tester, {
  required Map<String, List<Map<String, dynamic>>> queued,
  CatalogueRoute? route,
  Size size = const Size(1400, 900),
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
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the breadcrumb is the backend\'s trail', () {
    testWidgets('every word and the separator print verbatim, in payload order',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_tree': [
          _tree(path: const ['ANTI INFECTIVES', 'Cephalosporins']),
        ],
      }, route: const CatalogueRoute(path: ['ANTI INFECTIVES', 'Cephalosporins']));

      expect(find.text('Catalogue'), findsWidgets);
      expect(find.text('Category'), findsOneWidget);
      expect(find.text('ANTI INFECTIVES'), findsWidgets);
      expect(find.text('Cephalosporins'), findsOneWidget);
      // The chevron is a payload string, not an Icon this screen picked.
      expect(find.text('›'), findsNWidgets(3));
    });

    testWidgets('it is drawn on a PRODUCT GRID too, not only while browsing',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_drillList()],
      }, route: const CatalogueRoute(
          tab: 'companies', listKind: 'company', listKey: 'SUN PHARMA'));

      expect(find.text('Company'), findsOneWidget);
      expect(find.text('SUN PHARMA'), findsWidgets);
    });

    testWidgets('a crumb tap carries the crumb\'s OWN route, never a depth count',
        (tester) async {
      final rpc = await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_drillList()],
        'catalogue_companies': [_companies()],
      }, route: const CatalogueRoute(
          tab: 'companies', listKind: 'company', listKey: 'SUN PHARMA'));

      await tester.tap(find.text('Company'));
      await tester.pumpAndSettle();

      // The 'Company' crumb said tab:companies with no list — so the company
      // INDEX is what loads, and the product list is not re-asked.
      expect(rpc.called('catalogue_companies'), isTrue);
      expect(rpc.lastArgs('catalogue_companies')['p_letter'], isNull);
    });

    testWidgets('a payload with no trail keeps the last one — it never blinks out',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_companies': [_companies()],
        // The next screen answers without a trail at all (an older backend, a
        // half-rolled deploy). The header must not go blank.
        'catalogue_tree': [_tree(withTrail: false)],
      }, route: const CatalogueRoute(tab: 'companies'));

      expect(find.text('Company'), findsOneWidget);
      await tester.tap(find.text('Catalogue').first);
      await tester.pumpAndSettle();
      expect(find.text('Company'), findsOneWidget,
          reason: 'the trail is held across a reload, so it cannot disappear '
              'while the next payload is in flight');
    });
  });

  group('the A–Z strip is one component on three lists', () {
    for (final (tab, fn) in <(String, String)>[
      ('companies', 'catalogue_companies'),
      ('salts', 'catalogue_salts'),
      ('browse', 'catalogue_tree'),
    ]) {
      testWidgets('$tab draws the strip and re-asks with p_letter', (tester) async {
        final body = switch (fn) {
          'catalogue_companies' => _companies(),
          'catalogue_salts' => _salts(),
          _ => _tree(),
        };
        final rpc = await _pump(tester, queued: {
          'catalogue_home': [_home()],
          fn: [body],
        }, route: CatalogueRoute(tab: tab));

        expect(find.byType(CatalogueAlphabetRail), findsOneWidget);
        // Every letter of the track is built, disabled ones included.
        expect(find.text('Q'), findsOneWidget);
        expect(find.text('#'), findsOneWidget);

        await tester.tap(find.descendant(
            of: find.byType(CatalogueAlphabetRail), matching: find.text('Z')));
        await tester.pumpAndSettle();
        expect(rpc.lastArgs(fn)['p_letter'], 'Z');
      });
    }

    testWidgets('"All" is the backend\'s word and it clears the letter',
        (tester) async {
      final rpc = await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_salts': [_salts()],
      }, route: const CatalogueRoute(tab: 'salts', letter: 'Z'));

      await tester.tap(find.descendant(
          of: find.byType(CatalogueAlphabetRail), matching: find.text('All')));
      await tester.pumpAndSettle();
      expect(rpc.lastArgs('catalogue_salts')['p_letter'], isNull);
    });

    testWidgets('a product grid gets no strip — the backend sent no rail',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_drillList()],
      }, route: const CatalogueRoute(
          tab: 'companies', listKind: 'company', listKey: 'SUN PHARMA'));
      expect(find.byType(CatalogueAlphabetRail), findsNothing);
    });

    test('the letter round-trips through the URL', () {
      const r = CatalogueRoute(tab: 'salts', letter: 'Z');
      expect(r.url, contains('l=Z'));
      expect(CatalogueRoute.parse(r.url.split('?').last).letter, 'Z');
      expect(CatalogueRoute.parse('').letter, isNull);
    });
  });

  group('a drill-down has no narrowing chips, and keeps its sort', () {
    testWidgets('an empty sentence draws no row, and the home one is not reused',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_list': [_drillList()],
      }, route: const CatalogueRoute(
          tab: 'companies', listKind: 'company', listKey: 'SUN PHARMA'));

      // The home page's own chip must not leak onto a company page.
      expect(find.text('Strip'), findsNothing);
      expect(find.text('Showing everything'), findsNothing);
      // The sort options are not filters and are still offered.
      expect(find.text('Name A–Z'), findsOneWidget);
      expect(find.text('Newest added'), findsOneWidget);
    });

    testWidgets('a browse index draws no sentence either', (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_companies': [_companies()],
      }, route: const CatalogueRoute(tab: 'companies'));
      expect(find.text('Strip'), findsNothing);
    });
  });

  group('one search bar per screen', () {
    testWidgets('the salt list has no field of its own', (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_salts': [_salts()],
      }, route: const CatalogueRoute(tab: 'salts'));

      expect(find.byType(TextField), findsOneWidget,
          reason: 'the hero field at the top is the only search box');
      expect(find.text('Search a salt, e.g. Paracetamol'), findsNothing);
      // The subtitle Om asked to keep is still there.
      expect(find.text('Biggest salts first — search to narrow.'), findsOneWidget);
    });
  });
}
