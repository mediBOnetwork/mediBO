// PROTECTED — CMD #1889.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the customer's payout UPI card behaves.
//
// What this holds down:
//
//   1. SIGNUP NEVER SEES IT. `pharmacy_payout_upi()` answers `needed:false`
//      until there is money to send, and the card then draws ZERO pixels. This
//      is the whole point of "UPI is not asked at signup" — a card that renders
//      an empty shell would still be asking.
//
//   2. EVERY WORD IS THE BACKEND'S. Title, hint, the "₹2,400.00 is waiting"
//      line, the state sentence, the ADD and CONFIRM captions are printed
//      verbatim. Nothing is pluralised, formatted or composed in Dart — the
//      fixture deliberately carries a phrasing no Dart string could produce.
//
//   3. CONFIRM APPEARS ONLY WHILE A ₹1 TEST IS OUT. `test_pending:true` shows
//      the confirm button; without it the customer is offered ADD. A verified
//      card offers neither — only "change".
//
//   4. VERIFIED IS THE BACKEND'S FLAG, NOT AN INFERENCE. A payload that says
//      verified:true with an unconfirmed-looking state still renders as
//      verified, because the server decided.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/payout_upi_card.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _card({
  bool needed = true,
  bool verified = false,
  bool pending = false,
  String vpa = '',
}) =>
    {
      'ok': true,
      'needed': needed,
      'title': 'Where should we send your money?',
      'hint': 'We send ₹1 to prove it works before anything else is paid out.',
      'due': {'has': true, 'count': 2, 'amount': 2400},
      'due_label': '₹2,400.00 across 2 payouts is waiting to be sent to you.',
      'state_label': verified
          ? 'Your UPI ID is verified. Payouts go out to it.'
          : pending
              ? '₹1 test sent — waiting for you to confirm'
              : 'Payouts are on hold until your UPI ID is verified.',
      'state_tone': verified ? 'success' : (pending ? 'warning' : 'danger'),
      'vpa': vpa,
      'vpa_name': '',
      'verified': verified,
      'test_pending': pending,
      'vpa_label': 'UPI ID',
      'name_label': 'Name on the UPI ID',
      'can_edit': true,
      'locked_hint': '',
      'add_label': 'Add UPI',
      'change_label': 'Change UPI ID',
      'send_label': 'Send ₹1 test',
      'confirm_label': 'I received ₹1',
      'reference': pending ? 'UPI1-AB12CD34' : '',
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  PayoutUpiCard.rpcOverride = (rpc, params) async => payload;
  await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: PayoutUpiCard()))));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => PayoutUpiCard.rpcOverride = null);

  testWidgets('needed:false draws nothing — signup is never asked',
      (tester) async {
    await _pump(tester, _card(needed: false));
    expect(find.text('Where should we send your money?'), findsNothing);
    expect(find.text('Add UPI'), findsNothing);
  });

  testWidgets('an unverified customer with money waiting is offered ADD',
      (tester) async {
    await _pump(tester, _card());
    expect(find.text('Where should we send your money?'), findsOneWidget);
    // verbatim: the amount, the count and the phrasing are all the backend's
    expect(find.text('₹2,400.00 across 2 payouts is waiting to be sent to you.'),
        findsOneWidget);
    expect(find.text('Payouts are on hold until your UPI ID is verified.'),
        findsOneWidget);
    expect(find.text('Add UPI'), findsOneWidget);
    expect(find.text('I received ₹1'), findsNothing);
  });

  testWidgets('a ₹1 test in flight offers CONFIRM, not ADD', (tester) async {
    await _pump(tester, _card(pending: true, vpa: 'shop@upi'));
    expect(find.text('I received ₹1'), findsOneWidget);
    expect(find.text('Add UPI'), findsNothing);
    expect(find.text('₹1 test sent — waiting for you to confirm'),
        findsOneWidget);
    // the saved VPA is printed with the backend's own label
    expect(find.text('UPI ID: shop@upi'), findsOneWidget);
    // and the customer can still correct it
    expect(find.text('Change UPI ID'), findsOneWidget);
  });

  testWidgets('verified is the backend flag: no ADD, no CONFIRM, only change',
      (tester) async {
    await _pump(tester, _card(verified: true, vpa: 'shop@upi'));
    expect(find.text('Your UPI ID is verified. Payouts go out to it.'),
        findsOneWidget);
    expect(find.text('Add UPI'), findsNothing);
    expect(find.text('I received ₹1'), findsNothing);
    expect(find.text('Change UPI ID'), findsOneWidget);
  });

  testWidgets('an owner who cannot edit is shown the reason, not a button',
      (tester) async {
    final p = _card();
    p['can_edit'] = false;
    p['locked_hint'] = 'Only the shop owner login can change the UPI ID.';
    await _pump(tester, p);
    expect(find.text('Only the shop owner login can change the UPI ID.'),
        findsOneWidget);
    expect(find.text('Add UPI'), findsNothing);
  });
}
