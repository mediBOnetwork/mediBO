// PROTECTED — CHANGE #306.
//
// The unpaid-order alert is the one popup that can cost real money: accepting
// it starts an inquiry against stock the platform may end up buying. So what
// this test holds down is that the CARD DECIDES NOTHING.
//
//  * every word on it — banner, chips, both button captions, the credit
//    sentence — is printed verbatim from the payload, never composed in Dart;
//  * Accept is offered only when the BACKEND says can_accept, so a customer
//    over their credit limit cannot be accepted from the popup any more than
//    from the lock screen;
//  * Reject stays available even then, because refusing is always allowed;
//  * a paid order carries its own banner and never a ring flag.
//
// If any of this drifts, the money gate has drifted with it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/order_alerts_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _item({
  bool canAccept = true,
  bool canReject = true,
  bool blocked = false,
  bool paid = false,
  bool critical = false,
  String creditNote = '',
}) =>
    <String, dynamic>{
      'alert_id': 7,
      'order_id': '11111111-2222-3333-4444-555555555555',
      'order_code': 'CPO300826CHAO1',
      'customer': 'Chandra Medicom',
      'amount_display': '₹1,175.85',
      'age_label': '4 min',
      'state': 'ringing',
      'state_label': 'Awaiting action',
      'stage': 'new',
      'stage_label': 'New',
      'risk': paid ? 'prepaid' : 'unpaid',
      'risk_label': paid ? 'Paid' : 'Unpaid',
      'paid': paid,
      'ring': !paid,
      'critical': critical,
      'banner': paid
          ? 'Paid order — accepted automatically'
          : 'UNPAID ORDER — needs your decision',
      'credit_blocked': blocked,
      'credit_note': creditNote,
      'can_accept': canAccept,
      'can_reject': canReject,
      'accept_label': 'Accept',
      'reject_label': 'Reject',
      'dismiss_label': 'Later',
      'view_label': 'Open order',
      'override_label': 'Authorise purchase without payment',
      'accept_note': 'Accepting starts the supplier inquiry only.',
      'reject_note': 'Rejects the order and releases anything reserved for it.',
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> item,
    {VoidCallback? onAccept, VoidCallback? onReject, VoidCallback? onOverride}) {
  return tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: OrderAlertCard(
          item: item,
          onAccept: onAccept ?? () {},
          onReject: onReject ?? () {},
          onOverride: onOverride,
        ),
      ),
    ),
  ));
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  testWidgets('every word is the payload, printed verbatim', (tester) async {
    await _pump(tester, _item());

    expect(find.text('UNPAID ORDER — needs your decision'), findsOneWidget);
    expect(find.text('Chandra Medicom'), findsOneWidget);
    expect(find.text('CPO300826CHAO1'), findsOneWidget);
    // The amount is the backend's rendered string — no Dart currency maths.
    expect(find.text('₹1,175.85'), findsOneWidget);
    expect(find.text('Unpaid'), findsOneWidget);
    expect(find.text('New'), findsOneWidget);
    expect(find.text('4 min'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(find.text('Accepting starts the supplier inquiry only.'), findsOneWidget);
  });

  testWidgets('can_accept:false disables Accept but never Reject', (tester) async {
    var accepted = 0;
    var rejected = 0;
    await _pump(
      tester,
      _item(
        canAccept: false,
        blocked: true,
        creditNote: 'Chandra Medicom owes ₹1,25,210.78 against a limit of ₹25,000.00.',
      ),
      onAccept: () => accepted++,
      onReject: () => rejected++,
    );

    // The block's reason is on the card, in the backend's own words.
    expect(
      find.text('Chandra Medicom owes ₹1,25,210.78 against a limit of ₹25,000.00.'),
      findsOneWidget,
    );

    final accept = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Accept'));
    expect(accept.onPressed, isNull, reason: 'a blocked order cannot be accepted');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
    await tester.pump();
    expect(rejected, 1, reason: 'refusing is always allowed');
    expect(accepted, 0);
  });

  testWidgets('the override is offered only when the card is blocked', (tester) async {
    await _pump(tester, _item(), onOverride: () {});
    expect(find.text('Authorise purchase without payment'), findsNothing);

    await _pump(tester, _item(canAccept: false, blocked: true), onOverride: () {});
    expect(find.text('Authorise purchase without payment'), findsOneWidget);
  });

  testWidgets('a paid order shows its own banner and no unpaid wording',
      (tester) async {
    await _pump(tester, _item(paid: true));
    expect(find.text('Paid order — accepted automatically'), findsOneWidget);
    expect(find.text('UNPAID ORDER — needs your decision'), findsNothing);
    expect(find.text('Paid'), findsOneWidget);
  });

  testWidgets('absent strings render as absence, never as a Dart default',
      (tester) async {
    // A payload with only the keys the card cannot do without: nothing else
    // may appear invented on screen.
    await _pump(tester, <String, dynamic>{
      'order_id': 'x',
      'can_accept': false,
      'can_reject': false,
    });
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Reject'), findsNothing);
    expect(find.text('UNPAID ORDER — needs your decision'), findsNothing);
  });
}
