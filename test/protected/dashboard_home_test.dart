// PROTECTED — CMD #1891.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the Dashboard's section behaviour, never to make an
// unrelated change go green.
//
// What this holds down — the doors that used to hide in the "Also here" chip
// strip above Customers, Suppliers and Fulfill now live on the Dashboard, and
// EVERY decision about them belongs to `dashboard_home()`:
//
//   1. Sections render IN PAYLOAD ORDER with the payload's own labels. The
//      widget never sorts, re-titles, drops or reorders them — moving a tile
//      between sections is an UPDATE in Postgres, not a deploy.
//
//   2. needs_now ships only badged tiles (the backend filters), and it is the
//      ONE section that still prints when it is empty — because "nothing needs
//      you right now" is an answer. That is `show_when_empty`, a column, not a
//      Dart rule: a section with no items and show_when_empty false is skipped
//      silently, header and all.
//
//   3. A badge is the payload's: count, phrase and TONE. The widget never
//      counts, never pluralises, and never picks a colour by section name.
//
//   4. A tap hands the backend's OWN map back untouched, so a tile that names
//      a sub-tab of another page (`tab_host` / `tab_key`) can be routed by the
//      one handler that knows how to reach a host.
//
//   5. ok:false renders nothing rather than throwing, and a section list that
//      arrives with an unknown extra field is still drawn (forward compat).
//
// Fixture mirrors a real dashboard_home() response taken off the build branch.
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/dashboard_home_sections.dart';

Map<String, dynamic> _tile({
  required String key,
  required String label,
  int badge = 0,
  String tone = 'info',
  String? badgeLabel,
  String? tabHost,
  String? tabKey,
  String route = 'somewhere',
}) =>
    {
      'feature_key': key,
      'label': label,
      'icon_key': 'rule',
      'icon_letter': label.substring(0, 1).toUpperCase(),
      'route_key': route,
      'deep_link': null,
      'tool_key': null,
      'tab_host': tabHost,
      'tab_key': tabKey,
      'description': '',
      'badge_count': badge,
      'badge_label': badgeLabel,
      'badge_tone': tone,
    };

Map<String, dynamic> _section({
  required String key,
  required String label,
  required List<Map<String, dynamic>> items,
  bool showWhenEmpty = false,
  String emptyLabel = 'Nothing here for this login.',
}) =>
    {
      'key': key,
      'label': label,
      'show_when_empty': showWhenEmpty,
      'empty_label': emptyLabel,
      'items': items,
    };

Map<String, dynamic> _payload({
  required List<Map<String, dynamic>> sections,
  bool ok = true,
}) =>
    {
      'ok': ok,
      'title': 'All your work',
      'empty_label': 'Nothing is open to you here yet.',
      'needs_now_empty': 'Nothing needs you right now.',
      'sections': sections,
      'items_count': sections.fold<int>(
          0, (n, s) => n + (s['items'] as List).length),
    };

/// The six sections as the live RPC sends them for a super admin with one
/// pending-approval queue and nothing else outstanding.
Map<String, dynamic> _sixSections() => _payload(sections: [
      _section(
        key: 'needs_now',
        label: 'NEEDS YOU NOW',
        showWhenEmpty: true,
        emptyLabel: 'Nothing needs you right now.',
        items: [
          _tile(
              key: 'admin.cust_tab.pending',
              label: 'Pending Approval',
              badge: 5,
              tone: 'warn',
              badgeLabel: '5 to approve',
              tabHost: 'customers',
              tabKey: 'pendingRegistrations',
              route: 'cust_pending'),
        ],
      ),
      _section(key: 'onboarding', label: 'ONBOARDING', items: [
        _tile(key: 'admin.add_customer', label: 'Add customer'),
        _tile(key: 'admin.add_supplier', label: 'Add supplier'),
      ]),
      _section(key: 'field_growth', label: 'FIELD & GROWTH', items: [
        _tile(
            key: 'admin.cust_tab.s_leads',
            label: 'S Leads',
            tabHost: 'customers',
            tabKey: 'sLeads',
            route: 'cust_s_leads'),
      ]),
      _section(key: 'delivery', label: 'DELIVERY', items: [
        _tile(key: 'admin.delivery_waves', label: 'Delivery waves'),
      ]),
      _section(key: 'returns_issues', label: 'RETURNS & ISSUES', items: [
        _tile(key: 'admin.order_closure', label: 'Order closure'),
      ]),
      _section(key: 'my_work', label: 'MY WORK', items: [
        _tile(key: 'worker.my_tasks', label: 'My tasks'),
      ]),
    ]);

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  void Function(Map<String, dynamic>)? onOpen,
}) async {
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

  group('CMD #1891 — the Dashboard draws dashboard_home() and nothing else', () {
    testWidgets('six sections, in payload order, with the payload\'s labels',
        (tester) async {
      await _pump(tester, _sixSections());

      const order = [
        'NEEDS YOU NOW',
        'ONBOARDING',
        'FIELD & GROWTH',
        'DELIVERY',
        'RETURNS & ISSUES',
        'MY WORK',
      ];
      for (final label in order) {
        expect(find.text(label), findsOneWidget, reason: 'missing $label');
      }
      // Payload order, not alphabetical and not a Dart list.
      final ys = [
        for (final label in order)
          tester.getTopLeft(find.text(label)).dy,
      ];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]),
            reason: '${order[i]} must print after ${order[i - 1]}');
      }
    });

    testWidgets('needs_now prints its empty line; a plain empty section is '
        'skipped header and all', (tester) async {
      await _pump(
        tester,
        _payload(sections: [
          _section(
              key: 'needs_now',
              label: 'NEEDS YOU NOW',
              showWhenEmpty: true,
              emptyLabel: 'Nothing needs you right now.',
              items: const []),
          _section(
              key: 'onboarding',
              label: 'ONBOARDING',
              emptyLabel: 'Nothing here for this login.',
              items: const []),
        ]),
      );

      expect(find.text('NEEDS YOU NOW'), findsOneWidget);
      expect(find.text('Nothing needs you right now.'), findsOneWidget);
      // show_when_empty false → no header, no empty line, no dangling gap.
      expect(find.text('ONBOARDING'), findsNothing);
      expect(find.text('Nothing here for this login.'), findsNothing);
    });

    testWidgets('the badge is the backend\'s — count, phrase and tone',
        (tester) async {
      await _pump(
        tester,
        _payload(sections: [
          _section(key: 'needs_now', label: 'NEEDS YOU NOW', showWhenEmpty: true, items: [
            _tile(
                key: 'admin.order_alerts',
                label: 'New-order alerts',
                badge: 3,
                tone: 'bad',
                badgeLabel: '3 alerts'),
            _tile(key: 'fulfill.order_timeline', label: 'Where is this order'),
          ]),
        ]),
      );

      // The count and the phrase are printed verbatim; nothing is pluralised
      // or recomposed in Dart.
      expect(find.text('3'), findsOneWidget);
      expect(find.text('3 alerts'), findsOneWidget);

      final badged = tester.widget<Text>(find.text('3 alerts'));
      expect(badged.style?.color, DashboardHomeTile.toneColor('bad'),
          reason: 'the tone travels with the tile, never a section-name guess');

      // A tile with no badge shows no number and no phrase.
      expect(find.text('0'), findsNothing);
    });

    testWidgets('a tap hands the backend\'s own map back untouched',
        (tester) async {
      final opened = <Map<String, dynamic>>[];
      await _pump(tester, _sixSections(), onOpen: opened.add);

      await tester.tap(find.byKey(const Key('c1891_tile_admin.cust_tab.pending')));
      await tester.pump();

      expect(opened, hasLength(1));
      // The sub-tab pairing survives the tap: this is what lets ONE handler
      // reach a sub-tab of another page.
      expect(opened.single['tab_host'], 'customers');
      expect(opened.single['tab_key'], 'pendingRegistrations');
      expect(opened.single['route_key'], 'cust_pending');
      expect(opened.single['feature_key'], 'admin.cust_tab.pending');
    });

    testWidgets('ok:false renders nothing rather than throwing',
        (tester) async {
      await _pump(tester, _payload(ok: false, sections: const []));
      expect(find.byKey(const Key('c1891_dashboard_sections')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unknown extra field on a section is ignored, not fatal',
        (tester) async {
      final p = _sixSections();
      (p['sections'] as List)[1] = {
        ...(p['sections'] as List)[1] as Map<String, dynamic>,
        'layout_this_build_has_never_heard_of': 'grid_v9',
      };
      await _pump(tester, p);
      expect(find.text('ONBOARDING'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a load failure leaves the dashboard standing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DashboardHomeSections(
            load: () async => throw StateError('offline'),
            onOpen: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('c1891_dashboard_sections')), findsNothing);
    });
  });
}
