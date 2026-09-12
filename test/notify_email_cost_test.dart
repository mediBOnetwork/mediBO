// cmd #299 — the focused test for PART 3 of the notification rebuild.
//
// What it holds down, all on the same principle as the protected suite: the
// cost dashboard is ONE RPC printed verbatim. Every rupee on that screen was
// formatted in Postgres from notification_cost_config, so:
//
//   1. Money is never re-derived in Dart. The test feeds a cost_display that
//      does NOT match the row's own send counts; the screen must print the
//      backend's string anyway. A screen that "corrects" it has started
//      computing.
//   2. Rows render in payload order — the fixture is deliberately not sorted
//      by cost, and the backend already ordered it.
//   3. Absence is explicit: no rows means the backend's empty_text, not a
//      Dart-authored "Nothing here yet".
//   4. Titles, subtitle, tile labels, the savings line and the footnote all
//      come from the payload — there is no Dart copy to drift.
//   5. Changing the range asks the BACKEND again with the new window and
//      re-prints its new range_label; the screen never relabels itself.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/notify_cost_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _payload({
  required String rangeLabel,
  List<Map<String, dynamic>>? rows,
}) =>
    {
      'ok': true,
      'title': 'Notification cost',
      'subtitle': 'What every event costs to deliver, and what push saved.',
      'range_label': rangeLabel,
      'totals': [
        {'label': 'Total spend', 'value': '₹2.19', 'tone': 'neutral'},
        {'label': 'WhatsApp', 'value': '₹2.19', 'tone': 'warning'},
        {'label': 'Notifications sent', 'value': '36', 'tone': 'neutral'},
        {'label': 'Free on push / email', 'value': '4', 'tone': 'success'},
      ],
      'savings': {
        'label': 'Saved versus WhatsApp-only',
        'value': '₹0.46',
        'note': '3 push and 1 email deliveries that would otherwise have been '
            'billed WhatsApp conversations.',
      },
      'rows_heading': 'Cost per event',
      'rows': rows ??
          [
            // Deliberately NOT ordered by cost: the backend ordered this list,
            // and a screen that re-sorts it is deciding something.
            {
              'event_key': 'order_placed',
              'label': 'Order placed',
              'sends_label': '12 sent',
              'mix_label': 'WA 10 · Push 2',
              // Deliberately inconsistent with the counts above — the screen
              // must print it, not recompute it.
              'cost_display': '₹9,999.00',
              'share_pct': 53,
            },
            {
              'event_key': 'payment_due',
              'label': 'Payment due',
              'sends_label': '24 sent',
              'mix_label': 'WA 24',
              'cost_display': '₹1.02',
              'share_pct': 47,
            },
          ],
      'empty_text': 'No notifications were sent in this window.',
      'footnote': 'Rates are the per-conversation charges in '
          'notification_cost_config. Push and email are billed at zero.',
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => NotifyCostScreen.rpcOverride = null);

  // A tall surface so the whole list is laid out at once — the ListView is
  // lazy, and a row scrolled out of the default 800x600 viewport would look
  // like a missing row rather than an off-screen one.
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: NotifyCostScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('prints the backend payload verbatim and computes no money',
      (tester) async {
    NotifyCostScreen.rpcOverride = (fn, params) async {
      expect(fn, 'notif_cost_dashboard');
      return _payload(rangeLabel: 'Last 30 days');
    };
    await pump(tester);

    expect(find.text('Notification cost'), findsOneWidget);
    expect(find.text('What every event costs to deliver, and what push saved.'),
        findsOneWidget);
    expect(find.text('Last 30 days'), findsOneWidget);

    // Tile labels and values are the backend's, in the backend's order.
    for (final t in const ['Total spend', 'WhatsApp', 'Notifications sent',
      'Free on push / email']) {
      expect(find.text(t), findsOneWidget, reason: 'tile label $t');
    }
    expect(find.text('36'), findsOneWidget);

    // The savings block.
    expect(find.text('Saved versus WhatsApp-only'), findsOneWidget);
    expect(find.text('₹0.46'), findsOneWidget);

    // THE money rule: the fixture's cost_display disagrees with its own send
    // counts on purpose. Printing it unchanged is the pass condition.
    expect(find.text('₹9,999.00'), findsOneWidget);
    expect(find.text('₹1.02'), findsOneWidget);
    expect(find.text('53%'), findsOneWidget);

    expect(find.text('Cost per event'), findsOneWidget);
    expect(
        find.textContaining('notification_cost_config'), findsOneWidget);
  });

  testWidgets('rows render in payload order, never re-sorted by cost',
      (tester) async {
    NotifyCostScreen.rpcOverride =
        (fn, params) async => _payload(rangeLabel: 'Last 30 days');
    await pump(tester);

    final placed = tester.getTopLeft(find.text('Order placed')).dy;
    final due = tester.getTopLeft(find.text('Payment due')).dy;
    // 'Order placed' carries the SMALLER real spend but comes first in the
    // payload, so it must come first on screen.
    expect(placed, lessThan(due));
  });

  testWidgets('an empty window shows the backend empty text', (tester) async {
    NotifyCostScreen.rpcOverride = (fn, params) async =>
        _payload(rangeLabel: 'Last 7 days', rows: const []);
    await pump(tester);

    expect(find.text('No notifications were sent in this window.'),
        findsOneWidget);
    expect(find.text('Cost per event'), findsOneWidget);
  });

  testWidgets('changing the range re-asks the backend and reprints its label',
      (tester) async {
    final asked = <int>[];
    NotifyCostScreen.rpcOverride = (fn, params) async {
      final days = (params?['p_days'] as num?)?.toInt() ?? -1;
      asked.add(days);
      return _payload(rangeLabel: 'Last $days days');
    };
    await pump(tester);

    expect(asked, [30]);
    expect(find.text('Last 30 days'), findsOneWidget);

    await tester.tap(find.text('7'));
    await tester.pumpAndSettle();

    expect(asked, [30, 7]);
    // The new caption is the backend's, not '7 days' assembled in Dart.
    expect(find.text('Last 7 days'), findsOneWidget);
    expect(find.text('Last 30 days'), findsNothing);
  });

  testWidgets('a failed load shows backend copy and a Retry that re-asks',
      (tester) async {
    var calls = 0;
    NotifyCostScreen.rpcOverride = (fn, params) async {
      calls++;
      if (calls == 1) throw Exception('boom');
      return _payload(rangeLabel: 'Last 30 days');
    };
    await pump(tester);

    // ui_copy is empty in a widget test, so the copy renders as the empty
    // string it is — the point is that NO Dart fallback sentence appears and
    // the Retry button is present and works.
    expect(find.byType(FilledButton), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('Notification cost'), findsOneWidget);
  });
}
