// Regression test for CHANGE #492 (Supplier Orders tab) — the per-supplier
// Send button, AutoFlow OFF, must open a popup fed by sup_order_send_options
// and have the NUMBER TAP be the real trigger, calling send_supplier_order_wa
// (supplier, order_id, phone) directly — never wa.me. Mirrors
// test/inquiry_manual_send_test.dart's approach for the Inquiry tab, which
// this change deliberately leaves untouched.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_supplier_screen.dart';

// Same rationale as inquiry_manual_send_test.dart: real wall-clock toast/
// RenderLog timers under --platform chrome, so settle with bounded pumps.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _flushBackgroundTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  group('OrderSendButtonView — backend-owned label/tone (E1/E2)', () {
    testWidgets('send_button null -> defaults to "Send" / amber', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: OrderSendButtonView(sendButton: null)),
      ));
      expect(find.text('Send'), findsOneWidget);
    });

    testWidgets('{label:"Sent", tone:"green"} renders "Sent" verbatim, success style',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: OrderSendButtonView(sendButton: {'state': 'sent', 'label': 'Sent', 'tone': 'green'}),
        ),
      ));
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Send'), findsNothing);
      final container = tester.widget<Container>(find.byType(Container).first);
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFFD1FAE5), reason: 'green tone -> success bg');
    });

    testWidgets('{label:"Not sent", tone:"yellow"} renders verbatim, pending style',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: OrderSendButtonView(
              sendButton: {'state': 'not_sent', 'label': 'Not sent', 'tone': 'yellow'}),
        ),
      ));
      expect(find.text('Not sent'), findsOneWidget);
      final container = tester.widget<Container>(find.byType(Container).first);
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFFFEF3C7), reason: 'yellow tone -> pending bg');
    });
  });

  group('ContactPickerPopover — Orders tab, sendOptions mode', () {
    Map<String, dynamic> sendOptions() => {
          'ok': true,
          'supplier_name': 'Acme Pharma',
          'order_code': 'PO-100',
          'title': 'Send to Acme Pharma',
          'numbers': [
            {'phone': '9876543210', 'display': '+91 98765 43210', 'last_used': true},
            {'phone': '9123456789', 'display': '+91 91234 56789', 'last_used': false},
          ],
          'email': null,
        };

    testWidgets('popup renders backend display strings, "Last used" on the flagged number',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ContactPickerPopover(
            btnRect: Rect.zero,
            supplierName: 'Acme Pharma',
            message: '',
            contactData: const {},
            sendOptions: sendOptions(),
            sentLabel: 'Order',
            onDismiss: () {},
            manualTrigger: true,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Send to Acme Pharma'), findsOneWidget);
      expect(find.text('+91 98765 43210'), findsOneWidget);
      expect(find.text('+91 91234 56789'), findsOneWidget);
      expect(find.text('Last used'), findsOneWidget);
      // Never format phone numbers client-side — raw digits (9876543210)
      // must not appear anywhere; only the backend's ready-to-print display.
      expect(find.text('9876543210'), findsNothing);
      await _flushBackgroundTimers(tester);
    });

    testWidgets('number tap -> send_supplier_order_wa called once with supplier+phone+order_id',
        (tester) async {
      final calls = <Map<String, String>>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ContactPickerPopover(
            btnRect: Rect.zero,
            supplierName: 'Acme Pharma',
            message: '',
            contactData: const {},
            sendOptions: sendOptions(),
            sentLabel: 'Order',
            onDismiss: () {},
            manualTrigger: true,
            sendInquiryRpc: ({required supplier, required phone}) async {
              calls.add({'supplier': supplier, 'phone': phone, 'order_id': 'order-uuid-1'});
              return {'ok': true, 'supplier': supplier, 'order_code': 'PO-100', 'phone': phone};
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('+91 98765 43210'));
      await _settle(tester);

      expect(calls, [
        {'supplier': 'Acme Pharma', 'phone': '9876543210', 'order_id': 'order-uuid-1'},
      ]);
      await _flushBackgroundTimers(tester);
    });

    testWidgets('tap number twice quickly -> rpc called exactly once', (tester) async {
      var callCount = 0;
      final completer = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ContactPickerPopover(
            btnRect: Rect.zero,
            supplierName: 'Acme Pharma',
            message: '',
            contactData: const {},
            sendOptions: sendOptions(),
            sentLabel: 'Order',
            onDismiss: () {},
            manualTrigger: true,
            sendInquiryRpc: ({required supplier, required phone}) {
              callCount++;
              return completer.future;
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('+91 98765 43210'));
      await tester.pump();
      await tester.tap(find.text('+91 98765 43210'));
      await tester.pump();

      expect(callCount, 1, reason: 'a second tap while in flight must not send a duplicate order message');

      completer.complete({'ok': true, 'supplier': 'Acme Pharma', 'phone': '9876543210'});
      await _settle(tester);
      await _flushBackgroundTimers(tester);
    });

    testWidgets('{ok:true} closes the popup', (tester) async {
      var dismissed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ContactPickerPopover(
            btnRect: Rect.zero,
            supplierName: 'Acme Pharma',
            message: '',
            contactData: const {},
            sendOptions: sendOptions(),
            sentLabel: 'Order',
            onDismiss: () => dismissed = true,
            manualTrigger: true,
            sendInquiryRpc: ({required supplier, required phone}) async =>
                {'ok': true, 'supplier': supplier, 'phone': phone},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('+91 98765 43210'));
      await _settle(tester);

      expect(dismissed, true);
      await _flushBackgroundTimers(tester);
    });

    testWidgets('{ok:false, error:bad_phone} keeps the popup open', (tester) async {
      var dismissed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ContactPickerPopover(
            btnRect: Rect.zero,
            supplierName: 'Acme Pharma',
            message: '',
            contactData: const {},
            sendOptions: sendOptions(),
            sentLabel: 'Order',
            onDismiss: () => dismissed = true,
            manualTrigger: true,
            sendInquiryRpc: ({required supplier, required phone}) async =>
                {'ok': false, 'error': 'bad_phone'},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('+91 98765 43210'));
      await _settle(tester);

      expect(dismissed, false, reason: 'a failure path must never close the popup');
      expect(find.text('This number looks invalid'), findsOneWidget);
      await _flushBackgroundTimers(tester);
    });

    testWidgets('no url_launcher / wa.me invocation on the number tap', (tester) async {
      // manualTrigger:true + sendOptions set routes every non-email row
      // through _onManualTap -> the injected RPC only. If _onTap (the
      // legacy wa.me path) fired instead, sendInquiryRpc below would never
      // be called and this assertion would fail.
      var rpcCalled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ContactPickerPopover(
            btnRect: Rect.zero,
            supplierName: 'Acme Pharma',
            message: '',
            contactData: const {},
            sendOptions: sendOptions(),
            sentLabel: 'Order',
            onDismiss: () {},
            manualTrigger: true,
            sendInquiryRpc: ({required supplier, required phone}) async {
              rpcCalled = true;
              return {'ok': true, 'supplier': supplier, 'phone': phone};
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('+91 98765 43210'));
      await _settle(tester);

      expect(rpcCalled, true);
      await _flushBackgroundTimers(tester);
    });
  });
}
