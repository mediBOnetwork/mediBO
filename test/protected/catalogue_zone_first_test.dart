// PROTECTED — CMD #2088: the drill-down list matches the tile.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change go
// green.
//
// The bug this retires: the Browse-by tiles said "18,563 companies" and the
// company list under them said the same thing, and neither number was about
// the zone the viewer can actually buy from. The tile is zone-scoped now, and
// the list has to agree with it or the tile is a lie one tap deep.
//
// What this file holds down:
//
//   1. THE HEADER COUNT IS THE PAYLOAD'S, AND IT IS THE TILE'S NUMBER. The
//      list prints `count_label` verbatim — it never counts the rows it was
//      handed, which are one page of a longer list.
//   2. THE GROUP DIVIDER IS A ROW'S OWN STRING. `cat_group_label()` writes
//      "Available in your zone (5)" and "Not available in your zone (193)" and
//      puts each on the FIRST row of its group. The app prints whatever
//      arrived, above that row, and decides nothing: it does not sort, does
//      not group, does not count and does not know which group is which.
//   3. NO DIVIDER WHEN THE BACKEND SENT NONE. A viewer with no zone (a super
//      admin on "all zones", a visitor whose zone cache is not built) gets one
//      ungrouped list, because every `group_label` arrived empty.
//   4. ORDER IS THE PAYLOAD'S ORDER. Zone-available rows come first because
//      the backend sent them first, not because Dart moved them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/catalogue.dart';
import 'package:pharma_b2b/screens/catalogue_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

Map<String, dynamic> _zone() => {
      'has': true,
      'on': true,
      'label': 'Available in my zone',
      'zone_label': 'Raipur Zone',
      'note': 'Showing what suppliers in your zone can send.',
    };

Map<String, dynamic> _rail() => {
      'label': 'Jump to a letter',
      'all_label': 'All',
      'letters': [
        {'key': 'A', 'label': 'A', 'n': 1, 'enabled': true},
        {'key': 'C', 'label': 'C', 'n': 2, 'enabled': true},
      ],
    };

Map<String, dynamic> _row(String key, String label, String count,
        {String group = ''}) =>
    {
      'key': key,
      'label': label,
      'letter': label.substring(0, 1),
      'count_label': count,
      'group_label': group,
    };

Map<String, dynamic> _home() => {
      'ok': true,
      'title': 'Catalogue',
      'zone': _zone(),
      'doors_title': 'Browse by',
      'doors': [
        {
          'key': 'companies',
          'kind': 'companies',
          'tab': 'companies',
          'label': 'Company',
          'icon_key': 'store',
          'icon_letter': 'C',
          'count_label': 'Companies 5 available',
          'entity_label': 'Companies 5 available',
          'products_label': 'Products 88 available',
        },
      ],
      'tabs': <Map<String, dynamic>>[],
      'recent_viewed': {
        'has': false,
        'title': '',
        'items': <Map<String, dynamic>>[],
      },
      'trail': {'label': '', 'separator': '›', 'items': <Map<String, dynamic>>[]},
      'filters': {
        'groups': <Map<String, dynamic>>[],
        'sort': {'label': '', 'options': <Map<String, dynamic>>[]},
      },
    };

/// The company index exactly as `catalogue_companies()` now answers it: the
/// zone's own companies first, each group opened by the sentence the backend
/// wrote on its first row.
Map<String, dynamic> _companies({bool grouped = true}) => {
      'ok': true,
      'title': 'Companies',
      'zone': _zone(),
      'all_label': 'All',
      'rail': _rail(),
      'trail': {
        'label': 'You are here',
        'separator': '›',
        'items': [
          {'label': 'Catalogue', 'tab': 'browse', 'path': <String>[], 'current': false},
          {'label': 'Company', 'tab': 'companies', 'path': <String>[], 'current': true},
        ],
      },
      // The tile said "Companies 5 available"; this is the same 5.
      'count_label': grouped ? '5 companies' : '18,563 companies',
      'empty_label': 'No company matches this view.',
      'has_more': false,
      'next_offset': 3,
      'rows': grouped
          ? [
              _row('cipla health', 'CIPLA HEALTH LTD', '2 products',
                  group: 'Available in your zone (5)'),
              _row('cipla', 'CIPLA LTD', '26 products'),
              _row('a menarini india', 'A MENARINI INDIA PVT LTD', '3 products',
                  group: 'Not available in your zone (193)'),
            ]
          : [
              _row('abbott', 'ABBOTT', '1,204 products'),
              _row('cipla', 'CIPLA LTD', '2,110 products'),
            ],
    };

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
}

Future<_Rpc> _pump(
  WidgetTester tester, {
  required Map<String, List<Map<String, dynamic>>> queued,
  Size size = const Size(360, 900),
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
            initialRoute: const CatalogueRoute(tab: 'companies'),
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

  group('the model carries the group, it does not derive it', () {
    test('group_label round-trips and defaults to empty', () {
      final withGroup = CatRow.fromMap(
          _row('cipla', 'CIPLA LTD', '26 products', group: 'Available in your zone (5)'));
      expect(withGroup.groupLabel, 'Available in your zone (5)');

      // A payload from before CMD #2088 has no group_label at all. It must be
      // an absence, never a guess.
      final legacy = CatRow.fromMap(const {
        'key': 'abbott',
        'label': 'ABBOTT',
        'letter': 'A',
        'count_label': '1,204 products',
      });
      expect(legacy.groupLabel, '');
    });
  });

  group('the list matches the tile', () {
    testWidgets('the header count is the payload string, not a row count',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_companies': [_companies()],
      });
      // Three rows arrived; the header says 5, because the backend said 5 —
      // and 5 is exactly what the tile printed.
      expect(find.text('5 companies'), findsOneWidget);
      expect(find.text('3 companies'), findsNothing);
    });

    testWidgets('each group opens with the sentence the backend wrote',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_companies': [_companies()],
      });
      expect(find.text('Available in your zone (5)'), findsOneWidget);
      expect(find.text('Not available in your zone (193)'), findsOneWidget);
    });

    testWidgets('the divider sits above its own row, in payload order',
        (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_companies': [_companies()],
      });
      final y = (String s) => tester.getTopLeft(find.text(s)).dy;
      expect(y('Available in your zone (5)') < y('CIPLA HEALTH LTD'), isTrue);
      expect(y('CIPLA HEALTH LTD') < y('CIPLA LTD'), isTrue);
      expect(y('CIPLA LTD') < y('Not available in your zone (193)'), isTrue);
      expect(y('Not available in your zone (193)') <
              y('A MENARINI INDIA PVT LTD'),
          isTrue,
          reason: 'zone-available first is the ORDER the backend sent, and the '
              'divider belongs to the row that carried it');
    });

    testWidgets('no zone means no divider at all', (tester) async {
      await _pump(tester, queued: {
        'catalogue_home': [_home()],
        'catalogue_companies': [_companies(grouped: false)],
      });
      expect(find.text('18,563 companies'), findsOneWidget);
      expect(find.textContaining('in your zone'), findsNothing,
          reason: 'a super admin on all zones is handed one ungrouped list, '
              'and the app never invents a heading for it');
      expect(tester.takeException(), isNull);
    });
  });
}
