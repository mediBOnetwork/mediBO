// Regression test for CHANGE #484 — customer pay popup:
//  t1: WhatsApp mini-popup must show a saved number from
//      customer_order_wa_numbers({"numbers":[...]}) instead of "No saved
//      number" (the old code assumed the RPC returned a bare List, but it
//      returns a Map wrapping a "numbers" list).
//  t2: Download QR must build the CUSTOM popup amount's payload (am=264.5),
//      not the generic no-amount account QR.
//
// RPCs and the platform-only PNG/download path are injected via
// CustPaySheet's fetchWaNumbers/sendQr/qrImageBuilder/downloadSink params —
// no network, no dart:html download actually fires.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/cust_pay_panel.dart';

void main() {
  testWidgets(
      't1: WhatsApp popup shows the saved number from customer_order_wa_numbers, not "No saved number"',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustPaySheet(
          qrData: 'upi://pay?pa=test@upi&pn=Test&am=100.0&cu=INR',
          vpa: 'test@upi',
          bankingName: 'Test Banking',
          payLabel: 'Pay Advance',
          orderId: 'order-1',
          amount: 100,
          kind: 'advance',
          fetchWaNumbers: (orderId) async => {
            'numbers': [
              {'phone': '8357881873', 'label': 'WhatsApp', 'last_used': false},
            ],
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('WhatsApp'));
    await tester.pumpAndSettle();

    expect(find.textContaining('8357881873'), findsOneWidget);
    expect(find.text('No saved number'), findsNothing);

    // Drain RenderLog's 800ms Supabase-flush debounce Timer before teardown.
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('t2: Download QR builds the custom-amount payload, not the generic account QR',
      (tester) async {
    String? capturedPayload;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustPaySheet(
          qrData: 'upi://pay?pa=test@upi&pn=Test&am=264.5&cu=INR',
          vpa: 'test@upi',
          bankingName: 'Test Banking',
          payLabel: 'Pay Advance',
          orderId: 'order-1',
          amount: 264.50,
          kind: 'advance',
          qrImageBuilder: ({
            required String qrPayload,
            required String vpa,
            required String bankingName,
            String? payLabel,
          }) async {
            capturedPayload = qrPayload;
            return Uint8List(0);
          },
          downloadSink: (bytes, filename, mimeType) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Download QR'));
    await tester.pumpAndSettle();

    expect(capturedPayload, isNotNull);
    expect(capturedPayload, contains('am=264.5'));

    await tester.pump(const Duration(milliseconds: 900));
  });
}
