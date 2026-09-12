// PROTECTED — CMD #1941.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the Dashboard's AUTOMATION block, never to make an
// unrelated change go green.
//
// Why this file exists: the AutoFlow / Bundle toggles used to sit under the
// Supplier inquiry and Supplier orders sub-tabs, which a phone reaches through
// a chip row — so on the mobile PWA they were unreachable, the same way the
// Fulfill "Also here" strip hides the Order cut-off door. They are now one
// AUTOMATION block at the TOP of the Dashboard grid, and every decision about
// them stays in `dashboard_home().automation` / `dashboard_automation_set()`.
//
// What this holds down:
//
//   1. The block is FIRST, above every section, and its heading is the
//      payload's own label — never the word "AUTOMATION" written in Dart.
//
//   2. A pill prints the backend's label and its ON/OFF word verbatim, and its
//      colour comes from `tone`, never from `on` being re-derived here.
//
//   3. A tap sends the chip's OWN key and the value it is moving to, and the
//      block then re-draws from the REPLY. A refusal (ok:false) therefore
//      leaves the pill exactly as the server still has it — there is no local
//      flip to roll back.
//
//   4. `show:false` (a login that may not switch them) draws no block at all,
//      and neither does a surface that passes no `automationSet`. An empty bar
//      is the thing CHANGE #754 removed and must not come back.
//
//   5. The ORDERS section is an ordinary payload section: it renders in the
//      order the backend sent it, between FIELD & GROWTH and DELIVERY, with
//      the cut-off tile inside it.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/dashboard_home_sections.dart';

import 'ui_copy_fixture.dart';

Map<String, dynamic> _chip(String key, String label, bool on,
        {String? actionLabel}) =>
    {
      'key': key,
      'setting_key': 'x_$key',
      'label': label,
      'on': on,
      'state_label': on ? 'ON' : 'OFF',
      'tone': on ? 'on' : 'off',
      if (actionLabel != null) 'action_label': actionLabel,
    };

Map<String, dynamic> _automation({
  bool show = true,
  bool inquiryOn = false,
  bool bundleOn = false,
  bool ordersOn = false,
}) =>
    {
      'key': 'automation',
      'label': 'AUTOMATION',
      'hint': 'Tap to switch · hold for settings',
      'show': show,
      'items': show
          ? [
              _chip('auto_meta', 'Inquiry AutoFlow', inquiryOn),
              _chip('bundle', 'Bundle', bundleOn,
                  actionLabel: 'Re-optimise bundles'),
              _chip('order_auto_meta', 'Orders AutoFlow', ordersOn),
            ]
          : const [],
    };

Map<String, dynamic> _tile(String key, String label) => {
      'feature_key': key,
      'label': label,
      'icon_key': 'schedule',
      'icon_letter': label.substring(0, 1).toUpperCase(),
      'route_key': 'order_cutoff',
      'deep_link': '/admin/go/order_cutoff',
      'tool_key': null,
      'tab_host': null,
      'tab_key': null,
      'description': '',
      'badge_count': 0,
      'badge_label': null,
      'badge_tone': 'info',
    };

Map<String, dynamic> _section(String key, String label,
        List<Map<String, dynamic>> items) =>
    {
      'key': key,
      'label': label,
      'show_when_empty': false,
      'empty_label': 'Nothing here for this login.',
      'items': items,
    };

/// The grid as the live RPC sends it for a super admin after CMD #1941.
Map<String, dynamic> _payload({Map<String, dynamic>? automation}) => {
      'ok': true,
      'title': 'All your work',
      'automation': automation ?? _automation(),
      'sections': [
        _section('field_growth', 'FIELD & GROWTH',
            [_tile('admin.cust_tab.s_leads', 'S Leads')]),
        _section('orders', 'ORDERS', [_tile('admin.order_cutoff', 'Order cut-off')]),
        _section('delivery', 'DELIVERY',
            [_tile('admin.delivery_waves', 'Delivery waves')]),
      ],
      'items_count': 3,
    };

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  DashboardAutomationSet? set,
  DashboardAutomationAct? act,
  void Function(String message, bool isError)? onToast,
  bool wire = true,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: DashboardHomeSections(
          // A fresh key every pump: the widget reads its payload in initState,
          // so re-pumping the same element would keep the previous answer.
          key: UniqueKey(),
          load: () async => payload,
          onOpen: (_) {},
          automationSet: wire ? (set ?? (_, _) async => {'ok': true}) : null,
          automationAction: wire ? act : null,
          onToast: onToast,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    seedUiCopy();
  });

  group('CMD #1941 — the AUTOMATION block is the backend\'s, at the top', () {
    testWidgets('heading is the payload label and prints above every section',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.text('AUTOMATION'), findsOneWidget);
      final auto = tester.getTopLeft(find.text('AUTOMATION')).dy;
      for (final label in ['FIELD & GROWTH', 'ORDERS', 'DELIVERY']) {
        expect(find.text(label), findsOneWidget, reason: 'missing $label');
        expect(tester.getTopLeft(find.text(label)).dy, greaterThan(auto),
            reason: '$label must print below the automation block');
      }
    });

    testWidgets('pills print the backend label and ON/OFF word verbatim',
        (tester) async {
      await _pump(tester,
          _payload(automation: _automation(inquiryOn: true, bundleOn: false)));

      expect(find.text('Inquiry AutoFlow'), findsOneWidget);
      expect(find.text('Bundle'), findsOneWidget);
      expect(find.text('Orders AutoFlow'), findsOneWidget);
      // One ON (inquiry) and two OFF — the words are the payload's, and the
      // widget never writes either of them.
      expect(find.text('ON'), findsOneWidget);
      expect(find.text('OFF'), findsNWidgets(2));
    });

    testWidgets('a tap sends the chip key and the value it moves to',
        (tester) async {
      final sent = <String>[];
      await _pump(tester, _payload(), set: (key, next) async {
        sent.add('$key=$next');
        return {'ok': true, 'automation': _automation(inquiryOn: true)};
      });

      await tester.tap(find.text('Inquiry AutoFlow'));
      await tester.pumpAndSettle();

      expect(sent, ['auto_meta=true']);
      // Re-drawn from the REPLY: the pill that was OFF now reads ON.
      expect(find.text('ON'), findsOneWidget);
    });

    testWidgets('the reply is the state — a refusal does not flip the pill',
        (tester) async {
      final toasts = <String>[];
      await _pump(
        tester,
        _payload(),
        set: (key, next) async => {
          'ok': false,
          'error': 'not_authorized',
          'message': 'This console is for staff logins.',
          // The server still has every toggle OFF.
          'automation': _automation(),
        },
        onToast: (m, isError) => toasts.add('${isError ? 'E' : 'I'}:$m'),
      );

      await tester.tap(find.text('Bundle'));
      await tester.pumpAndSettle();

      expect(find.text('OFF'), findsNWidgets(3));
      expect(find.text('ON'), findsNothing);
      expect(toasts, ['E:This console is for staff logins.']);
    });

    testWidgets('the success toast is the reply\'s own sentence',
        (tester) async {
      final toasts = <String>[];
      await _pump(
        tester,
        _payload(),
        set: (key, next) async => {
          'ok': true,
          'toast': 'Automatic by Meta: ON',
          'automation': _automation(inquiryOn: true),
        },
        onToast: (m, isError) => toasts.add('${isError ? 'E' : 'I'}:$m'),
      );

      await tester.tap(find.text('Inquiry AutoFlow'));
      await tester.pumpAndSettle();

      expect(toasts, ['I:Automatic by Meta: ON']);
    });

    testWidgets('show:false draws no block, and neither does an unwired host',
        (tester) async {
      await _pump(tester, _payload(automation: _automation(show: false)));
      expect(find.text('AUTOMATION'), findsNothing);
      expect(find.text('Bundle'), findsNothing);
      // The sections still draw.
      expect(find.text('ORDERS'), findsOneWidget);

      await _pump(tester, _payload(), wire: false);
      expect(find.text('AUTOMATION'), findsNothing);
      expect(find.text('Bundle'), findsNothing);
      expect(find.text('ORDERS'), findsOneWidget);
    });

    testWidgets('the Bundle action only exists while the payload names one',
        (tester) async {
      final acted = <String>[];
      await _pump(
        tester,
        // Bundle ON, so its extra affordance is offered.
        _payload(automation: _automation(bundleOn: true)),
        set: (_, _) async => {'ok': true},
        act: (key) async {
          acted.add(key);
          return {'ok': true, 'automation': _automation(bundleOn: true)};
        },
      );

      final action = find.byIcon(Icons.auto_fix_high_outlined);
      expect(action, findsOneWidget);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(acted, ['bundle']);

      // Bundle OFF: the backend still names an action_label, but a pill that
      // is off offers nothing.
      await _pump(tester, _payload(), act: (key) async => {'ok': true});
      expect(find.byIcon(Icons.auto_fix_high_outlined), findsNothing);
    });

    testWidgets('ORDERS carries the cut-off tile, in payload order',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.text('Order cut-off'), findsOneWidget);
      final orders = tester.getTopLeft(find.text('ORDERS')).dy;
      expect(tester.getTopLeft(find.text('FIELD & GROWTH')).dy,
          lessThan(orders));
      expect(tester.getTopLeft(find.text('DELIVERY')).dy, greaterThan(orders));
      expect(tester.getTopLeft(find.text('Order cut-off')).dy,
          greaterThan(orders));
    });
  });
}
