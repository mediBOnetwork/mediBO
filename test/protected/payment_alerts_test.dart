// PROTECTED — CMD #1929.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes payment-alert behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the Payment alerts screen prints ONE payload and
// decides nothing:
//
//   1. Rows render in PAYLOAD ORDER. The fixture is deliberately not sorted by
//      time or amount: a client-side sort would reorder it and fail here.
//
//   2. Every visible string is the backend's, verbatim: amount_label,
//      status_label, sender_label, utr_label, app_label, posted_label,
//      source_label, match_reason. Nothing is formatted in Dart — in
//      particular no '₹', no rounding and no pluralisation.
//
//   3. The filter chip prints `chip_label`, the caption the BACKEND already
//      joined. Composing '$label $count' in Dart is the bug this guards: the
//      wording of that join would stop being an ui_copy UPDATE.
//
//   4. A matched row offers no action. The two buttons are driven by
//      retry_match_label / ignore_label being non-empty — which the backend
//      blanks on a matched row — not by a status string compared in Dart. A
//      verified payment is not re-matched or ignored from this screen.
//
//   5. ok:false renders the backend's own `message` plus its retry label
//      instead of throwing or showing a Dart-authored error.
//
//   6. An empty list shows empty_label + empty_hint from the payload, never a
//      bare spinner and never a hardcoded "Nothing here".
//
// No network, no Supabase, no goldens — the RPC is injected.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/payment_alerts_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// One row exactly as payment_alert_state() builds it.
Map<String, dynamic> _row({
  required String id,
  required String status,
  required String tone,
  required String amountLabel,
  required String senderLabel,
  String utrLabel = '523456789012',
  String appLabel = 'PhonePe',
  String sourceLabel = 'Rule',
  String postedLabel = '12 Sep, 06:41 pm',
  String matchReason = '',
  String customerLabel = '',
  String orderCode = '',
}) =>
    {
      'ok': true,
      'alert_id': id,
      'status': status,
      'status_label': status == 'matched' ? 'Matched' : 'Needs a look',
      'status_tone': tone,
      'source': 'rule',
      'source_label': sourceLabel,
      'app_label': appLabel,
      'rule_label': appLabel,
      'amount_label': amountLabel,
      'utr_label': utrLabel,
      'has_utr': true,
      'sender_label': senderLabel,
      'posted_label': postedLabel,
      'match_reason': matchReason,
      'customer_label': customerLabel,
      'order_code': orderCode,
      // Blank on a matched row — that is how the backend withdraws the action.
      'retry_match_label': status == 'matched' ? '' : 'Match again',
      'ignore_label': status == 'matched' ? '' : 'Ignore',
    };

Map<String, dynamic> _payload({List<Map<String, dynamic>>? rows}) => {
      'ok': true,
      'title': 'Payment alerts',
      'subtitle': 'Payment notifications forwarded from the partner phone',
      'empty_label': 'No payment notifications for this zone and date yet.',
      'empty_hint': 'Alerts appear here the moment the partner phone forwards one.',
      'retry_label': 'Retry',
      'count_label': '3 alerts',
      'active_filter': '',
      'filters': [
        {'key': '', 'label': 'All', 'count': 3, 'chip_label': 'All 3'},
        {'key': 'new', 'label': 'New', 'count': 0, 'chip_label': 'New 0'},
        {
          'key': 'matched',
          'label': 'Matched',
          'count': 1,
          'chip_label': 'Matched 1'
        },
        {
          'key': 'unmatched',
          'label': 'Needs a look',
          'count': 2,
          'chip_label': 'Needs a look 2'
        },
        {
          'key': 'ignored',
          'label': 'Ignored',
          'count': 0,
          'chip_label': 'Ignored 0'
        },
      ],
      'rows': rows ??
          [
            // NOT in time or amount order, on purpose.
            _row(
              id: 'a-1',
              status: 'unmatched',
              tone: 'warning',
              amountLabel: '₹1,250.50',
              senderLabel: 'Sharma Pharma',
              matchReason: 'Nothing pending looks like this payment.',
            ),
            _row(
              id: 'a-2',
              status: 'matched',
              tone: 'success',
              amountLabel: '₹500.00',
              senderLabel: 'Pooja Medical',
              appLabel: 'Google Pay',
              postedLabel: '12 Sep, 06:39 pm',
              matchReason: 'Matched on the full UTR',
              customerLabel: 'Pooja Medical Store',
              orderCode: 'PO-4F2A',
            ),
            _row(
              id: 'a-3',
              status: 'unmatched',
              tone: 'warning',
              amountLabel: '₹3,499.00',
              senderLabel: 'POOJA MEDICAL',
              appLabel: 'SBI YONO',
              postedLabel: '12 Sep, 06:52 pm',
              matchReason: 'Asked the customer which order this is for.',
            ),
          ],
    };

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  List<String?>? statusCalls,
  List<List<String>>? setCalls,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: PaymentAlertsScreen(
      screenRpc: (status) async {
        statusCalls?.add(status);
        return payload;
      },
      setStatusRpc: (id, status) async {
        setCalls?.add([id, status]);
        return {'ok': true};
      },
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    // The screen calls RenderLog.write; its 800 ms debounce is a real Timer
    // that would outlive the test and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  testWidgets('rows render in payload order, never re-sorted in Dart',
      (tester) async {
    await _pump(tester, _payload());

    final amounts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.startsWith('₹'))
        .toList();

    expect(amounts, ['₹1,250.50', '₹500.00', '₹3,499.00'],
        reason: 'payload order, not sorted by amount or by time');
  });

  testWidgets('every visible string is the backend string, verbatim',
      (tester) async {
    await _pump(tester, _payload());

    for (final s in [
      'Payment alerts',
      'Payment notifications forwarded from the partner phone',
      '3 alerts',
      '₹1,250.50',
      'Sharma Pharma',
      '523456789012',
      'PhonePe',
      '12 Sep, 06:41 pm',
      'Rule',
      'Nothing pending looks like this payment.',
      'Needs a look',
      'Matched',
      'Matched on the full UTR',
    ]) {
      expect(find.text(s), findsWidgets, reason: 'missing backend string: $s');
    }

    // The customer and the order code are joined by the card, so assert the
    // rendered line rather than the two halves.
    expect(find.text('Pooja Medical Store · PO-4F2A'), findsOneWidget);
  });

  testWidgets('filter chips print chip_label, not a Dart-joined label+count',
      (tester) async {
    await _pump(tester, _payload());

    for (final s in ['All 3', 'New 0', 'Matched 1', 'Needs a look 2', 'Ignored 0']) {
      expect(find.text(s), findsOneWidget, reason: 'chip_label verbatim: $s');
    }
  });

  testWidgets('picking a filter asks the backend for that status', (tester) async {
    final calls = <String?>[];
    await _pump(tester, _payload(), statusCalls: calls);
    expect(calls, [null], reason: 'first load is the unfiltered payload');

    await tester.tap(find.text('Needs a look 2'));
    await tester.pumpAndSettle();

    expect(calls, [null, 'unmatched'],
        reason: 'the chip key is sent as-is; no client-side filtering');
  });

  testWidgets('a matched row offers no action; an unmatched one offers both',
      (tester) async {
    final setCalls = <List<String>>[];
    await _pump(tester, _payload(), setCalls: setCalls);

    // Two unmatched rows in the fixture → two of each control.
    expect(find.text('Match again'), findsNWidgets(2));
    expect(find.byIcon(Icons.block), findsNWidgets(2));

    await tester.tap(find.text('Match again').first);
    await tester.pumpAndSettle();
    expect(setCalls, [
      ['a-1', 'new']
    ], reason: 'the first unmatched row is a-1, and re-match means status new');
  });

  testWidgets('a matched-only payload shows no action at all', (tester) async {
    await _pump(
        tester,
        _payload(rows: [
          _row(
            id: 'm-1',
            status: 'matched',
            tone: 'success',
            amountLabel: '₹500.00',
            senderLabel: 'Pooja Medical',
          )
        ]));

    expect(find.text('Match again'), findsNothing);
    expect(find.byIcon(Icons.block), findsNothing);
  });

  testWidgets('ok:false renders the backend message and its retry label',
      (tester) async {
    await _pump(tester, {
      'ok': false,
      'error': 'not_authorized',
      'message': 'Payment alerts are visible to a partner or an admin.',
      'retry_label': 'Retry',
      'title': 'Payment alerts',
    });

    expect(find.text('Payment alerts are visible to a partner or an admin.'),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('an empty list shows the backend empty state, not a spinner',
      (tester) async {
    await _pump(tester, _payload(rows: []));

    expect(find.text('No payment notifications for this zone and date yet.'),
        findsOneWidget);
    expect(find.text('Alerts appear here the moment the partner phone forwards one.'),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
