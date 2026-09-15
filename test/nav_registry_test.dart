// CHANGE #325 — the dashboard nav renders the registry, and computes nothing.
//
// The bug class this retires: a feature ships, nobody adds it to the dashboard,
// and it ends up in the profile dropdown — thirty deep — because the dropdown
// was the only list anyone remembered to edit. The fix is that the dashboard's
// nav IS `nav_registry()`, so these tests hold down the ONE property that makes
// that true: every label, category, order, count and phrase on screen came out
// of the payload, and nothing on screen was decided here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/command_palette.dart';
import 'package:pharma_b2b/screens/admin/nav_registry_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _tile(
  String key,
  String label, {
  String icon = 'receipt',
  String route = 'r',
  int? count,
  String? badgeLabel,
  bool pinned = false,
}) =>
    <String, dynamic>{
      'feature_key': key,
      'label': label,
      'icon_key': icon,
      'route_key': route,
      'deep_link': '/admin/go/$route',
      'badge_count': count,
      'badge_label': badgeLabel,
      'pinned': pinned,
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('action tiles', () {
    testWidgets('the phrase under the number is the backend string, verbatim',
        (tester) async {
      await tester.pumpWidget(_host(NavActionTiles(
        tiles: [
          _tile('admin.bill_pipeline', 'Bill pipeline',
              count: 10, badgeLabel: '10 bills to review'),
          _tile('admin.order_closure', 'Order closure',
              count: 7, badgeLabel: '7 pending orders'),
        ],
        emptyLabel: 'nothing',
        onOpen: (_) {},
      )));

      // The count and the noun are ONE backend string. Nothing here pluralises
      // "bill" or re-derives "10" — a Dart-built phrase would read
      // "10 Bill pipeline" and this expectation would fail.
      expect(find.text('10 bills to review'), findsOneWidget);
      expect(find.text('7 pending orders'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      expect(find.text('Bill pipeline'), findsNothing);
    });

    testWidgets('no counted feature -> the backend empty state, not a blank',
        (tester) async {
      await tester.pumpWidget(_host(NavActionTiles(
        tiles: const [],
        emptyLabel: 'Nothing needs your attention right now.',
        onOpen: (_) {},
      )));
      expect(find.text('Nothing needs your attention right now.'),
          findsOneWidget);
    });

    testWidgets('a tap hands back the backend row untouched', (tester) async {
      Map<String, dynamic>? got;
      await tester.pumpWidget(_host(NavActionTiles(
        tiles: [
          _tile('admin.bill_pipeline', 'Bill pipeline',
              route: 'bill_pipeline', count: 3, badgeLabel: '3 bills to review')
        ],
        emptyLabel: '',
        onOpen: (t) => got = t,
      )));
      await tester.tap(find.text('3 bills to review'));
      expect(got?['route_key'], 'bill_pipeline');
      expect(got?['feature_key'], 'admin.bill_pipeline');
      expect(got?['deep_link'], '/admin/go/bill_pipeline');
    });
  });

  group('sections', () {
    List<Map<String, dynamic>> sections() => [
          {
            'category_key': 'money',
            'label': 'Money',
            'icon_key': 'rupee',
            // Deliberately NOT alphabetical: the backend already ranked these
            // (pinned, then most-opened, then sort_order) and the app must not
            // re-sort them.
            'items': [
              _tile('admin.gst', 'GST'),
              _tile('admin.bill_pipeline', 'Bill pipeline'),
            ],
          },
          {
            'category_key': 'comms',
            'label': 'Communication',
            'icon_key': 'forum',
            'items': [_tile('admin.wa_ops', 'WhatsApp Ops')],
          },
        ];

    testWidgets('categories and items render in payload order', (tester) async {
      await tester.pumpWidget(_host(SingleChildScrollView(
        child: NavSections(
          sections: sections(),
          pinned: const [],
          pinnedLabel: 'Pinned',
          pinHint: 'Long-press a tile to pin it',
          onOpen: (_) {},
          onPin: (_) async => const {},
        ),
      )));

      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('Money'), lessThan(y('Communication')));
      // The two Money tiles sit on one Wrap row, so payload order is left-to-
      // right here, not top-to-bottom.
      expect(tester.getTopLeft(find.text('GST')).dx,
          lessThan(tester.getTopLeft(find.text('Bill pipeline')).dx));
      expect(find.text('Long-press a tile to pin it'), findsOneWidget);
    });

    testWidgets('an empty section is skipped silently (forward compat)',
        (tester) async {
      await tester.pumpWidget(_host(SingleChildScrollView(
        child: NavSections(
          sections: [
            {
              'category_key': 'ghost',
              'label': 'Not Built Yet',
              'icon_key': 'x',
              'items': const [],
            },
            ...sections(),
          ],
          pinned: const [],
          pinnedLabel: 'Pinned',
          pinHint: '',
          onOpen: (_) {},
          onPin: (_) async => const {},
        ),
      )));
      expect(find.text('Not Built Yet'), findsNothing);
      expect(find.text('Money'), findsOneWidget);
    });

    testWidgets('a section collapses and its items go with it', (tester) async {
      await tester.pumpWidget(_host(SingleChildScrollView(
        child: NavSections(
          sections: sections(),
          pinned: const [],
          pinnedLabel: 'Pinned',
          pinHint: '',
          onOpen: (_) {},
          onPin: (_) async => const {},
        ),
      )));
      expect(find.text('GST'), findsOneWidget);
      await tester.tap(find.text('Money'));
      await tester.pumpAndSettle();
      expect(find.text('GST'), findsNothing);
      // The heading stays — collapsing hides the features, not the category.
      expect(find.text('Money'), findsOneWidget);
    });

    testWidgets('pinned tiles get their own block above the categories',
        (tester) async {
      await tester.pumpWidget(_host(SingleChildScrollView(
        child: NavSections(
          sections: sections(),
          pinned: [_tile('admin.gst', 'GST', pinned: true)],
          pinnedLabel: 'Pinned',
          pinHint: '',
          onOpen: (_) {},
          onPin: (_) async => const {},
        ),
      )));
      expect(find.text('Pinned'), findsOneWidget);
      expect(
          tester.getTopLeft(find.text('Pinned')).dy,
          lessThan(tester.getTopLeft(find.text('Money')).dy));
      // GST appears twice: once pinned at the top, once in its own category.
      expect(find.text('GST'), findsNWidgets(2));
    });

    testWidgets('long-press pins, and the toast is the RPC message',
        (tester) async {
      String? asked;
      await tester.pumpWidget(_host(SingleChildScrollView(
        child: NavSections(
          sections: sections(),
          pinned: const [],
          pinnedLabel: 'Pinned',
          pinHint: '',
          onOpen: (_) {},
          onPin: (k) async {
            asked = k;
            return {'ok': true, 'pinned': true, 'message': 'Pinned to the top.'};
          },
        ),
      )));
      await tester.longPress(find.text('GST'));
      await tester.pump();
      expect(asked, 'admin.gst');
      expect(find.text('Pinned to the top.'), findsOneWidget);
    });
  });

  group('command palette', () {
    testWidgets('renders the backend groups and returns the row on tap',
        (tester) async {
      Map<String, dynamic>? picked;
      await tester.pumpWidget(_host(CommandPaletteSheet(
        hint: 'Search…',
        title: 'Jump to…',
        onPick: (i) => picked = i,
        search: (q) async => {
          'ok': true,
          'query': q,
          'groups': [
            {
              'key': 'screens',
              'label': 'Screens',
              'items': [
                {
                  'kind': 'screen',
                  'title': 'GST',
                  'subtitle': 'Money',
                  'icon_key': 'account_balance',
                  'route_key': 'gst',
                  'feature_key': 'admin.gst',
                }
              ],
            },
            {
              'key': 'customers',
              'label': 'Customers',
              'items': [
                {
                  'kind': 'customer',
                  'title': 'Sharma Medicals',
                  'subtitle': 'Raipur',
                  'icon_key': 'people',
                  'route_key': 'customers',
                  'seed': 'Sharma Medicals',
                }
              ],
            },
          ],
          'empty_label': 'nope',
        },
      )));

      await tester.enterText(find.byType(TextField), 'gst');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('Screens'), findsOneWidget);
      expect(find.text('Customers'), findsOneWidget);
      // A customer name lands on the customer screen — their orders — carrying
      // the seed the backend chose.
      await tester.tap(find.text('Sharma Medicals'));
      expect(picked?['route_key'], 'customers');
      expect(picked?['seed'], 'Sharma Medicals');
    });

    testWidgets('a slow earlier reply never overwrites a newer one',
        (tester) async {
      await tester.pumpWidget(_host(CommandPaletteSheet(
        hint: '',
        title: '',
        onPick: (_) {},
        search: (q) async {
          // "ab" answers late; "abc" answers immediately. The sheet must end up
          // showing "abc".
          if (q == 'ab') {
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          return {
            'ok': true,
            'groups': [
              {'key': 'k', 'label': 'for $q', 'items': const []}
            ],
            'empty_label': '',
          };
        },
      )));

      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pump(const Duration(milliseconds: 260));
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(find.text('for abc'), findsOneWidget);
      expect(find.text('for ab'), findsNothing);
    });

    testWidgets('nothing matched -> the backend copy, not a Dart sentence',
        (tester) async {
      await tester.pumpWidget(_host(CommandPaletteSheet(
        hint: '',
        title: '',
        onPick: (_) {},
        search: (_) async => {
          'ok': true,
          'groups': const [],
          'empty_label': 'Nothing matched. Try an order code.',
        },
      )));
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Nothing matched. Try an order code.'), findsOneWidget);
    });
  });

  group('icon mapping', () {
    test('an unregistered icon_key falls back instead of throwing', () {
      expect(navIcon('a_key_shipped_after_this_build'), Icons.widgets_outlined);
      expect(navIcon(null), Icons.widgets_outlined);
      expect(navIcon('terminal'), Icons.terminal);
    });
  });
}
