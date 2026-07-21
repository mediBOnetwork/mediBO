// Regression test for CHANGE #486 — customer pay popup, "max backend":
//  t1: the WhatsApp number row must show the backend's `display` field
//      verbatim, not a locally-rebuilt "phone · label" string.
//  t2: Download QR must request the backend's payment-qr-image render
//      (order_id/amount/kind) and download the returned url — no
//      client-side QR/image composition anymore.
// (The anchor-position test for the "Send QR to" popup moved to
// test/send_qr_popup_test.dart in CHANGE #488, once the anchor mechanism
// switched from a manually-computed Offset to CompositedTransformFollower.)
//
// RPCs/edge-function calls and the platform-only download path are
// injected via CustPaySheet's fetchWaNumbers/sendQr/fetchQrImage/
// downloadSink params — no network, no dart:html download actually fires.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/cust_pay_panel.dart';

CustPaySheet _sheet({
  Future<dynamic> Function(String orderId)? fetchWaNumbers,
  Future<Map<String, dynamic>> Function(String orderId, double amount, String kind)? fetchQrImage,
  void Function(String url, String filename)? downloadSink,
}) {
  return CustPaySheet(
    qrData: 'upi://pay?pa=test@upi&pn=Test&am=264.5&cu=INR',
    vpa: 'test@upi',
    bankingName: 'Test Banking',
    payLabel: 'Pay Advance',
    orderId: 'order-1',
    amount: 264.50,
    kind: 'advance',
    fetchWaNumbers: fetchWaNumbers,
    fetchQrImage: fetchQrImage,
    downloadSink: downloadSink,
  );
}

void main() {
  testWidgets('t1: WhatsApp row shows the backend display field verbatim, not a rebuilt phone/label string',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _sheet(
          fetchWaNumbers: (orderId) async => {
            'numbers': [
              {'phone': '8357881873', 'display': '8357881873', 'last_used': false},
            ],
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('WhatsApp'));
    await tester.pumpAndSettle();

    expect(find.text('8357881873'), findsOneWidget);
    // Verbatim backend display, not a rebuilt "phone · label" string.
    expect(find.text('8357881873 · WhatsApp'), findsNothing);
    expect(find.text('No saved number'), findsNothing);

    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('t2: Download QR invokes payment-qr-image with the popup amount/kind and downloads the backend url',
      (tester) async {
    String? invokedOrderId;
    double? invokedAmount;
    String? invokedKind;
    String? downloadedUrl;
    String? downloadedFilename;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _sheet(
          fetchQrImage: (orderId, amount, kind) async {
            invokedOrderId = orderId;
            invokedAmount = amount;
            invokedKind = kind;
            return {'url': 'https://signed.example/mediBO-pay-264.5.jpg', 'filename': 'mediBO-pay-264.5.jpg'};
          },
          downloadSink: (url, filename) {
            downloadedUrl = url;
            downloadedFilename = filename;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Download QR'));
    await tester.pumpAndSettle();

    expect(invokedOrderId, 'order-1');
    expect(invokedAmount, 264.5);
    expect(invokedKind, 'advance');
    expect(downloadedUrl, 'https://signed.example/mediBO-pay-264.5.jpg');
    expect(downloadedFilename, 'mediBO-pay-264.5.jpg');

    await tester.pump(const Duration(milliseconds: 900));
  });
}
