// PROTECTED — CMD #1892, the Dashboard home LAYOUT.
//
// #1891 held down what the sections MEAN (payload order, show_when_empty, the
// badge's tone). This file holds down the SHAPE #1892 gave them, because the
// shape is where a redesign quietly re-introduces client-side decisions:
//
//   1. needs_now is drawn as full-width ROWS with a 4px bar in the payload's
//      own tone — red for a breach ('bad'), amber for due-soon ('warn') — and
//      the count on the right. Every other section is a TILE GRID. Which shape
//      a section gets is its `key`, not its position in the list.
//
//   2. The grid is 3 across on a phone, 5 on a tablet, 6 on a desktop, and the
//      tile stays an 88pt square at every one of them.
//
//   3. A badge exists only when the payload sent a count; it is never a "0",
//      never pluralised in Dart, and on a tile it is the one red thing.
//
//   4. The search field is nav_search() and nothing else: it renders the
//      payload's groups, in payload order, with the payload's own labels and
//      empty line, and hands the chosen row back untouched.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/dashboard_home_sections.dart';
import 'package:pharma_b2b/widgets/dashboard_nav_search.dart';

Map<String, dynamic> _tile({
  required String key,
  required String label,
  int badge = 0,
  String tone = 'info',
  String? badgeLabel,
}) =>
    {
      'feature_key': key,
      'label': label,
      'icon_key': 'rule',
      'icon_letter': label.substring(0, 1).toUpperCase(),
      'route_key': 'somewhere',
      'deep_link': null,
      'tool_key': null,
      'tab_host': null,
      'tab_key': null,
      'description': '',
      'badge_count': badge,
      'badge_label': badgeLabel,
      'badge_tone': tone,
    };

Map<String, dynamic> _payload(List<Map<String, dynamic>> sections) => {
      'ok': true,
      'title': 'All your work',
      'empty_label': 'Nothing is open to you here yet.',
      'needs_now_empty': 'Nothing needs you right now.',
      'sections': sections,
      'items_count': sections.fold<int>(
          0, (n, s) => n + (s['items'] as List).length),
    };

Map<String, dynamic> _section(
  String key,
  String label,
  List<Map<String, dynamic>> items, {
  bool showWhenEmpty = false,
}) =>
    {
      'key': key,
      'label': label,
      'show_when_empty': showWhenEmpty,
      'empty_label': 'Nothing here for this login.',
      'items': items,
    };

/// A breach, a due-soon, and six plain doors.
Map<String, dynamic> _busy() => _payload([
      _section('needs_now', 'NEEDS YOU NOW', [
        _tile(
            key: 'admin.breach',
            label: 'SLA breached',
            badge: 4,
            tone: 'bad',
            badgeLabel: '4 breached'),
        _tile(
            key: 'admin.due_soon',
            label: 'Due in an hour',
            badge: 2,
            tone: 'warn',
            badgeLabel: '2 due soon'),
      ]),
      _section('onboarding', 'ONBOARDING', [
        for (var i = 0; i < 6; i++)
          _tile(key: 'admin.door$i', label: 'Door $i'),
      ]),
    ]);

Future<void> _pumpSections(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  double width = 390,
  void Function(Map<String, dynamic>)? onOpen,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(
            child: DashboardHomeSections(
              load: () async => payload,
              onOpen: onOpen ?? (_) {},
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('CMD #1892 — needs you now is rows, everything else is a grid', () {
    testWidgets('the needs-now row wears the payload\'s tone on a 4px bar',
        (tester) async {
      await _pumpSections(tester, _busy());

      // The bar is a 4-wide Container filled with the tone the tile carried:
      // red for the breach, amber for the due-soon. Nothing here reads the
      // section name to pick a colour.
      final bars = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.constraints?.maxWidth == Ds.space.x4)
          .toList();
      final colors = [
        for (final b in bars) (b.color ?? (b.decoration as BoxDecoration?)?.color)
      ];
      expect(colors, contains(DashboardHomeTile.toneColor('bad')));
      expect(colors, contains(DashboardHomeTile.toneColor('warn')));
    });

    testWidgets('a needs-now count prints on the right of its own row, and a '
        'phrase never becomes a Dart plural', (tester) async {
      await _pumpSections(tester, _busy());

      expect(find.text('4'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('4 breached'), findsOneWidget);
      expect(find.text('2 due soon'), findsOneWidget);

      // Right of the label, on the same row.
      final label = tester.getTopLeft(find.text('SLA breached'));
      final count = tester.getTopLeft(find.text('4'));
      expect(count.dx, greaterThan(label.dx));
    });

    testWidgets('3 across on a phone, 5 on a tablet, 6 on a desktop — and the '
        'tile stays square', (tester) async {
      expect(dashboardTileColumns(390), 3);
      expect(dashboardTileColumns(768), 5);
      expect(dashboardTileColumns(1100), 6);

      await tester.binding.setSurfaceSize(const Size(1200, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpSections(tester, _busy(), width: 1100);

      final tile = tester.getSize(
          find.byKey(const Key('c1891_tile_admin.door0')));
      expect(tile.height, dashboardTileSide);
      expect(tile.width,
          moreOrLessEquals(dashboardTileWidth(1100, Ds.space.x12), epsilon: 0.5));
    });

    testWidgets('a tile with no count has no badge at all', (tester) async {
      await _pumpSections(tester, _busy());
      // Six plain doors, no badge text among them.
      expect(find.text('0'), findsNothing);
      expect(find.text('Door 0'), findsOneWidget);
    });

    testWidgets('a grid tile still hands the backend\'s map back untouched',
        (tester) async {
      final opened = <Map<String, dynamic>>[];
      await _pumpSections(tester, _busy(), onOpen: opened.add);
      await tester.tap(find.byKey(const Key('c1891_tile_admin.door3')));
      await tester.pump();
      expect(opened.single['feature_key'], 'admin.door3');
      expect(opened.single['route_key'], 'somewhere');
    });

    testWidgets('an empty needs_now with show_when_empty false takes its '
        'header with it', (tester) async {
      await _pumpSections(
          tester,
          _payload([
            _section('needs_now', 'NEEDS YOU NOW', const []),
            _section('onboarding', 'ONBOARDING', [
              _tile(key: 'admin.door0', label: 'Door 0'),
            ]),
          ]));
      expect(find.text('NEEDS YOU NOW'), findsNothing);
      expect(find.text('ONBOARDING'), findsOneWidget);
    });
  });

  group('CMD #1892 — the search field is nav_search() and nothing else', () {
    Future<void> pumpField(
      WidgetTester tester, {
      required Future<Map<String, dynamic>> Function(String) search,
      void Function(Map<String, dynamic>)? onPick,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DashboardNavSearchField(
              search: search,
              onPick: onPick ?? (_) {},
              hint: 'Search screens, orders, customers, suppliers, products',
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Map<String, dynamic> reply() => {
          'ok': true,
          'query': 'gst',
          'groups': [
            {
              'key': 'screens',
              'label': 'Screens',
              'items': [
                {
                  'kind': 'screen',
                  'title': 'GST ledger',
                  'subtitle': 'Money',
                  'icon_key': 'rule',
                  'icon_letter': 'G',
                  'route_key': 'gst',
                  'deep_link': null,
                  'feature_key': 'admin.gst',
                  'seed': null,
                },
              ],
            },
            {
              'key': 'medicines',
              'label': 'Medicines',
              'items': [
                {
                  'kind': 'medicine',
                  'title': 'Gestone 100mg',
                  'subtitle': 'Ferring',
                  'icon_key': 'medication',
                  'icon_letter': 'M',
                  'route_key': 'search',
                  'deep_link': null,
                  'feature_key': null,
                  'seed': 'Gestone 100mg',
                },
              ],
            },
          ],
          'empty_label': 'Nothing matched.',
        };

    testWidgets('nothing is asked, and nothing is drawn, until you type',
        (tester) async {
      var calls = 0;
      await pumpField(tester, search: (q) async {
        calls++;
        return reply();
      });
      expect(calls, 0);
      expect(find.byKey(const Key('c1892_search_results')), findsNothing);
    });

    testWidgets('groups print in payload order with the payload\'s labels',
        (tester) async {
      await pumpField(tester, search: (q) async => reply());
      await tester.enterText(find.byKey(const Key('c1892_search_field')), 'gst');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('Screens'), findsOneWidget);
      expect(find.text('Medicines'), findsOneWidget);
      expect(find.text('GST ledger'), findsOneWidget);
      expect(find.text('Ferring'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Medicines')).dy,
          greaterThan(tester.getTopLeft(find.text('Screens')).dy));
    });

    testWidgets('an empty result prints the BACKEND\'s line', (tester) async {
      await pumpField(tester,
          search: (q) async =>
              {'ok': true, 'groups': const [], 'empty_label': 'Nothing matched.'});
      await tester.enterText(find.byKey(const Key('c1892_search_field')), 'zzz');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Nothing matched.'), findsOneWidget);
    });

    testWidgets('a pick hands back the row untouched and clears the field',
        (tester) async {
      final picked = <Map<String, dynamic>>[];
      await pumpField(tester, search: (q) async => reply(), onPick: picked.add);
      await tester.enterText(find.byKey(const Key('c1892_search_field')), 'gst');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      await tester.tap(find.text('GST ledger'));
      await tester.pumpAndSettle();

      expect(picked.single['feature_key'], 'admin.gst');
      expect(picked.single['route_key'], 'gst');
      expect(find.byKey(const Key('c1892_search_results')), findsNothing);
    });

    testWidgets('a failed search leaves the field standing', (tester) async {
      await pumpField(tester, search: (q) async => throw StateError('offline'));
      await tester.enterText(find.byKey(const Key('c1892_search_field')), 'gst');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('c1892_search_field')), findsOneWidget);
    });
  });
}
