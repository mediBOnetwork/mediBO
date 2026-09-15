// CMD #1987 — the message trail prints the backend's account of the send and
// nothing of its own.
//
// What this holds down, permanently:
//   * every chip on an attempt row — status, path, reason — is the LABEL and
//     TONE the payload carried. The fixture deliberately pairs a 'sent' status
//     with a warning tone and an unknown reason code, so a Dart-side re-derive
//     ("sent means green") would be visible instantly;
//   * a row with no provider id prints the backend's 'No provider id' line, and
//     a row with one prints the backend's provider line verbatim — the screen
//     never decides that a send happened;
//   * rows render in PAYLOAD order (the fixture is deliberately not
//     chronological) — there is no client-side sort;
//   * the day list, the empty state and the not-found state all print the
//     backend's own copy, and a mode this build has never heard of falls back
//     to that same empty copy instead of throwing;
//   * tapping an order in the day list re-asks the backend for that ORDER —
//     the screen does not filter a list it already has.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/admin/order_notification_trail_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _orderPayload() => {
      'ok': true,
      'mode': 'order',
      'title': 'Message trail',
      'subtitle': 'CPO140926CHA101O1',
      'search': {
        'hint': 'Order code, e.g. CPO140926CHA101O1',
        'button_label': 'Show trail',
      },
      'order': {
        'id': '25520698-511a-4fd0-96e8-0b2d6a61c591',
        'code_label': 'CPO140926CHA101O1',
        'when_label': '14 Sep 2026, 02:28 pm',
        'customer_label': 'Chandra Medicom',
        'status_label': 'Order placed',
      },
      'summary_label': '0 sent · 5 not sent',
      'summary_tone': 'warning',
      'rows_label': 'Every attempt, newest first',
      'empty_label': 'No message has been attempted for this order',
      'empty_hint': 'Nothing has tried to notify anyone about it yet',
      'rows': [
        {
          'id': 'a55247',
          'source_label': 'Send path',
          'when_label': '14 Sep, 02:28 pm',
          'event_key': 'order_placed',
          'event_label': 'Order placed',
          // A 'Sent' label carrying a WARNING tone: nothing in Dart may decide
          // that "sent" is green.
          'status': {'label': 'Sent', 'tone': 'warning', 'note': null},
          'path': {'label': 'WhatsApp template', 'tone': 'success'},
          'reason': {'label': 'Already sent for this order', 'tone': 'warning'},
          'reason_raw': 'already_delivered_recently',
          'provider_label': null,
        },
        {
          'id': 'l43580',
          'source_label': 'Ledger',
          // Deliberately EARLIER than the row above: payload order wins.
          'when_label': '14 Sep, 02:01 pm',
          'event_key': 'partner_order_placed',
          'event_label': 'Partner · new order',
          'status': {
            'label': 'Skipped',
            'tone': 'neutral',
            'note': 'Deliberately not sent',
          },
          'path': {'label': 'No channel', 'tone': 'neutral'},
          // A reason code nobody has worded yet is still shown.
          'reason': {'label': 'wa_route_half_bound', 'tone': 'danger'},
          'reason_raw': 'wa_route_half_bound',
          'provider_label': 'No provider id',
        },
        {
          'id': 'l43581',
          'source_label': 'Ledger',
          'when_label': '14 Sep, 02:29 pm',
          'event_key': 'order_placed',
          'event_label': 'Order placed',
          'status': {'label': 'Sent', 'tone': 'success', 'note': null},
          'path': {'label': 'WhatsApp template', 'tone': 'success'},
          'reason': null,
          'reason_raw': null,
          'provider_label': 'Provider id wamid.HBgMOTE4MzU3ODgxODcz',
        },
      ],
    };

Map<String, dynamic> _listPayload() => {
      'ok': true,
      'mode': 'list',
      'title': 'Message trail',
      'subtitle': '14 Sep 2026 · all zones',
      'search': {
        'hint': 'Order code, e.g. CPO140926CHA101O1',
        'button_label': 'Show trail',
      },
      'rows_label': 'Orders on this day',
      'empty_label': 'No orders on this day in this zone',
      'empty_hint':
          'Change the date or zone in the header picker, or type an order code above',
      'orders': [
        {
          'id': '25520698-511a-4fd0-96e8-0b2d6a61c591',
          'code_label': 'CPO140926CHA101O1',
          'when_label': '02:28 pm',
          'customer_label': 'Chandra Medicom',
          'summary_label': '0 sent · 5 not sent',
          'tone': 'warning',
        },
        {
          'id': '00000000-0000-0000-0000-0000000000aa',
          'code_label': 'CPO140926CHA102O1',
          'when_label': '02:01 pm',
          'customer_label': 'Chandra Medicom',
          'summary_label': '2 sent · 0 not sent',
          'tone': 'success',
        },
      ],
    };

/// Every pump happens on a 360 px phone — the viewport this screen is designed
/// for — and tall enough that the lazy list builds every row it was sent.
Future<void> _pump(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(360, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: child));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    Ds.apply(const {});
  });

  tearDown(() => OrderNotificationTrailTransport.rpc = null);

  testWidgets('every chip is the backend label, in payload order',
      (t) async {
    OrderNotificationTrailTransport.rpc = (fn, params) async {
      expect(fn, 'order_notification_trail');
      return _orderPayload();
    };

    await _pump(t, const OrderNotificationTrailScreen(orderCode: 'X'));

    expect(find.text('CPO140926CHA101O1'), findsWidgets);
    expect(find.text('Chandra Medicom'), findsOneWidget);
    expect(find.text('0 sent · 5 not sent'), findsOneWidget);

    // Verbatim chips, including the reason code nobody has worded yet.
    expect(find.text('Already sent for this order'), findsOneWidget);
    expect(find.text('wa_route_half_bound'), findsOneWidget);
    expect(find.text('WhatsApp template'), findsNWidgets(2));
    expect(find.text('No channel'), findsOneWidget);

    // Provider lines, both ways round.
    expect(find.text('Ledger · No provider id'), findsOneWidget);
    expect(find.text('Ledger · Provider id wamid.HBgMOTE4MzU3ODgxODcz'),
        findsOneWidget);
    expect(find.text('Send path'), findsOneWidget);

    // Payload order, not time order: 02:28, then 02:01, then 02:29.
    final times = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => s.startsWith('14 Sep, '))
        .toList();
    expect(times, ['14 Sep, 02:28 pm', '14 Sep, 02:01 pm', '14 Sep, 02:29 pm']);
  });

  testWidgets('the day list prints its own summaries and opens one order',
      (t) async {
    final asked = <Map<String, dynamic>?>[];
    OrderNotificationTrailTransport.rpc = (fn, params) async {
      asked.add(params);
      return asked.length == 1 ? _listPayload() : _orderPayload();
    };

    await _pump(t, const OrderNotificationTrailScreen());

    expect(find.text('Orders on this day'), findsOneWidget);
    expect(find.text('0 sent · 5 not sent'), findsOneWidget);
    expect(find.text('2 sent · 0 not sent'), findsOneWidget);
    expect(asked.first?['p_order_id'], isNull);

    await t.tap(find.text('CPO140926CHA101O1'));
    await t.pumpAndSettle();

    // The tap re-ASKS the backend for that order; it does not filter locally.
    expect(asked.length, 2);
    expect(asked.last?['p_order_id'], '25520698-511a-4fd0-96e8-0b2d6a61c591');
    expect(find.text('Every attempt, newest first'), findsOneWidget);
  });

  testWidgets('not_found and an unknown mode both print the backend copy',
      (t) async {
    OrderNotificationTrailTransport.rpc = (fn, params) async => {
          'ok': true,
          'mode': 'not_found',
          'title': 'Message trail',
          'search': {'hint': 'h', 'button_label': 'b'},
          'empty_label': 'No order with that code in this zone',
          'empty_hint': 'Check the code, or switch zone in the header picker',
        };

    await _pump(t,
        const OrderNotificationTrailScreen(key: ValueKey('nf'), orderCode: 'NOPE'));
    expect(find.text('No order with that code in this zone'), findsOneWidget);
    expect(find.text('Check the code, or switch zone in the header picker'),
        findsOneWidget);

    // A mode this build has never heard of is forward-compatible: same empty
    // copy, no throw.
    OrderNotificationTrailTransport.rpc = (fn, params) async => {
          'ok': true,
          'mode': 'something_new',
          'title': 'Message trail',
          'search': {'hint': 'h', 'button_label': 'b'},
          'empty_label': 'Nothing to show',
          'empty_hint': '',
        };
    await _pump(t,
        const OrderNotificationTrailScreen(key: ValueKey('unknown'), orderCode: 'Y'));
    expect(find.text('Nothing to show'), findsOneWidget);
  });

  testWidgets('a refusal is the backend sentence, with no invented retry',
      (t) async {
    OrderNotificationTrailTransport.rpc = (fn, params) async => {
          'ok': false,
          'error': 'forbidden',
          'title': 'Message trail',
          'message': 'Only an admin can read the message trail',
        };

    await _pump(t, const OrderNotificationTrailScreen());
    expect(find.text('Only an admin can read the message trail'), findsOneWidget);
  });
}
