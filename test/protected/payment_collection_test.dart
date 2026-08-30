// PROTECTED — CHANGE #293.
//
// #304 renamed the sheet's injected creator `createQr` -> `createPayment`:
// the sheet now mints whatever payable object the BACKEND's pay_mode names (a
// Razorpay Checkout link for a customer paying on the phone in hand, the #291
// QR when the payer is on another device). Only the parameter name moved —
// every assertion below is the one #293 wrote, and a payload with no pay_mode
// is still the QR contract, which is why they all still hold.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes payment collection, never to make an unrelated change
// go green.
//
// #291 shipped the Razorpay QR behind a BOOLEAN switch, with no statement of
// where the money lands, no zone/date collection view, and nothing at all at
// checkout. #293 replaced the boolean with a two-option selector and wired the
// customer's own "Pay & Place Order". What must never regress:
//
//   1. The selector is the BACKEND's option list. The card renders the options
//      it is given, in payload order, marks the one carrying `selected:true`,
//      and hands back that option's own KEY — never a boolean, never a label.
//      A third provider must be addable from SQL alone.
//   2. Only `can_edit` makes an option tappable, so an ordinary admin reading
//      the screen cannot move the whole platform's money.
//   3. "Where the money lands" is printed verbatim, label and value, in payload
//      order — no Dart ever assembles "bank ••••1234" or picks a fallback word.
//      A `note` (no active VPA) prints instead of, not beside, invented copy.
//   4. The collection summary prints the backend's totals and its zone/date
//      chips as strings; `is_empty` shows the backend's empty line.
//   5. CheckoutPaySheet mints ONE QR, prints the payload's own words while it
//      loads and when it fails, and flips to paid only because the BACKEND
//      said paid — never because a timer elapsed.
//   6. Absence is absence: an empty payload renders no button, no title and no
//      paid banner rather than Dart defaults.
//
// Fixtures mirror payment_mode_get() / checkout_action() / rzp_order_paid().
// No network, no Supabase.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/checkout_pay_sheet.dart';
import 'package:pharma_b2b/widgets/payment_mode_card.dart';

const String _kManualLabel = 'Manual UPI';
const String _kGatewayLabel = 'Payment Gateway';
const String _kManualHelper =
    'Customers scan the shared UPI QR and send a screenshot. An admin verifies each payment by hand.';
const String _kGatewayHelper =
    'Every payment gets its own Razorpay QR and confirms itself. No screenshot, no manual check.';

Map<String, dynamic> _modePayload({
  String selected = 'gateway',
  bool canEdit = true,
  Map<String, dynamic>? lands,
  Map<String, dynamic>? collection,
}) =>
    <String, dynamic>{
      'ok': true,
      'title': 'Payment collection mode',
      'helper': 'Pick how customers pay.',
      'selected': selected,
      'mode_label': selected == 'gateway' ? _kGatewayLabel : _kManualLabel,
      'mode_tone': selected == 'gateway' ? 'ok' : 'pending',
      'can_edit': canEdit,
      'options': [
        {
          'key': 'manual_upi',
          'label': _kManualLabel,
          'helper': _kManualHelper,
          'selected': selected == 'manual_upi',
        },
        {
          'key': 'gateway',
          'label': _kGatewayLabel,
          'helper': _kGatewayHelper,
          'selected': selected == 'gateway',
        },
      ],
      if (lands != null) 'money_lands': lands,
      if (collection != null) 'collection': collection,
    };

Map<String, dynamic> _gatewayLands() => <String, dynamic>{
      'ok': true,
      'mode': 'gateway',
      'title': 'Where the money lands',
      'caption': 'Collected by Razorpay and settled to your bank',
      'note': '',
      'can_edit': false,
      'rows': [
        {'label': 'Razorpay account', 'value': 'rzp_live_TT7Yo8GlF8JHF6'},
        {'label': 'Settlement bank', 'value': 'HDFC Bank ••••4417'},
        {'label': 'Settlement cycle', 'value': 'T+2 working days'},
      ],
    };

Map<String, dynamic> _manualLandsNoVpa() => <String, dynamic>{
      'ok': true,
      'mode': 'manual_upi',
      'title': 'Where the money lands',
      'caption': 'Collected into the active UPI account',
      'note': 'No active UPI account. Add one below.',
      'rows': const [],
      'can_edit': false,
    };

Map<String, dynamic> _collection({bool empty = false}) => <String, dynamic>{
      'ok': true,
      'title': 'Collected',
      'zone_label': 'Raipur Zone',
      'date_label': '21/08/2026',
      'total_label': 'Total collected',
      'total_display': empty ? '₹0.00' : '₹18,240.00',
      'orders_label': 'Orders',
      'orders_count': empty ? 0 : 7,
      'verified_label': 'Verified',
      'verified_display': empty ? '₹0.00' : '₹15,900.00',
      'pending_label': 'Pending',
      'pending_display': empty ? '₹0.00' : '₹2,340.00',
      'is_empty': empty,
      'empty_label': 'No payments collected in this zone on this date.',
      'modes': [
        {'key': 'gateway', 'label': _kGatewayLabel, 'amount_display': '₹12,000.00', 'count': 4},
        {'key': 'manual', 'label': _kManualLabel, 'amount_display': '₹3,900.00', 'count': 2},
        {'key': 'cash', 'label': 'Cash', 'amount_display': '₹2,340.00', 'count': 1},
      ],
    };

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('collection mode selector', () {
    testWidgets('renders the backend options in payload order and marks selected',
        (tester) async {
      await _pump(tester, PaymentModeCard(
        payload: _modePayload(),
        onPick: (_) {},
      ));

      expect(find.text(_kManualLabel), findsWidgets);
      expect(find.text(_kGatewayLabel), findsWidgets);
      expect(find.text(_kManualHelper), findsOneWidget);
      expect(find.text(_kGatewayHelper), findsOneWidget);

      // Exactly one option is ticked, and it is the one the BACKEND marked.
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_off), findsOneWidget);

      final manualY = tester.getTopLeft(find.text(_kManualHelper)).dy;
      final gatewayY = tester.getTopLeft(find.text(_kGatewayHelper)).dy;
      expect(manualY, lessThan(gatewayY),
          reason: 'options render in payload order, never re-sorted in Dart');
    });

    testWidgets('onPick emits the option KEY, not a boolean or a label',
        (tester) async {
      final picked = <String>[];
      await _pump(tester, PaymentModeCard(
        payload: _modePayload(),
        onPick: picked.add,
      ));

      await tester.tap(find.text(_kManualHelper));
      await tester.pump();
      expect(picked, ['manual_upi']);
    });

    testWidgets('a third mode the backend invents needs no Dart change',
        (tester) async {
      final payload = _modePayload();
      (payload['options'] as List).add({
        'key': 'card_terminal',
        'label': 'Card terminal',
        'helper': 'Swipe at the counter.',
        'selected': false,
      });
      final picked = <String>[];
      await _pump(tester, PaymentModeCard(payload: payload, onPick: picked.add));

      expect(find.text('Card terminal'), findsOneWidget);
      await tester.tap(find.text('Swipe at the counter.'));
      await tester.pump();
      expect(picked, ['card_terminal']);
    });

    testWidgets('can_edit:false makes the whole selector read-only',
        (tester) async {
      final picked = <String>[];
      await _pump(tester, PaymentModeCard(
        payload: _modePayload(canEdit: false),
        onPick: picked.add,
      ));

      await tester.tap(find.text(_kManualHelper));
      await tester.pump();
      expect(picked, isEmpty);
    });

    testWidgets('busy blocks a second tap while the switch is in flight',
        (tester) async {
      final picked = <String>[];
      await _pump(tester, PaymentModeCard(
        payload: _modePayload(),
        busy: true,
        onPick: picked.add,
      ));

      await tester.tap(find.text(_kManualHelper));
      await tester.pump();
      expect(picked, isEmpty);
    });
  });

  group('where the money lands', () {
    testWidgets('gateway rows print label and value verbatim', (tester) async {
      await _pump(tester, PaymentModeCard(
        payload: _modePayload(lands: _gatewayLands()),
        onPick: (_) {},
      ));

      expect(find.text('Where the money lands'), findsOneWidget);
      expect(find.text('Collected by Razorpay and settled to your bank'),
          findsOneWidget);
      // The masked account is the BACKEND's string, assembled in SQL.
      expect(find.text('HDFC Bank ••••4417'), findsOneWidget);
      expect(find.text('T+2 working days'), findsOneWidget);
      expect(find.text('rzp_live_TT7Yo8GlF8JHF6'), findsOneWidget);
    });

    testWidgets('no active VPA shows the backend note and no rows',
        (tester) async {
      await _pump(tester, PaymentModeCard(
        payload: _modePayload(selected: 'manual_upi', lands: _manualLandsNoVpa()),
        onPick: (_) {},
      ));

      expect(find.text('No active UPI account. Add one below.'), findsOneWidget);
      expect(find.text('UPI ID'), findsNothing);
    });

    testWidgets('the edit affordance appears only when the backend allows it',
        (tester) async {
      final lands = _gatewayLands()
        ..['can_edit'] = true
        ..['edit_label'] = 'Edit';
      await _pump(tester, PaymentModeCard(
        payload: _modePayload(lands: lands),
        onPick: (_) {},
        onEditGateway: () {},
      ));
      expect(find.text('Edit'), findsOneWidget);

      await _pump(tester, PaymentModeCard(
        payload: _modePayload(lands: _gatewayLands()),
        onPick: (_) {},
        onEditGateway: () {},
      ));
      expect(find.text('Edit'), findsNothing);
    });
  });

  group('zone + date collection summary', () {
    testWidgets('prints the backend totals and its zone/date chips',
        (tester) async {
      await _pump(tester, PaymentModeCard(
        payload: _modePayload(collection: _collection()),
        onPick: (_) {},
      ));

      expect(find.text('Raipur Zone'), findsOneWidget);
      expect(find.text('21/08/2026'), findsOneWidget);
      expect(find.text('₹18,240.00'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(find.text('₹15,900.00'), findsOneWidget);
      expect(find.text('₹2,340.00'), findsWidgets);
      expect(find.text('₹12,000.00'), findsOneWidget);
      expect(find.text('No payments collected in this zone on this date.'),
          findsNothing);
    });

    testWidgets('is_empty prints the backend empty line', (tester) async {
      await _pump(tester, PaymentModeCard(
        payload: _modePayload(collection: _collection(empty: true)),
        onPick: (_) {},
      ));

      expect(find.text('No payments collected in this zone on this date.'),
          findsOneWidget);
    });
  });

  group('Pay & Place Order sheet', () {
    Map<String, dynamic> checkout() => <String, dynamic>{
          'pay_now': true,
          'pay_title': 'Pay to confirm your order',
          'paid_toast': 'Payment received — order confirmed',
          'done_label': 'Done',
        };

    Map<String, dynamic> rzpCopy() => <String, dynamic>{
          'loading_label': 'Preparing your QR…',
          'error_label': 'Could not prepare the QR right now.',
          'retry_label': 'Try again',
        };

    Map<String, dynamic> qrPayload() => <String, dynamic>{
          'ok': true,
          'provider': 'razorpay_qr',
          'qr_id': 'a1',
          'rzp_qr_id': 'qr_live_1',
          'qr_string': 'upi://pay?pa=rzp@icici&am=500.00&cu=INR',
          'image_url': '',
          'title': 'Pay advance ₹500.00',
          'subtitle': 'Scan this QR in any UPI app.',
          'amount_label': '₹500.00',
          'amount_row_label': 'Amount',
          'note_label': 'Verified by Razorpay',
          'paid': false,
        };

    testWidgets('mints exactly one QR and prints the payload, not Dart words',
        (tester) async {
      var mints = 0;
      await _pump(tester, CheckoutPaySheet(
        orderId: 'o1',
        checkout: checkout(),
        razorpayCopy: rzpCopy(),
        orderCode: 'MB-1042',
        amountDisplay: '₹500.00',
        createPayment: (_) async {
          mints++;
          return qrPayload();
        },
        checkPaid: (_) async => <String, dynamic>{'paid': false},
      ));

      // First frame: the backend's loading word, never a bare spinner alone.
      expect(find.text('Preparing your QR…'), findsOneWidget);
      await tester.pumpAndSettle();

      expect(mints, 1, reason: 'never a second QR for the same order');
      expect(find.text('Pay to confirm your order'), findsOneWidget);
      expect(find.text('Scan this QR in any UPI app.'), findsOneWidget);
      expect(find.text('Amount'), findsOneWidget);
      expect(find.text('Verified by Razorpay'), findsOneWidget);
      expect(find.text('Payment received — order confirmed'), findsNothing);
    });

    testWidgets('flips to paid only when the BACKEND says paid', (tester) async {
      var paid = false;
      await _pump(tester, CheckoutPaySheet(
        orderId: 'o1',
        checkout: checkout(),
        razorpayCopy: rzpCopy(),
        createPayment: (_) async => qrPayload(),
        checkPaid: (_) async => <String, dynamic>{
          'paid': paid,
          if (paid) 'view': {...qrPayload(), 'paid': true, 'title': 'Payment received ✓'},
        },
      ));
      await tester.pumpAndSettle();

      // Time passing on its own confirms nothing.
      await tester.pump(kCheckoutPayPollInterval);
      await tester.pump();
      expect(find.text('Payment received — order confirmed'), findsNothing);

      paid = true;
      await tester.pump(kCheckoutPayPollInterval);
      await tester.pump();
      expect(find.text('Payment received — order confirmed'), findsOneWidget);

      // Stop the timer before the test ends.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a refusal prints the backend message with its Retry',
        (tester) async {
      await _pump(tester, CheckoutPaySheet(
        orderId: 'o1',
        checkout: checkout(),
        razorpayCopy: rzpCopy(),
        createPayment: (_) async => <String, dynamic>{
          'ok': false,
          'error': 'nothing_due',
          'message': 'Nothing due right now.',
        },
        checkPaid: (_) async => <String, dynamic>{'paid': false},
      ));
      await tester.pumpAndSettle();

      expect(find.text('Nothing due right now.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Could not prepare the QR right now.'), findsNothing);
    });

    testWidgets('an empty payload renders no invented copy', (tester) async {
      await _pump(tester, CheckoutPaySheet(
        orderId: 'o1',
        createPayment: (_) async => qrPayload(),
        checkPaid: (_) async => <String, dynamic>{'paid': false},
      ));
      await tester.pumpAndSettle();

      expect(find.text('Done'), findsNothing);
      expect(find.text('Pay to confirm your order'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });
  });
}
