// PROTECTED — CMD #1893.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the Dashboard's personal rows, never to make an
// unrelated change go green.
//
// What this holds down — Quick actions and Recently used are the SAME payload
// the six sections come in, and every decision about them is the backend's:
//
//   1. ONE dashboard_home() read feeds both rows AND the sections under them.
//      DashboardHomeFeed holds the answer; two widgets asking is still one
//      round trip. Two answers would let a pinned tile disagree with the
//      section tile it was pinned from.
//
//   2. Quick actions draws the pins in PAYLOAD ORDER at the payload's own
//      column count. 4-across is `quick.columns`, not a number in Dart.
//
//   3. Empty pins print `quick.empty_label` VERBATIM ("Long-press any tile to
//      pin it here") and no grid. The string is never spelled in Dart.
//
//   4. Recently used hides itself when the payload sent no items and
//      `show_when_empty: false` — the widget does not decide that — and when it
//      does print, it prints the payload's order, newest first, untouched.
//
//   5. Long-press prints the HELD TILE's own `pin_action_label`. Pin vs Unpin
//      is a backend string chosen from `pinned`; Dart never picks between two
//      words. Confirming calls nav_pin_toggle with that tile's feature_key and
//      shows the reply's `message` verbatim as the toast.
//
//   6. A toggle invalidates the feed exactly once, so both rows re-read the
//      new truth rather than patching a local list.
//
//   7. ok:false renders nothing rather than throwing.
//
// Fixture mirrors a real dashboard_home() reply taken off the build branch on
// 2026-09-08. No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/dashboard_home_sections.dart';
import 'package:pharma_b2b/widgets/dashboard_quick_actions.dart';

const String kQuickEmpty = 'Long-press any tile to pin it here';
const String kPin = 'Pin to Quick actions';
const String kUnpin = 'Remove from Quick actions';

Map<String, dynamic> _tile(String key, String label,
        {bool pinned = false, int badge = 0}) =>
    {
      'feature_key': key,
      'label': label,
      'icon_key': 'rule',
      'icon_letter': label.substring(0, 1).toUpperCase(),
      'route_key': key.split('.').last,
      'deep_link': null,
      'tool_key': null,
      'tab_host': null,
      'tab_key': null,
      'description': '',
      'badge_count': badge,
      'badge_label': null,
      'badge_tone': 'info',
      'pinned': pinned,
      'pin_action_label': pinned ? kUnpin : kPin,
    };

Map<String, dynamic> _payload({
  List<Map<String, dynamic>> quick = const [],
  List<Map<String, dynamic>> recent = const [],
  bool ok = true,
}) =>
    {
      'ok': ok,
      'title': 'All your work',
      'pin_label': kPin,
      'unpin_label': kUnpin,
      'quick': {
        'key': 'quick',
        'label': 'QUICK ACTIONS',
        'empty_label': kQuickEmpty,
        'show_when_empty': true,
        'columns': 4,
        'items': quick,
      },
      'recent': {
        'key': 'recent',
        'label': 'RECENTLY USED',
        'empty_label': '',
        'show_when_empty': false,
        'items': recent,
      },
      'sections': const [],
      'items_count': 0,
    };

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 390, child: child),
      ),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('CMD #1893 — Quick actions', () {
    testWidgets('pins render in payload order at the payload column count',
        (tester) async {
      final p = _payload(quick: [
        _tile('admin.companies', 'Company registrations', pinned: true),
        _tile('admin.bags', 'Bags', pinned: true),
        _tile('admin.mr', 'MR', pinned: true),
      ]);
      await tester.pumpWidget(_host(DashboardPersonalRows(
        load: () async => p,
        onOpen: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('QUICK ACTIONS'), findsOneWidget);
      expect(find.byKey(const Key('c1893_quick_grid')), findsOneWidget);
      expect(find.byKey(const Key('c1893_quick_empty')), findsNothing);

      // Payload order, not alphabetical: "Company registrations" is first even
      // though "Bags" sorts before it.
      final labels = tester
          .widgetList<Text>(find.descendant(
            of: find.byKey(const Key('c1893_quick_grid')),
            matching: find.byType(Text),
          ))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(labels, ['Company registrations', 'Bags', 'MR']);

      // 4 across is the payload's `columns`, so on a 390px host each tile is a
      // quarter of the width (minus the three 12px gaps) — never the responsive
      // 3-across a phone-width section grid would use.
      final grid =
          tester.widget<DashboardTileGrid>(find.byType(DashboardTileGrid));
      expect(grid.columns, 4);
      expect(dashboardTileColumns(390), isNot(4));
    });

    testWidgets('no pins prints the backend empty line and no grid',
        (tester) async {
      await tester.pumpWidget(_host(DashboardPersonalRows(
        load: () async => _payload(),
        onOpen: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('c1893_quick_empty')), findsOneWidget);
      expect(find.text(kQuickEmpty), findsOneWidget);
      expect(find.byKey(const Key('c1893_quick_grid')), findsNothing);
    });
  });

  group('CMD #1893 — Recently used', () {
    testWidgets('hidden when the payload sent none', (tester) async {
      await tester.pumpWidget(_host(DashboardPersonalRows(
        load: () async => _payload(),
        onOpen: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('RECENTLY USED'), findsNothing);
      expect(find.byKey(const Key('c1893_recent_strip')), findsNothing);
    });

    testWidgets('prints the payload order, newest first, untouched',
        (tester) async {
      final p = _payload(recent: [
        _tile('admin.mr', 'MR'),
        _tile('admin.bags', 'Bags'),
        _tile('admin.companies', 'Company registrations'),
      ]);
      await tester.pumpWidget(_host(DashboardPersonalRows(
        load: () async => p,
        onOpen: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('c1893_recent_strip')), findsOneWidget);
      final strip = tester
          .widgetList<DashboardHomeTile>(find.descendant(
            of: find.byKey(const Key('c1893_recent_strip')),
            matching: find.byType(DashboardHomeTile),
          ))
          .map((t) => t.tile['feature_key'])
          .toList();
      expect(strip, ['admin.mr', 'admin.bags', 'admin.companies']);
    });

    testWidgets('a tap hands back the backend map untouched', (tester) async {
      Map<String, dynamic>? opened;
      await tester.pumpWidget(_host(DashboardPersonalRows(
        load: () async => _payload(recent: [_tile('admin.mr', 'MR')]),
        onOpen: (t) => opened = t,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('c1891_tile_admin.mr')));
      expect(opened?['feature_key'], 'admin.mr');
      expect(opened?['route_key'], 'mr');
    });
  });

  group('CMD #1893 — Pin / Unpin is a backend string', () {
    testWidgets('the sheet prints the held tile own pin_action_label',
        (tester) async {
      late Map<String, dynamic> held;
      final p = _payload(quick: [
        _tile('admin.companies', 'Company registrations', pinned: true),
      ], recent: [
        _tile('admin.mr', 'MR'),
      ]);
      await tester.pumpWidget(_host(DashboardPersonalRows(
        load: () async => p,
        onOpen: (_) {},
        onHold: (t) => held = t,
      )));
      await tester.pumpAndSettle();

      // A pinned tile offers the UNPIN wording…
      await tester
          .longPress(find.byKey(const Key('c1891_tile_admin.companies')));
      await tester.pump();
      expect(held['pin_action_label'], kUnpin);

      // …and an unpinned one the PIN wording. Both came off the payload.
      await tester.longPress(find.byKey(const Key('c1891_tile_admin.mr')));
      await tester.pump();
      expect(held['pin_action_label'], kPin);
    });

    testWidgets('confirming toggles that feature and toasts the reply verbatim',
        (tester) async {
      String? toggled;
      final tile = _tile('admin.mr', 'MR');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showDashboardPinSheet(ctx, tile, (key) async {
                toggled = key;
                return {
                  'ok': true,
                  'pinned': true,
                  'message': 'Pinned to Quick actions.',
                };
              }),
              child: const Text('hold'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('hold'));
      await tester.pumpAndSettle();

      // The sheet's one line is the tile's string, spelled nowhere in Dart.
      expect(find.byKey(const Key('c1893_pin_action')), findsOneWidget);
      expect(find.text(kPin), findsOneWidget);

      await tester.tap(find.byKey(const Key('c1893_pin_action')));
      await tester.pumpAndSettle();

      expect(toggled, 'admin.mr');
      expect(find.text('Pinned to Quick actions.'), findsOneWidget);
    });

    testWidgets('dismissing the sheet toggles nothing', (tester) async {
      var calls = 0;
      final tile = _tile('admin.mr', 'MR');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showDashboardPinSheet(ctx, tile, (key) async {
                calls++;
                return const {'ok': true};
              }),
              child: const Text('hold'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('hold'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byKey(const Key('c1893_pin_action'))))
          .pop();
      await tester.pumpAndSettle();
      expect(calls, 0);
    });
  });

  group('CMD #1893 — one read, two rows', () {
    testWidgets('the feed answers both widgets from a single call',
        (tester) async {
      var reads = 0;
      final feed = DashboardHomeFeed(() async {
        reads++;
        return _payload(quick: [_tile('admin.mr', 'MR', pinned: true)]);
      });
      addTearDown(feed.dispose);

      await tester.pumpWidget(_host(Column(children: [
        DashboardPersonalRows(
            load: feed.read, onOpen: (_) {}, revision: feed.revision),
        DashboardHomeSections(
            load: feed.read, onOpen: (_) {}, revision: feed.revision),
      ])));
      await tester.pumpAndSettle();
      expect(reads, 1);

      // A pin toggle drops the held answer: exactly one more round trip, and
      // both rows redraw from it.
      feed.invalidate();
      await tester.pumpAndSettle();
      expect(reads, 2);
    });

    testWidgets('ok:false renders nothing rather than throwing',
        (tester) async {
      await tester.pumpWidget(_host(DashboardPersonalRows(
        load: () async => _payload(ok: false),
        onOpen: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('c1893_personal_rows')), findsNothing);
      expect(find.text('QUICK ACTIONS'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
