// CMD #1953 — "Shop by condition" reads MEDICINE.condition, and the key it
// carries is a PRINTED PHRASE, not a slug.
//
// #1910's Use door keyed every condition by a slug ('diabetes-type-2'). #1953
// derives the vocabulary from MEDICINE.uses instead, so the facet key IS the
// sentence a shopper reads — 'Pain relief', with a space and a capital. That
// is a new class of bug for the client:
//
//   1. THE PHRASE IS CARRIED VERBATIM. A key with a space, a capital or an
//      ampersand goes to catalogue_list exactly as the backend printed it. The
//      moment Dart lower-cases, slugifies or trims it, the array containment
//      `condition @> array[key]` matches nothing and a full door shows zero
//      products — the silent failure this file exists to stop.
//   2. THE URL ROUND-TRIPS IT. A phrase key must survive url -> parse -> url,
//      percent-encoded in the link and decoded back to the same phrase, or a
//      shared "Shop by condition" link lands on an empty list.
//   3. THE SCREEN COUNTS NOTHING. Every number and word on the door is the
//      payload's — count_label per row, count_label for the page, the title.
//      A "N uses" built in Dart is what made the old door say "0 uses".
//   4. ROWS RENDER IN PAYLOAD ORDER. The backend sorts by size; the fixture is
//      deliberately not alphabetical, so a client-side sort would show.
//   5. AN EMPTY DOOR STILL SPEAKS. No rows means the backend's empty_label,
//      never a blank screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/screens/catalogue_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

/// The Use door as #1953's backend prints it: phrases, biggest first, with
/// every word already formatted. Not alphabetical on purpose.
Map<String, dynamic> _conditions({List<Map<String, dynamic>>? rows}) => {
      'ok': true,
      'title': 'Shop by condition',
      'zone': {'on': false, 'label': 'All zones', 'zone_label': '', 'note': ''},
      'letter': null,
      'q': null,
      'all_label': 'All',
      'trail': {
        'rows': [
          {'label': 'Catalogue', 'tab': 'browse', 'kind': '', 'key': '', 'path': <String>[]},
          {'label': 'Use', 'tab': 'conditions', 'kind': '', 'key': '', 'path': <String>[]},
        ],
      },
      'rail': {'label': 'Jump to a letter', 'rows': <Map<String, dynamic>>[]},
      'search_hint': 'Search a use, e.g. Fever',
      'lead_label': 'Biggest uses first — search to narrow.',
      'empty_label': 'No use matches this search.',
      'count_label': '3 uses',
      'offset': 0,
      'next_offset': 3,
      'has_more': false,
      'more_label': 'Load more',
      'rows': rows ??
          [
            {
              'key': 'Pain relief',
              'label': 'Pain relief',
              'n': 18402,
              'letter': 'P',
              'count_label': '18,402 products',
            },
            {
              'key': 'Fever',
              'label': 'Fever',
              'n': 12410,
              'letter': 'F',
              'count_label': '12,410 products',
            },
            {
              'key': 'Cough & cold',
              'label': 'Cough & cold',
              'n': 4120,
              'letter': 'C',
              'count_label': '4,120 products',
            },
          ],
    };

Map<String, dynamic> _list() => {
      'ok': true,
      'title': 'Pain relief',
      'subtitle': 'Products used for this condition',
      'count_label': '18,402 products',
      'empty_label': 'Nothing in Pain relief right now.',
      'end_label': 'That is the whole list.',
      'more_label': 'Load more',
      'trail': {
        'rows': [
          {'label': 'Catalogue', 'tab': 'browse', 'kind': '', 'key': '', 'path': <String>[]},
          {'label': 'Pain relief', 'tab': 'conditions', 'kind': 'condition', 'key': 'Pain relief', 'path': <String>[]},
        ],
      },
      'rail': {'label': '', 'rows': <Map<String, dynamic>>[]},
      'filters': {
        'title': 'Filters',
        'clear_label': 'Clear all',
        'apply_label': 'Show results',
        'groups': <Map<String, dynamic>>[],
        'sort': {'label': 'Sort', 'options': <Map<String, dynamic>>[]},
      },
      'sentence': {
        'lead': '', 'parts': <Map<String, dynamic>>[], 'all_label': '',
        'separator': '', 'clear_label': '', 'has_selection': false,
      },
      'filters_active': false,
      'filters_active_label': '',
      'grouped': false,
      'empty': {
        'label': 'Nothing in Pain relief right now.',
        'hint': '',
        'action': {'has': false, 'kind': 'request', 'label': ''},
        'clear': {'has': false, 'kind': 'clear_filters', 'label': ''},
      },
      'items': <Map<String, dynamic>>[],
      'has_more': false,
      'next_cursor': null,
    };

class _CatRpc {
  _CatRpc(this.queued);
  final Map<String, List<Map<String, dynamic>>> queued;
  final List<(String, Map<String, dynamic>)> calls = [];

  Future<Map<String, dynamic>> call(String fn, Map<String, dynamic> args) async {
    calls.add((fn, args));
    final q = queued[fn];
    if (q == null || q.isEmpty) return {'ok': false};
    return q.length == 1 ? q.first : q.removeAt(0);
  }

  Map<String, dynamic> lastArgs(String fn) => calls.lastWhere((c) => c.$1 == fn).$2;
  bool called(String fn) => calls.any((c) => c.$1 == fn);
}

/// A PHONE viewport, because 99% of mediBO shoppers are on one (CMD #1950).
Future<_CatRpc> _pumpPhone(
  WidgetTester t,
  Map<String, List<Map<String, dynamic>>> queued, {
  CatalogueRoute? route,
  Size size = const Size(360, 800),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  final rpc = _CatRpc(queued);
  await t.pumpWidget(AppState(
    cart: CartModel.forTest(),
    child: MaterialApp(
      home: Scaffold(
        body: CatalogueScreen(
          active: true,
          rpc: rpc.call,
          initialRoute: route ?? const CatalogueRoute(tab: 'conditions'),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
  return rpc;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the Use door prints phrases', () {
    testWidgets('1 · title, rows and counts are the payload, in payload order',
        (t) async {
      await _pumpPhone(t, {'catalogue_conditions': [_conditions()]});

      expect(find.text('Shop by condition'), findsWidgets);
      expect(find.text('Pain relief'), findsWidgets);
      expect(find.text('18,402 products'), findsWidgets);
      expect(find.text('Cough & cold'), findsWidgets);
      expect(find.text('4,120 products'), findsWidgets);

      // Payload order, not alphabetical: Pain relief is drawn above Fever.
      final pain = t.getTopLeft(find.text('Pain relief').first).dy;
      final fever = t.getTopLeft(find.text('Fever').first).dy;
      final cold = t.getTopLeft(find.text('Cough & cold').first).dy;
      expect(pain, lessThan(fever));
      expect(fever, lessThan(cold));
    });

    testWidgets('2 · a tap carries the phrase to catalogue_list untouched',
        (t) async {
      final rpc = await _pumpPhone(t, {
        'catalogue_conditions': [_conditions()],
        'catalogue_list': [_list()],
      });

      await t.tap(find.text('Pain relief').first);
      await t.pumpAndSettle();

      final a = rpc.lastArgs('catalogue_list');
      expect(a['p_kind'], 'condition');
      // Verbatim — the space and the capital are part of the key.
      expect(a['p_key'], 'Pain relief');
    });

    testWidgets('3 · an ampersand phrase survives the tap too', (t) async {
      final rpc = await _pumpPhone(t, {
        'catalogue_conditions': [_conditions()],
        'catalogue_list': [_list()],
      });

      await t.tap(find.text('Cough & cold').first);
      await t.pumpAndSettle();

      expect(rpc.lastArgs('catalogue_list')['p_key'], 'Cough & cold');
    });

    testWidgets('4 · an empty door draws the backend sentence, not a blank',
        (t) async {
      await _pumpPhone(t, {
        'catalogue_conditions': [_conditions(rows: const [])],
      });

      expect(find.text('No use matches this search.'), findsWidgets);
    });

  });

  group('a phrase key is a deep link', () {
    test('6 · url -> parse -> url keeps the phrase exactly', () {
      const r = CatalogueRoute(
          tab: 'conditions', listKind: 'condition', listKey: 'Cough & cold');
      final url = r.url;

      // Encoded in the link — a raw '&' would end the query parameter.
      expect(url.contains('Cough & cold'), isFalse);

      final back = CatalogueRoute.parse(url.substring(url.indexOf('?')));
      expect(back.listKind, 'condition');
      expect(back.listKey, 'Cough & cold');
      expect(back.url, url);
    });

    test('7 · a phrase with a space round-trips as one key', () {
      const r = CatalogueRoute(
          tab: 'conditions', listKind: 'condition', listKey: 'Pain relief');
      final back = CatalogueRoute.parse(r.url.substring(r.url.indexOf('?')));
      expect(back.listKey, 'Pain relief');
    });
  });
}
