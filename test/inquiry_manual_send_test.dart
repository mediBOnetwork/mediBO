// Regression test for CHANGE #493 — the number tap must ALWAYS call the
// WhatsApp Cloud API RPC, in every AutoFlow state, on the Supplier Inquiry
// tab. #492 shipped a bug: with AutoFlow ON the number tap still ran the old
// wa.me path, so nothing went through the Cloud API despite the button
// looking identical. #493's fix is structural, not conditional — AutoFlow is
// no longer a parameter InquirySendButton or ContactPickerPopover even
// accept, so there is no toggle left to branch on. The "AutoFlow ON/OFF"
// labels below exist only to spell out, per spec, that both states hit the
// exact same code.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_supplier_screen.dart';

// Widget-under-test constructs its own toast/RenderLog timers (a real 800ms
// Supabase-flush debounce and a real 4s toast auto-dismiss) that flutter_test
// flags as leaked if still pending at tearDown. Under --platform chrome those
// are real wall-clock timers (no FakeAsync), and pumpAndSettle() gets thrown
// off by the toast's independently-ticking AnimationController racing the
// popover's own — so settling is done with bounded explicit pumps instead.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _flushBackgroundTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
}

Map<String, dynamic> _contactData() => {
      'whatsapp': ['9876543210'],
      'contact': [],
      'phone': [],
      'other': [],
      'email': null,
    };

void main() {
  group('InquirySendButton — exactly one tap path (CHANGE #493)', () {
    testWidgets('tap always calls onOpenPopupOnly — the widget has no AutoFlow input to branch on',
        (tester) async {
      var popupOnlyCalls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: InquirySendButton(
            enabled: true,
            onOpenPopupOnly: () => popupOnlyCalls++,
            child: const Text('Send'),
          ),
        ),
      ));

      await tester.tap(find.text('Send'));
      await tester.pump();

      expect(popupOnlyCalls, 1);
      // Structural proof there is no second path: onAutoSend/autoFlowOn no
      // longer exist as constructor parameters at all (compile-time fact —
      // this file would fail to build if #492's branch had survived).
    });
  });

  group('ContactPickerPopover — number tap always calls the Cloud API RPC, regardless of AutoFlow (#493)', () {
    for (final scenario in [('AutoFlow ON', true), ('AutoFlow OFF', false)]) {
      final label = scenario.$1;

      testWidgets('$label, inquiry number tap -> send_supplier_inquiry_wa called, url_launcher NOT called',
          (tester) async {
        final calls = <Map<String, String>>[];
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: ContactPickerPopover(
              btnRect: Rect.zero,
              supplierName: 'Acme Pharma',
              message: '',
              contactData: _contactData(),
              onDismiss: () {},
              sendInquiryRpc: ({required supplier, required phone}) async {
                calls.add({'supplier': supplier, 'phone': phone});
                return {'ok': true, 'supplier': supplier, 'phone': phone, 'status': 'pending'};
              },
            ),
          ),
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.text('9876543210'));
        await _settle(tester);

        expect(calls, [
          {'supplier': 'Acme Pharma', 'phone': '9876543210'},
        ]);
        // Reaching this point without a plugin-channel error IS the
        // "url_launcher not called" proof — dart:html/url_launcher aren't
        // stubbed in this harness, so a real launch attempt would throw.
        await _flushBackgroundTimers(tester);
      });
    }

    testWidgets('tap number twice quickly -> rpc called exactly once', (tester) async {
      var callCount = 0;
      final completer = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ContactPickerPopover(
            btnRect: Rect.zero,
            supplierName: 'Acme Pharma',
            message: '',
            contactData: _contactData(),
            onDismiss: () {},
            sendInquiryRpc: ({required supplier, required phone}) {
              callCount++;
              return completer.future;
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('9876543210'));
      await tester.pump();
      await tester.tap(find.text('9876543210'));
      await tester.pump();

      expect(callCount, 1, reason: 'a second tap while in flight must not send a duplicate message');

      completer.complete({'ok': true, 'supplier': 'Acme Pharma', 'phone': '9876543210'});
      await _settle(tester);
      await _flushBackgroundTimers(tester);
    });

    testWidgets('{ok:false, error:bad_phone} keeps the popup open', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ContactPickerPopover(
            btnRect: Rect.zero,
            supplierName: 'Acme Pharma',
            message: '',
            contactData: _contactData(),
            onDismiss: () {},
            sendInquiryRpc: ({required supplier, required phone}) async {
              return {'ok': false, 'error': 'bad_phone'};
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('9876543210'));
      await _settle(tester);

      expect(find.byType(ContactPickerPopover), findsOneWidget,
          reason: 'a failed send must never close the popup — that reads as sent when it was not');
      await _flushBackgroundTimers(tester);
    });

    testWidgets('{ok:true} closes the popup and refetches the overview', (tester) async {
      var refetchCalls = 0;
      var visible = true;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(builder: (context, setState) {
            return Stack(children: [
              if (visible)
                ContactPickerPopover(
                  btnRect: Rect.zero,
                  supplierName: 'Acme Pharma',
                  message: '',
                  contactData: _contactData(),
                  onDismiss: () => setState(() => visible = false),
                  onManualSendSuccess: () async => refetchCalls++,
                  sendInquiryRpc: ({required supplier, required phone}) async {
                    return {'ok': true, 'supplier': supplier, 'phone': phone};
                  },
                ),
            ]);
          }),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('9876543210'));
      await _settle(tester);

      expect(find.byType(ContactPickerPopover), findsNothing);
      expect(refetchCalls, 1, reason: 'success must refetch the card from the backend, not hand-compute the chip');
      await _flushBackgroundTimers(tester);
    });
  });

  group('SendButtonView — Inquiry tab backend-owned label/tone (C1-C3)', () {
    testWidgets('not sent -> {label:"Send", tone:"yellow"} renders "Send" amber', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SendButtonView(sendButton: {'state': 'not_sent', 'label': 'Send', 'tone': 'yellow'}),
        ),
      ));
      expect(find.text('Send'), findsOneWidget);
      final container = tester.widget<Container>(find.byType(Container).first);
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFFFEF3C7), reason: 'yellow tone -> pending/amber bg');
    });

    testWidgets('sent but NOT delivered -> STILL {label:"Send", tone:"yellow"} — C2 rule',
        (tester) async {
      // The inquiry mapping is deliberately different from Orders: a send
      // that hasn't been confirmed delivered is not green. This is backend-
      // computed (send_button.tone), so the test only proves the client
      // renders exactly what it's given — not that it re-derives the rule.
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SendButtonView(sendButton: {'state': 'sent', 'label': 'Send', 'tone': 'yellow'}),
        ),
      ));
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Sent'), findsNothing);
      final container = tester.widget<Container>(find.byType(Container).first);
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFFFEF3C7));
    });

    testWidgets('sent AND delivered -> {label:"Sent", tone:"green"} renders "Sent" green',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SendButtonView(sendButton: {'state': 'delivered', 'label': 'Sent', 'tone': 'green'}),
        ),
      ));
      expect(find.text('Sent'), findsOneWidget);
      final container = tester.widget<Container>(find.byType(Container).first);
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFFD1FAE5), reason: 'green tone -> only a confirmed delivery');
    });
  });
}
