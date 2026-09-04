// PROTECTED — CHANGE #1016: the staff information architecture.
//
// What this holds down. Five verbs + More, drawn from ONE backend payload,
// with nothing decided in Dart:
//   * the tab bar is `staff_nav().tabs` in PAYLOAD order (the fixture is
//     deliberately not the shipped order), a tab the backend turned off is
//     absent (never a hole), labels print verbatim, and a refusal blanks
//     nothing;
//   * a redirect is the backend's table: an old route resolves to its new
//     home, a route the table never mentions opens where it always did, and a
//     `when_no_seed` redirect steps aside for a link that carries a subject;
//   * the layout flag (`staff_layout_v1`) is the payload's word, not a clock
//     read in Dart;
//   * a home (Money / More) renders sections and tiles in PAYLOAD order (the
//     Money fixture lists Books before Bills to prove no client sort), every
//     rupee/count/label verbatim, a tap hands the backend's own tile map back,
//     the More search filters the backend's list and prints the backend's
//     empty sentence, the "Recent" row appears only when sent, and the
//     unused-report button only when the payload offers it;
//   * the strip above Customers / Suppliers / Fulfill draws chips in payload
//     order and draws NOTHING for an empty answer;
//   * the seven partner doors resolve in the staff route shard and an unknown
//     route resolves to null so the shell's backend-worded default stays in
//     charge.
//
// Runs on the Dart VM: no network, no Supabase — payloads are inline.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pharma_b2b/screens/admin/staff_home_screen.dart';
import 'package:pharma_b2b/screens/shell/shell_staff_routes.dart';
import 'package:pharma_b2b/services/staff_nav.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _tab(
  String key,
  String label,
  String route, {
  bool visible = true,
  String icon = 'people',
}) => {
  'key': key,
  'label': label,
  'icon_key': icon,
  'route_key': route,
  'badge_key': key == 'fulfill' ? 'order_alerts' : '',
  'visible': visible,
};

/// Deliberately NOT the shipped order, and Suppliers switched off.
final Map<String, dynamic> _navPayload = {
  'ok': true,
  'role': 'admin',
  'layout': 'v2',
  'layout_note': '',
  'tabs': [
    _tab('money', 'Paisa', 'money_home', icon: 'rupee'),
    _tab('dashboard', 'Dashboard', 'dashboard', icon: 'dashboard'),
    _tab('suppliers', 'Suppliers', 'suppliers', visible: false),
    _tab('more', 'Aur', 'more', icon: 'apps'),
    _tab('fulfill', 'Fulfill', 'fulfillment', icon: 'truck'),
    _tab('customers', 'Customers', 'customers'),
  ],
  'redirects': {
    'customer_360': {'to': 'customers', 'when_no_seed': true},
    'collect': {'to': 'supplier_shop', 'when_no_seed': false},
    'settlement': {'to': 'partner_settlement', 'when_no_seed': false},
  },
};

Map<String, dynamic> _tile(
  String key,
  String label,
  String route, {
  int badge = 0,
  String badgeLabel = '',
  String desc = '',
}) => {
  'feature_key': key,
  'label': label,
  'icon_key': 'receipt',
  'icon_letter': label.substring(0, 1),
  'route_key': route,
  'deep_link': '/admin/go/$route',
  'tool_key': null,
  'description': desc,
  'badge_count': badge,
  'badge_label': badgeLabel.isEmpty ? null : badgeLabel,
  'opens': 0,
};

/// Books BEFORE Bills, Zone P&L before GST — nothing here is alphabetical.
final Map<String, dynamic> _moneyPayload = {
  'ok': true,
  'tab_key': 'money',
  'title': 'Paisa',
  'subtitle': 'Bills, payments, settlements and the books.',
  'search_hint': 'Find a screen…',
  'search_empty': 'No screen matches that.',
  'recents_label': 'Recent',
  'strip_label': 'Also here',
  'stats_label': 'Right now',
  'empty_label': 'Nothing here for your login yet.',
  'unused_report_label': '',
  'sections': [
    {
      'key': 'home_money:Books',
      'label': 'Books',
      'sublabel': '',
      'items': [
        _tile('admin.zone_pnl', 'Zone P&L', 'zone_pnl'),
        _tile('admin.gst', 'GST', 'gst'),
      ],
    },
    {
      'key': 'home_money:Bills & payments',
      'label': 'Bills & payments',
      'sublabel': '',
      'items': [
        _tile(
          'admin.bill_pipeline',
          'Bills',
          'bill_pipeline',
          badge: 7,
          badgeLabel: '7 bills to review',
        ),
      ],
    },
  ],
  'items_count': 3,
  'recents': [],
  'stats': [
    {
      'key': 'pending_bills',
      'label': 'Supplier bills to check',
      'value_label': '12',
      'tone': 'warn',
      'route_key': 'bill_pipeline',
    },
  ],
};

final Map<String, dynamic> _morePayload = {
  ..._moneyPayload,
  'tab_key': 'more',
  'title': 'More',
  'subtitle': 'Everything else, in one place.',
  'unused_report_label': 'Screens nobody opened',
  'stats': [],
  'sections': [
    {
      'key': 'more_comms:',
      'label': 'Communication',
      'sublabel': '',
      'items': [
        _tile('admin.whatsapp', 'WhatsApp', 'whatsapp'),
        _tile('admin.wa_templates', 'WhatsApp templates', 'wa_templates'),
      ],
    },
    {
      'key': 'more_system:',
      'label': 'System & Dev tools',
      'sublabel': '',
      'items': [
        _tile(
          'admin.audit_log',
          'Audit trail',
          'audit_log',
          desc: 'who changed what',
        ),
      ],
    },
  ],
  'items_count': 3,
  'recents': [_tile('admin.gst', 'GST', 'gst')],
};

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 1200, height: 900, child: child)),
);

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('staff_nav() — the bar is the payload', () {
    test('tabs keep payload order; a hidden tab is absent, never a hole', () {
      final p = StaffNavPayload.fromJson(_navPayload);
      expect(p.ok, isTrue);
      expect(p.visibleTabs.map((t) => t.key).toList(), [
        'money',
        'dashboard',
        'more',
        'fulfill',
        'customers',
      ]);
      expect(p.tabs.length, 6);
      final entries = staffNavEntries(p);
      expect(entries.map((e) => e.label).toList(), [
        'Paisa',
        'Dashboard',
        'Aur',
        'Fulfill',
        'Customers',
      ]);
      expect(entries.map((e) => e.route).toList(), [
        'money_home',
        'dashboard',
        'more',
        'fulfillment',
        'customers',
      ]);
      expect(p.tabForRoute('fulfillment')!.badgeKey, 'order_alerts');
      expect(p.tabForRoute('money_home')!.badgeKey, '');
    });

    test('a refusal or a malformed answer is the empty payload', () {
      expect(StaffNavPayload.fromJson({'ok': false, 'tabs': []}).ok, isFalse);
      expect(StaffNavPayload.fromJson(null).visibleTabs, isEmpty);
      expect(staffNavEntries(StaffNavPayload.empty), isEmpty);
    });

    test('redirects are the backend table, applied verbatim', () {
      final p = StaffNavPayload.fromJson(_navPayload);
      expect(p.resolve('collect'), 'supplier_shop');
      expect(p.resolve('settlement'), 'partner_settlement');
      // an unmentioned route opens where it always did
      expect(p.resolve('bill_pipeline'), 'bill_pipeline');
      // when_no_seed: the bare tile redirects, a link with a subject does not
      expect(p.resolve('customer_360'), 'customers');
      expect(p.resolve('customer_360', hasSeed: true), 'customer_360');
    });

    test('the layout flag is the payload word, never a Dart clock', () {
      expect(StaffNavPayload.fromJson(_navPayload).isLegacy, isFalse);
      expect(
        StaffNavPayload.fromJson({..._navPayload, 'layout': 'v1'}).isLegacy,
        isTrue,
      );
    });
  });

  group('StaffHomeScreen — one home, rendered verbatim', () {
    testWidgets(
      'Money: sections + tiles in payload order, stats verbatim, tap hands the map back',
      (tester) async {
        Map<String, dynamic>? opened;
        await tester.pumpWidget(
          _host(
            StaffHomeScreen(
              tabKey: 'money',
              load: (_) async => _moneyPayload,
              onOpen: (t) => opened = t,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Paisa'), findsOneWidget);
        expect(
          find.text('Bills, payments, settlements and the books.'),
          findsOneWidget,
        );
        // stats verbatim
        expect(find.text('12'), findsOneWidget);
        expect(find.text('Supplier bills to check'), findsOneWidget);
        // payload order: Books before Bills & payments; Zone P&L before GST
        final books = tester.getTopLeft(find.text('Books'));
        final bills = tester.getTopLeft(find.text('Bills & payments'));
        expect(books.dy, lessThan(bills.dy));
        final zone = tester.getTopLeft(find.text('Zone P&L'));
        final gst = tester.getTopLeft(find.text('GST'));
        expect(zone.dx < gst.dx || zone.dy < gst.dy, isTrue);
        // the badge phrase is the backend's
        expect(find.text('7 bills to review'), findsOneWidget);
        // no search box on Money
        expect(find.byKey(const Key('c1016_more_search')), findsNothing);
        await tester.tap(find.text('Bills'));
        expect(opened, isNotNull);
        expect(opened!['route_key'], 'bill_pipeline');
        expect(opened!['feature_key'], 'admin.bill_pipeline');
        // a stat is a door too
        await tester.tap(find.text('12'));
        expect(opened!['route_key'], 'bill_pipeline');
      },
    );

    testWidgets(
      'More: search filters the backend list; recents and the report button only when sent',
      (tester) async {
        var report = 0;
        await tester.pumpWidget(
          _host(
            StaffHomeScreen(
              tabKey: 'more',
              load: (_) async => _morePayload,
              onOpen: (_) {},
              onUnusedReport: () => report++,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Recent'), findsOneWidget);
        expect(find.text('Communication'), findsOneWidget);
        expect(find.text('Screens nobody opened'), findsOneWidget);
        await tester.tap(find.text('Screens nobody opened'));
        expect(report, 1);

        await tester.enterText(
          find.byKey(const Key('c1016_more_search')),
          'audit',
        );
        await tester.pump();
        expect(find.text('Audit trail'), findsOneWidget);
        expect(find.text('WhatsApp templates'), findsNothing);
        expect(find.text('Communication'), findsNothing);
        // recents step aside while searching
        expect(find.text('Recent'), findsNothing);

        await tester.enterText(
          find.byKey(const Key('c1016_more_search')),
          'zzz',
        );
        await tester.pump();
        expect(find.text('No screen matches that.'), findsOneWidget);
      },
    );

    testWidgets('a refusal prints the backend sentence, no Dart fallback', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          StaffHomeScreen(
            tabKey: 'money',
            load: (_) async => {
              'ok': false,
              'error': 'not_authorized',
              'message': 'Not for this login.',
              'sections': [],
              'items_count': 0,
              'empty_label': 'Nothing here for your login yet.',
            },
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Not for this login.'), findsOneWidget);
    });

    testWidgets('the Money home does not offer the unused report', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          StaffHomeScreen(
            tabKey: 'money',
            load: (_) async => _moneyPayload,
            onOpen: (_) {},
            onUnusedReport: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Screens nobody opened'), findsNothing);
    });
  });

  group('StaffHomeStrip — the extras beside a page', () {
    testWidgets('chips in payload order, tap hands the map back', (
      tester,
    ) async {
      Map<String, dynamic>? opened;
      await tester.pumpWidget(
        _host(
          StaffHomeStrip(
            tabKey: 'fulfill',
            load: (_) async => {
              ..._moneyPayload,
              'tab_key': 'fulfill',
              'sections': [
                {
                  'key': 'home_fulfill:Team',
                  'label': 'Team',
                  'items': [
                    _tile('partner.workers', 'Workers', 'partner_workers'),
                    _tile(
                      'worker.my_tasks',
                      'My tasks',
                      'my_tasks',
                      badge: 3,
                      badgeLabel: '3 tasks',
                    ),
                  ],
                },
                {
                  'key': 'home_fulfill:Delivery',
                  'label': 'Delivery',
                  'items': [
                    _tile(
                      'admin.delivery_waves',
                      'Delivery waves',
                      'delivery_waves',
                    ),
                  ],
                },
              ],
              'items_count': 3,
            },
            onOpen: (t) => opened = t,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Also here'), findsOneWidget);
      final w = tester.getTopLeft(find.text('Workers'));
      final t = tester.getTopLeft(find.text('My tasks'));
      final d = tester.getTopLeft(find.text('Delivery waves'));
      expect(w.dx, lessThan(t.dx));
      expect(t.dx, lessThan(d.dx));
      expect(find.text('3'), findsOneWidget);
      await tester.tap(find.text('My tasks'));
      expect(opened!['route_key'], 'my_tasks');
    });

    testWidgets('an empty answer draws nothing at all', (tester) async {
      await tester.pumpWidget(
        _host(
          StaffHomeStrip(
            tabKey: 'customers',
            load: (_) async => {
              ..._moneyPayload,
              'sections': [],
              'items_count': 0,
            },
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('c1016_strip_customers')), findsNothing);
      expect(find.text('Also here'), findsNothing);
    });
  });

  group('shell_staff_routes — the partner doors', () {
    test(
      'the seven partner routes resolve; an unknown route resolves to null',
      () {
        for (final r in const [
          'partner_documents',
          'partner_staff',
          'partner_workers',
          'partner_expenses',
          'supplier_payment',
          'supplier_returns',
          'partner_settlement',
        ]) {
          expect(shellStaffRouteScreen(r), isNotNull, reason: r);
        }
        expect(
          shellStaffRouteScreen('settlement'),
          isNull,
          reason: 'the office console stays the shell\'s own case',
        );
        expect(shellStaffRouteScreen('never_heard_of_it'), isNull);
      },
    );
  });

  group('staff_nav cache — the last good bar, on disk, for its own login', () {
    const nav = <String, dynamic>{
      'ok': true,
      'role': 'admin',
      'layout': 'v2',
      'redirects': <String, dynamic>{},
      'tabs': [
        {
          'key': 'dashboard',
          'label': 'Dashboard',
          'visible': true,
          'icon_key': 'dashboard',
          'route_key': 'dashboard',
        },
        {
          'key': 'money',
          'label': 'Money',
          'visible': true,
          'icon_key': 'currency_rupee',
          'route_key': 'money_home',
        },
      ],
    };

    setUp(() => StaffNav.debugSet(StaffNavPayload.empty));

    test(
      'the cached payload of THIS login draws before the RPC answers',
      () async {
        SharedPreferences.setMockInitialValues({
          'staff_nav.cache.v1': jsonEncode({...nav, '_owner_uid': 'u-1'}),
        });
        StaffNav.currentUid = () => 'u-1';
        await StaffNav.debugRestore();
        expect(StaffNav.value.value.ok, isTrue);
        expect(StaffNav.value.value.visibleTabs.map((t) => t.key), [
          'dashboard',
          'money',
        ]);
      },
    );

    test('another account\'s cache is dropped, never drawn', () async {
      SharedPreferences.setMockInitialValues({
        'staff_nav.cache.v1': jsonEncode({...nav, '_owner_uid': 'u-1'}),
      });
      StaffNav.currentUid = () => 'u-2';
      await StaffNav.debugRestore();
      expect(StaffNav.value.value.ok, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('staff_nav.cache.v1'), isNull);
    });

    test(
      'a live answer already drawn is never overwritten by the disk',
      () async {
        SharedPreferences.setMockInitialValues({
          'staff_nav.cache.v1': jsonEncode({
            ...nav,
            '_owner_uid': 'u-1',
            'layout': 'v1',
          }),
        });
        StaffNav.currentUid = () => 'u-1';
        StaffNav.debugSet(StaffNavPayload.fromJson(nav));
        await StaffNav.debugRestore();
        expect(StaffNav.value.value.layout, 'v2');
      },
    );
  });
}
