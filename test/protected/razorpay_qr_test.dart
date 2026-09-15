// PROTECTED — CHANGE #291.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the Razorpay QR sheet, never to make an unrelated change
// go green.
//
// This is the money path. The old manual flow let Dart compose what the
// customer saw (a UPI URI built in `buildUpiUri`, an amount re-formatted from a
// raw double) and then asked a human to confirm a screenshot. The Razorpay
// branch replaces all of that with strings the BACKEND finished, so what must
// never regress is:
//
//   1. Title, subtitle, amount and the note chip are payload strings, VERBATIM.
//   2. The amount appears EXACTLY ONCE, and only from `amount_label` — never
//      re-derived in Dart from `amount`, which is a raw number.
//   3. `qr_string` is drawn locally when it exists; `image_url` is used ONLY
//      when it does not (the offline rule: no second fetch when the payload
//      already carries the data).
//   4. Absence is absence: a missing note / amount row / subtitle renders
//      nothing, never a Dart default word.
//   5. `ok:false` is never drawn as a QR, and the status widget prints the
//      BACKEND's message — its own `message` outranks the machine `error` code.
//
// Fixtures mirror what razorpay-qr-create returns (rzp_qr_view). No network.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:pharma_b2b/widgets/razorpay_qr_card.dart';

const String _kAmount = '₹10,770.73';
const String _kTitle = 'Pay advance $_kAmount';
const String _kSubtitle =
    'Scan this QR in any UPI app. Payment confirms automatically — no screenshot needed.';
const String _kNote = 'Verified by Razorpay';
const String _kQrString = 'upi://pay?pa=rzp@icici&am=10770.73&cu=INR';
const String _kImageUrl = 'https://rzp.io/i/BWcUVrLp';

Map<String, dynamic> _payload({
  bool ok = true,
  String? qrString = _kQrString,
  String? imageUrl = _kImageUrl,
  String? amountLabel = _kAmount,
  String? amountRowLabel = 'Amount',
  String? noteLabel = _kNote,
  String? subtitle = _kSubtitle,
  bool paid = false,
  String? message,
  String? error,
}) =>
    {
      'ok': ok,
      'provider': 'razorpay_qr',
      'qr_id': 'a0b1',
      'rzp_qr_id': 'qr_ABC123',
      'image_url': imageUrl,
      'qr_string': qrString,
      // Deliberately present as a RAW number as well: nothing may format it.
      'amount': 10770.73,
      'amount_label': amountLabel,
      'amount_row_label': amountRowLabel,
      'kind': 'advance',
      'status': paid ? 'paid' : 'active',
      'title': _kTitle,
      'subtitle': subtitle,
      'note_label': noteLabel,
      'paid': paid,
      'paid_at_label': paid ? '4:12 pm on 23 Aug' : null,
      if (message != null) 'message': message,
      if (error != null) 'error': error,
    };

Future<void> _pumpCard(WidgetTester tester, Map<String, dynamic> payload) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: RazorpayQrCard(
          view: RzpQrView.fromPayload(payload),
          qrSize: kRzpQrSide,
        ),
      ),
    ),
  ));
  await tester.pump();
}

List<String> _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? '')
    .where((s) => s.isNotEmpty)
    .toList();

void main() {
  testWidgets('subtitle, amount and note render verbatim off the payload',
      (tester) async {
    await _pumpCard(tester, _payload());

    expect(find.text(_kSubtitle), findsOneWidget);
    expect(find.text('Amount'), findsOneWidget);
    expect(find.text(_kAmount), findsOneWidget);
    expect(find.text(_kNote), findsOneWidget);
  });

  testWidgets('the amount appears exactly once and is never re-formatted',
      (tester) async {
    await _pumpCard(tester, _payload());

    final hits = _allText(tester).where((s) => s.contains(_kAmount)).toList();
    expect(hits.length, 1, reason: 'amount must appear once; found: $hits');

    // The shape a Dart `toStringAsFixed(2)` on `amount` would have produced.
    expect(find.textContaining('10770.73'), findsNothing,
        reason: 'the payload string is the ONLY amount that may be printed');
  });

  testWidgets('qr_string is drawn locally; image_url is not fetched',
      (tester) async {
    await _pumpCard(tester, _payload());

    expect(RzpQrView.fromPayload(_payload()).qrSource, 'local');
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.byType(Image), findsNothing,
        reason: 'a payload that carries qr_string must not hit the network');
  });

  testWidgets('image_url is used ONLY when qr_string is absent', (tester) async {
    await _pumpCard(tester, _payload(qrString: null));

    expect(RzpQrView.fromPayload(_payload(qrString: null)).qrSource, 'network');
    expect(find.byType(QrImageView), findsNothing);
    final img = tester.widget<Image>(find.byType(Image));
    expect((img.image as NetworkImage).url, _kImageUrl);
  });

  testWidgets('neither QR source means no QR box at all', (tester) async {
    await _pumpCard(tester, _payload(qrString: null, imageUrl: null));

    expect(find.byType(QrImageView), findsNothing);
    expect(find.byType(Image), findsNothing);
    final v = RzpQrView.fromPayload(_payload(qrString: null, imageUrl: null));
    expect(v.hasQr, isFalse);
    expect(v.qrSource, 'none');
  });

  testWidgets('absence is absence — no Dart default words fill the gaps',
      (tester) async {
    await _pumpCard(tester,
        _payload(noteLabel: null, subtitle: null, amountRowLabel: null));

    expect(find.text(_kNote), findsNothing);
    expect(find.text(_kSubtitle), findsNothing);
    expect(find.text('Amount'), findsNothing);
    // With no row label there is no amount row either — and so no orphan ₹.
    for (final s in _allText(tester)) {
      expect(s.contains('₹'), isFalse,
          reason: 'no amount row must print no currency at all: "$s"');
    }
  });

  testWidgets('a paid QR shows the backend paid time, not a computed one',
      (tester) async {
    await _pumpCard(tester, _payload(paid: true));

    expect(find.text('4:12 pm on 23 Aug'), findsOneWidget);
  });

  test('ok:false is never a drawable view', () {
    final v = RzpQrView.fromPayload(_payload(ok: false));
    expect(v.ok, isFalse);
  });

  test('the backend message outranks the machine error code', () {
    final v = RzpQrView.fromPayload(
        _payload(ok: false, message: 'Nothing due right now.', error: 'nothing_due'));
    expect(v.error, 'Nothing due right now.',
        reason: 'a human message must never be replaced by the error slug');

    final bare = RzpQrView.fromPayload(_payload(ok: false, error: 'nothing_due'));
    expect(bare.error, 'nothing_due');
  });

  test('an empty payload renders as a total absence, never as defaults', () {
    final v = RzpQrView.fromPayload(null);
    expect(v.ok, isFalse);
    expect(v.title, '');
    expect(v.subtitle, '');
    expect(v.amountLabel, '');
    expect(v.noteLabel, '');
    expect(v.hasQr, isFalse);
  });

  testWidgets('the status widget prints the backend message and retry label',
      (tester) async {
    var retried = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RazorpayQrStatus(
          loading: false,
          message: 'Could not prepare the QR right now.',
          retryLabel: 'Try again',
          onRetry: () => retried++,
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Could not prepare the QR right now.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('loading shows a spinner and no retry button', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RazorpayQrStatus(
          loading: true,
          message: 'Preparing your QR…',
          retryLabel: 'Try again',
          onRetry: () {},
        ),
      ),
    ));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Preparing your QR…'), findsOneWidget);
    expect(find.text('Try again'), findsNothing,
        reason: 'nothing to retry while the request is still in flight');
  });
}
