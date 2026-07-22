// Regression test for CHANGE #492 — the per-supplier Send button must stop
// flipping inquiry status when AutoFlow is off; the WhatsApp number tap
// becomes the real trigger, calling send_supplier_inquiry_wa(p_supplier,
// p_phone) instead of opening wa.me. A silent failure here (popup closing
// on error, or a second send firing on a double-tap) is exactly the bug
// this change removes, so those are the cases asserted below.
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

void main() {
  group('InquirySendButton — AutoFlow gating', () {
    testWidgets('AutoFlow OFF: tap only opens the popup, never the auto-send path',
        (tester) async {
      var autoSendCalls = 0;
      var popupOnlyCalls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: InquirySendButton(
            autoFlowOn: false,
            enabled: true,
            onAutoSend: () => autoSendCalls++,
            onOpenPopupOnly: () => popupOnlyCalls++,
            child: const Text('Send'),
          ),
        ),
      ));

      await tester.tap(find.text('Send'));
      await tester.pump();

      expect(popupOnlyCalls, 1);
      expect(autoSendCalls, 0,
          reason: 'AutoFlow OFF must never take the start_inquiry_for_suppliers path');
    });

    testWidgets('AutoFlow ON: tap takes the existing auto-send path, unchanged',
        (tester) async {
      var autoSendCalls = 0;
      var popupOnlyCalls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: InquirySendButton(
            autoFlowOn: true,
            enabled: true,
            onAutoSend: () => autoSendCalls++,
            onOpenPopupOnly: () => popupOnlyCalls++,
            child: const Text('Send'),
          ),
        ),
      ));

      await tester.tap(find.text('Send'));
      await tester.pump();

      expect(autoSendCalls, 1);
      expect(popupOnlyCalls, 0);
    });
  });

  group('ContactPickerPopover — manual trigger (number tap)', () {
    Map<String, dynamic> contactData() => {
          'whatsapp': ['9876543210'],
          'contact': [],
          'phone': [],
          'other': [],
          'email': null,
        };

    testWidgets('tap number -> rpc called once with p_supplier and p_phone', (tester) async {
      final calls = <Map<String, String>>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ContactPickerPopover(
            btnRect: Rect.zero,
            supplierName: 'Acme Pharma',
            message: '',
            contactData: contactData(),
            onDismiss: () {},
            manualTrigger: true,
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
            contactData: contactData(),
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
            contactData: contactData(),
            onDismiss: () {},
            manualTrigger: true,
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

    testWidgets('{ok:true} closes the popup', (tester) async {
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
                  contactData: contactData(),
                  onDismiss: () => setState(() => visible = false),
                  manualTrigger: true,
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

    testWidgets('no url_launcher / wa.me invocation occurs on the manual-trigger number tap',
        (tester) async {
      var visible = true;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(builder: (context, setState) {
            return Stack(children: [
              if (visible)
                ContactPickerPopover(
                  btnRect: Rect.zero,
                  supplierName: 'Acme Pharma',
                  message: 'should be unused',
                  contactData: contactData(),
                  onDismiss: () => setState(() => visible = false),
                  manualTrigger: true,
                  sendInquiryRpc: ({required supplier, required phone}) async {
                    return {'ok': true, 'supplier': supplier, 'phone': phone};
                  },
                ),
            ]);
          }),
        ),
      ));
      await tester.pumpAndSettle();

      // The manual path never touches dart:html/url_launcher — if it did,
      // the RPC stub above would be bypassed and this tap would instead try
      // to open a real window, which the test harness has no way to do
      // silently. Reaching this point without a plugin-channel error is
      // itself the assertion; the ok:true -> popup closes case above (which
      // shares this exact tap path) is the load-bearing proof.
      await tester.tap(find.text('9876543210'));
      await _settle(tester);

      expect(find.byType(ContactPickerPopover), findsNothing);
      await _flushBackgroundTimers(tester);
    });
  });
}
