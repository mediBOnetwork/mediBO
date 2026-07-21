// Regression test for CHANGE #490 — customer pay popup's Download QR button
// must capture the QR card already rendered on screen (RepaintBoundary +
// GlobalKey → toImage) instead of calling the payment-qr-image edge
// function. No network, no golden/pixel comparison — just proof the capture
// path fires and produces a real PNG.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:pharma_b2b/widgets/cust_pay_panel.dart';

CustPaySheet _sheet({void Function(Uint8List bytes, String filename)? downloadBytesSink}) {
  return CustPaySheet(
    qrData: 'upi://pay?pa=test@upi&pn=Test&am=264.5&cu=INR',
    vpa: 'test@upi',
    bankingName: 'Test Banking',
    payLabel: 'Pay Advance',
    orderId: 'order-1',
    amount: 264.50,
    kind: 'advance',
    downloadBytesSink: downloadBytesSink,
  );
}

void main() {
  testWidgets('a: the QR card is wrapped in a RepaintBoundary keyed for capture', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: _sheet())));
    await tester.pumpAndSettle();

    final cardFinder = find.byKey(const GlobalObjectKey('c490_qr_download_card'));
    expect(cardFinder, findsOneWidget);
    expect(tester.widget(cardFinder), isA<RepaintBoundary>());
    expect(
      find.descendant(of: cardFinder, matching: find.byType(QrImageView)),
      findsOneWidget,
    );
  });

  testWidgets(
      'b: Download QR captures the on-screen boundary (real PNG bytes) and never touches Supabase',
      (tester) async {
    Uint8List? capturedBytes;
    String? capturedFilename;

    // Supabase.initialize() is never called in this test — if the download
    // path tried functions.invoke('payment-qr-image') (or any Supabase
    // call), Supabase.instance would throw before the sink below could ever
    // receive bytes, and tester.takeException() would be non-null.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _sheet(
          downloadBytesSink: (bytes, filename) {
            capturedBytes = bytes;
            capturedFilename = filename;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.text('Download QR'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(capturedFilename, 'mediBO-pay-264.5.png');
    expect(capturedBytes, isNotNull);
    expect(capturedBytes!.length, greaterThan(0));
    // PNG signature — proves a real image was captured, not a stub.
    expect(capturedBytes!.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
  });
}
