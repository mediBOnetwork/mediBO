// PROTECTED — CMD #2056.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately moves the Routes doors again, never to make an unrelated change
// go green.
//
// Routes used to be ONE chip in the Customers chip row. It is now THREE tiles
// in the Dashboard's FIELD & GROWTH section — Route builder, Assign route,
// Today's visits — opening the SAME screen at three different sections. What
// this holds down:
//
//   1. The three doors are the payload's, in the payload's order, wearing the
//      payload's labels. The widget invents no tile and renames none: the
//      labels come from ui_copy through feature_registry.label_key, so
//      renaming a door is an UPDATE.
//
//   2. A tap hands the backend's own map back UNTOUCHED — `tab_host`
//      ('customers') and `tab_key` ('routes:<section>') included. The screen
//      never rewrites the pair.
//
//   3. `<tab>:<section>` is split, not interpreted: everything before the
//      first colon is the sub-tab, everything after it the section. No colon =
//      a plain sub-tab (every other tile in the app). This is the whole of
//      what Dart decides about a destination.
//
//   4. Which part of the Routes screen a section names is a four-row table,
//      and a key this build has never heard of resolves to NOTHING rather than
//      guessing — so a fourth door added in Postgres degrades to "the tab
//      opens on its own landing mode" instead of throwing.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/customer_tab_target.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/dashboard_home_sections.dart';

Map<String, dynamic> _tile({
  required String key,
  required String label,
  required String tabKey,
  required String route,
}) =>
    {
      'feature_key': key,
      'label': label,
      'icon_key': 'rule',
      'icon_letter': label.substring(0, 1).toUpperCase(),
      'route_key': route,
      'deep_link': null,
      'tool_key': null,
      'tab_host': 'customers',
      'tab_key': tabKey,
      'description': '',
      'badge_count': 0,
      'badge_label': null,
      'badge_tone': 'info',
    };

/// FIELD & GROWTH exactly as `dashboard_home()` sends it after #2056: S Leads
/// first (sort 160), then the three Routes doors (170/171/172). Deliberately
/// NOT alphabetical — "Assign route" would sort before "Route builder".
Map<String, dynamic> _fieldGrowth() => {
      'ok': true,
      'title': 'All your work',
      'empty_label': 'Nothing is open to you here yet.',
      'needs_now_empty': 'Nothing needs you right now.',
      'sections': [
        {
          'key': 'field_growth',
          'label': 'FIELD & GROWTH',
          'show_when_empty': false,
          'empty_label': 'Nothing here for this login.',
          'items': [
            _tile(
                key: 'admin.cust_tab.s_leads',
                label: 'S Leads',
                tabKey: 'sLeads',
                route: 'cust_s_leads'),
            _tile(
                key: 'admin.cust_tab.routes_builder',
                label: 'Route builder',
                tabKey: 'routes:all_plans',
                route: 'cust_routes_builder'),
            _tile(
                key: 'admin.cust_tab.routes_assign',
                label: 'Assign route',
                tabKey: 'routes:past_plans',
                route: 'cust_routes_assign'),
            _tile(
                key: 'admin.cust_tab.routes_today',
                label: "Today's visits",
                tabKey: 'routes:today',
                route: 'cust_routes_today'),
          ],
        },
      ],
      'items_count': 4,
    };

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  void Function(Map<String, dynamic>)? onOpen,
  double width = 360,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: DashboardHomeSections(
          load: () async => payload,
          onOpen: onOpen ?? (_) {},
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('CMD #2056 — Routes is three Dashboard doors, not a Customers chip',
      () {
    testWidgets('all three doors print, in payload order, with the payload\'s '
        'own labels', (tester) async {
      await _pump(tester, _fieldGrowth());

      expect(find.text('FIELD & GROWTH'), findsOneWidget);
      const order = [
        'S Leads',
        'Route builder',
        'Assign route',
        "Today's visits",
      ];
      for (final label in order) {
        expect(find.text(label), findsOneWidget, reason: 'missing $label');
      }
      // Payload order. Alphabetical would put "Assign route" first.
      final ys = [
        for (final label in order) tester.getTopLeft(find.text(label)).dy,
      ];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThanOrEqualTo(ys[i - 1]),
            reason: '${order[i]} must not print before ${order[i - 1]}');
      }
    });

    testWidgets('a tap hands back the backend\'s own map, tab pair untouched',
        (tester) async {
      final opened = <Map<String, dynamic>>[];
      await _pump(tester, _fieldGrowth(), onOpen: opened.add);

      for (final label in ['Route builder', 'Assign route', "Today's visits"]) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      expect(opened.map((t) => t['tab_host']).toList(),
          ['customers', 'customers', 'customers']);
      expect(opened.map((t) => t['tab_key']).toList(),
          ['routes:all_plans', 'routes:past_plans', 'routes:today']);
      expect(opened.map((t) => t['feature_key']).toList(), [
        'admin.cust_tab.routes_builder',
        'admin.cust_tab.routes_assign',
        'admin.cust_tab.routes_today',
      ]);
    });

    test('a destination is SPLIT, never interpreted', () {
      final b = CustomerTabTarget.parse('routes:all_plans');
      expect(b.tab, 'routes');
      expect(b.section, 'all_plans');
      expect(b.hasSection, isTrue);

      // Every other tile in the app: a plain sub-tab, no section.
      final plain = CustomerTabTarget.parse('sLeads');
      expect(plain.tab, 'sLeads');
      expect(plain.section, '');
      expect(plain.hasSection, isFalse);

      // Absent / blank / section-only are all "no destination", never a crash.
      expect(CustomerTabTarget.parse(null).tab, '');
      expect(CustomerTabTarget.parse('   ').tab, '');
      expect(CustomerTabTarget.parse(':today').tab, '');

      // Only the FIRST colon splits, so a section key may contain one.
      final deep = CustomerTabTarget.parse('routes:a:b');
      expect(deep.tab, 'routes');
      expect(deep.section, 'a:b');
    });

    test('the section table names a mode; an unknown key names nothing', () {
      expect(kRoutesSectionModes['today'], 'today');
      expect(kRoutesSectionModes['all_plans'], 'builder');
      // Assign route lands in the builder too — with Past plans open.
      expect(kRoutesSectionModes['past_plans'], 'builder');
      expect(kRoutesSectionModes['my_route'], 'myRoute');
      // A door added in Postgres that this build predates is IGNORED.
      expect(kRoutesSectionModes['a_door_from_the_future'], isNull);
    });
  });
}
