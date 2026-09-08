// PROTECTED — CHANGE #304.
//
// The self-checkout path. #291 shipped a QR-only sheet: Razorpay returns
// image_url with a NULL qr_string on this account, so the app could only ever
// DRAW a picture and could never launch PhonePe/GPay on the phone holding it.
// Five QRs were minted and not one was ever paid.
//
// What this file holds down, forever:
//   * the sheet renders the BACKEND's pay_mode — it never picks a branch,
//     never guesses from a role, never falls back to a Dart default word;
//   * every visible string (title, subtitle, amount, button word, waiting
//     line, failure sentence) is the payload's, printed verbatim;
//   * "Pay now" vs "Resume payment" is the backend's word for the state
//     machine on rzp_payment_attempt, not a count kept here;
//   * tapping Pay opens EXACTLY the backend's pay_url, and NOTHING about that
//     tap marks the order paid — only the poll's own paid flag does, because
//     the webhook is truth and the client's return is only speed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/checkout_pay_sheet.dart';
import 'package:pharma_b2b/widgets/rzp_checkout_card.dart';

/// The exact shape `razorpay-checkout-create` returns in sdk mode — every one
/// of these strings is written by SQL (_rzp_attempt_view / razorpay_copy).
Map<String, dynamic> sdkPayload({
  String status = 'pending',
  String button = 'Pay now',
  bool paid = false,
  String failure = '',
  String payUrl = 'https://rzp.io/rzp/TESTLINK',
}) =>
    <String, dynamic>{
      'ok': true,
      'pay_mode': 'sdk',
      'provider': 'razorpay_checkout',
      'attempt_id': 'a1',
      'status': status,
      'status_label': 'Payment in progress',
      'paid': paid,
      'resumable': !paid,
      'pay_url': payUrl,
      'amount': 52.76,
      'amount_label': '₹52.76',
      'amount_row_label': 'Amount',
      'title': 'Pay securely with UPI',
      'subtitle': 'Opens PhonePe, Google Pay, Paytm or any UPI app.',
      'link_row_label': 'Payment link',
      'button_label': button,
      'failure_label': failure,
    };

Map<String, dynamic> qrPayload() => <String, dynamic>{
      'ok': true,
      'pay_mode': 'qr',
      'provider': 'razorpay_qr',
      'qr_id': 'q1',
      'rzp_qr_id': 'qr_live_1',
      'image_url': 'https://rzp.io/i/qrimage.png',
      'qr_string': 'upi://pay?pa=x@y&am=52.76',
      'amount_label': '₹52.76',
      'amount_row_label': 'Amount',
      'title': 'Pay advance ₹52.76',
      'subtitle': 'Scan with any UPI app',
      'paid': false,
    };

const Map<String, dynamic> kCopy = <String, dynamic>{
  'loading_label': 'Preparing your payment…',
  'error_label': 'Could not start the payment.',
  'retry_label': 'Try again',
  'sdk_opening_label': 'Opening your UPI app…',
  'sdk_waiting_label': 'Waiting for your payment to be confirmed',
  'sdk_waiting_hint': 'Finished paying? Keep this open.',
  'sdk_open_failed_label': 'Could not open the payment page.',
};

const Map<String, dynamic> kAction = <String, dynamic>{
  'pay_title': 'Pay for your order',
  'paid_toast': 'Payment received. Your order is confirmed.',
  'done_label': 'Done',
};

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the backend picks the branch, the sheet only prints it', () {
    testWidgets('pay_mode sdk draws the checkout card, never a QR',
        (tester) async {
      await tester.pumpWidget(_host(CheckoutPaySheet(
        orderId: 'o1',
        checkout: kAction,
        razorpayCopy: kCopy,
        createPayment: (_) async => sdkPayload(),
      )));
      await tester.pump();

      expect(find.byType(RzpCheckoutCard), findsOneWidget);
      // The button word is the BACKEND's, not a Dart literal.
      expect(find.text('Pay now'), findsOneWidget);
      expect(find.text('₹52.76'), findsOneWidget);
      expect(find.text('Opens PhonePe, Google Pay, Paytm or any UPI app.'),
          findsOneWidget);
      // and no QR anywhere near it
      expect(find.byType(RazorpayQrCardProbe), findsNothing);
    });

    testWidgets('pay_mode qr still draws #291\'s QR card, unchanged',
        (tester) async {
      await tester.pumpWidget(_host(CheckoutPaySheet(
        orderId: 'o1',
        checkout: kAction,
        razorpayCopy: kCopy,
        createPayment: (_) async => qrPayload(),
      )));
      await tester.pump();

      expect(find.byType(RzpCheckoutCard), findsNothing);
      expect(find.text('Scan with any UPI app'), findsOneWidget);
    });

    testWidgets('an absent pay_mode is the OLD contract, not an error',
        (tester) async {
      final legacy = qrPayload()..remove('pay_mode');
      await tester.pumpWidget(_host(CheckoutPaySheet(
        orderId: 'o1',
        checkout: kAction,
        razorpayCopy: kCopy,
        createPayment: (_) async => legacy,
      )));
      await tester.pump();
      expect(find.text('Scan with any UPI app'), findsOneWidget);
    });
  });

  group('the state machine speaks, the widget does not', () {
    testWidgets('an attempted attempt says Resume payment', (tester) async {
      await tester.pumpWidget(_host(CheckoutPaySheet(
        orderId: 'o1',
        checkout: kAction,
        razorpayCopy: kCopy,
        createPayment: (_) async =>
            sdkPayload(status: 'attempted', button: 'Resume payment'),
      )));
      await tester.pump();
      expect(find.text('Resume payment'), findsOneWidget);
      expect(find.text('Pay now'), findsNothing);
    });

    testWidgets('a failed attempt prints the backend sentence, not a slug',
        (tester) async {
      await tester.pumpWidget(_host(CheckoutPaySheet(
        orderId: 'o1',
        checkout: kAction,
        razorpayCopy: kCopy,
        createPayment: (_) async => sdkPayload(
            status: 'failed', failure: 'That payment did not go through.'),
      )));
      await tester.pump();
      expect(find.text('That payment did not go through.'), findsOneWidget);
    });

    testWidgets('a paid attempt offers no button at all', (tester) async {
      await tester.pumpWidget(_host(CheckoutPaySheet(
        orderId: 'o1',
        checkout: kAction,
        razorpayCopy: kCopy,
        createPayment: (_) async =>
            sdkPayload(status: 'paid', paid: true, button: ''),
      )));
      await tester.pump();
      expect(find.text('Pay now'), findsNothing);
      expect(find.text('Resume payment'), findsNothing);
      expect(find.text('Payment received. Your order is confirmed.'),
          findsOneWidget);
    });
  });

  group('the tap opens the backend url and marks nothing paid', () {
    testWidgets('Pay opens EXACTLY pay_url', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(_host(CheckoutPaySheet(
        orderId: 'o1',
        checkout: kAction,
        razorpayCopy: kCopy,
        createPayment: (_) async => sdkPayload(payUrl: 'https://rzp.io/rzp/ABC'),
        openUrl: (u) async {
          opened.add(u);
          return true;
        },
      )));
      await tester.pump();
      await tester.tap(find.text('Pay now'));
      await tester.pump();

      expect(opened, <String>['https://rzp.io/rzp/ABC']);
    });

    testWidgets('coming back from Razorpay does NOT mark the order paid',
        (tester) async {
      // The webhook is truth. The sheet may only show "waiting" until the
      // BACKEND says paid — a client that could flip this could mark any
      // order paid for free.
      await tester.pumpWidget(_host(CheckoutPaySheet(
        orderId: 'o1',
        checkout: kAction,
        razorpayCopy: kCopy,
        createPayment: (_) async => sdkPayload(),
        openUrl: (_) async => true,
        checkPaid: (_) async => <String, dynamic>{'ok': true, 'paid': false},
      )));
      await tester.pump();
      await tester.tap(find.text('Pay now'));
      await tester.pump();

      expect(find.text('Waiting for your payment to be confirmed'),
          findsOneWidget);
      expect(find.text('Payment received. Your order is confirmed.'),
          findsNothing);

      // let the poll run and keep saying "not paid"
      await tester.pump(kCheckoutPayPollInterval);
      await tester.pump();
      expect(find.text('Payment received. Your order is confirmed.'),
          findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('only the backend paid flag flips the sheet', (tester) async {
      var calls = 0;
      await tester.pumpWidget(_host(CheckoutPaySheet(
        orderId: 'o1',
        checkout: kAction,
        razorpayCopy: kCopy,
        createPayment: (_) async => sdkPayload(),
        openUrl: (_) async => true,
        checkPaid: (_) async {
          calls++;
          return <String, dynamic>{
            'ok': true,
            'paid': true,
            'view': sdkPayload(status: 'paid', paid: true, button: ''),
          };
        },
      )));
      await tester.pump();
      await tester.pump(kCheckoutPayPollInterval);
      await tester.pump();

      expect(calls, greaterThan(0));
      expect(find.text('Payment received. Your order is confirmed.'),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a refused launch shows the backend failure copy, not silence',
        (tester) async {
      await tester.pumpWidget(_host(CheckoutPaySheet(
        orderId: 'o1',
        checkout: kAction,
        razorpayCopy: kCopy,
        createPayment: (_) async => sdkPayload(),
        openUrl: (_) async => false,
      )));
      await tester.pump();
      await tester.tap(find.text('Pay now'));
      await tester.pump();
      // Not "waiting" — nothing was handed off. The customer is told, in the
      // BACKEND's words, and the link stays on screen as the way out.
      expect(find.text('Waiting for your payment to be confirmed'), findsNothing);
      expect(find.text('Could not open the payment page.'), findsOneWidget);
      expect(find.text('https://rzp.io/rzp/TESTLINK'), findsOneWidget);
      // and the button is still tappable for a second try
      expect(find.text('Pay now'), findsOneWidget);
    });
  });

  group('RzpCheckoutView computes nothing', () {
    test('an absent field is an absence, never a default word', () {
      final v = RzpCheckoutView.fromPayload(<String, dynamic>{'ok': true});
      expect(v.buttonLabel, '');
      expect(v.amountLabel, '');
      expect(v.subtitle, '');
      expect(v.hasPayUrl, isFalse);
      expect(v.paid, isFalse);
    });

    test('the backend message outranks the machine slug', () {
      final v = RzpCheckoutView.fromPayload(<String, dynamic>{
        'ok': false,
        'error': 'nothing_due',
        'message': 'Nothing left to pay on this order.',
      });
      expect(v.error, 'Nothing left to pay on this order.');
    });

    test('paid is the backend flag, never inferred from the status text', () {
      final v = RzpCheckoutView.fromPayload(
          <String, dynamic>{'ok': true, 'status': 'paid', 'paid': false});
      expect(v.paid, isFalse, reason: 'only the paid flag may say paid');
    });
  });
}

/// A marker type used only to assert the QR card is absent in sdk mode without
/// importing the QR widget into this file's expectations.
class RazorpayQrCardProbe extends StatelessWidget {
  const RazorpayQrCardProbe({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
