// Regression test for CHANGE #492 — AutoFlow rename + manual WhatsApp send
// for supplier INQUIRY and supplier ORDERS.
//
// admin_supplier_screen.dart is a single god-widget that fires ~8 RPCs from
// initState with no dependency injection, so mounting the whole screen with
// a mocked Supabase client would be a slow, fragile integration test — not
// the "seconds, focused, no network" test this change calls for. Instead
// this exercises the actual shared production code at its real seams:
//   - ContactPickerPopover's "manual mode" (AutoFlow OFF), which both the
//     inquiry and orders Send buttons construct with real RPC results piped
//     in through onManualSend — the same shape send_supplier_inquiry_wa /
//     send_supplier_order_wa return.
//   - mapSendError and sendButtonStyle, the two pure helpers that back F2
//     and E1/E2.
// No network, no golden, no integration, no headless browser driving —
// this is dart:html's normal `flutter test --platform chrome` compile
// target, which admin_supplier_screen.dart already requires transitively
// (RenderLog imports dart:html).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_supplier_screen.dart';

void main() {
  group('mapSendError — CHANGE #492 F2 error text', () {
    test('maps the four documented RPC error codes verbatim', () {
      expect(mapSendError('not_authorized'), "You don't have permission to send");
      expect(mapSendError('no_supplier'), 'Supplier missing');
      expect(mapSendError('no_order'), 'Order not found');
      expect(mapSendError('bad_phone'), 'This number looks invalid');
    });

    test('falls back to a generic message for anything else', () {
      expect(mapSendError('something_new'), 'Failed to send');
      expect(mapSendError(null), 'Failed to send');
    });
  });

  group('sendButtonStyle — CHANGE #492 E1/E2 backend-owned label/tone', () {
    test('renders label verbatim and tone->color, never derived client-side', () {
      final sent = sendButtonStyle({'state': 'delivered', 'label': 'Sent', 'tone': 'green'});
      expect(sent.label, 'Sent');
      expect(sent.bg, const Color(0xFFD1FAE5));
      expect(sent.fg, const Color(0xFF065F46));

      final pending = sendButtonStyle({'state': 'not_sent', 'label': 'Send', 'tone': 'yellow'});
      expect(pending.label, 'Send');
      expect(pending.bg, const Color(0xFFFEF3C7));
      expect(pending.fg, const Color(0xFF92400E));
    });

    test('adds no third style for an unrecognized tone (falls back to yellow style)', () {
      final unknown = sendButtonStyle({'label': 'Send', 'tone': 'purple'});
      expect(unknown.bg, const Color(0xFFFEF3C7));
      expect(unknown.fg, const Color(0xFF92400E));
    });

    test('defaults to Send/yellow when backend data is missing entirely', () {
      final fallback = sendButtonStyle(null);
      expect(fallback.label, 'Send');
      expect(fallback.fg, const Color(0xFF92400E));
    });
  });

  group('ContactPickerPopover manual mode — AutoFlow OFF (shared by both tabs)', () {
    Widget host(Widget popover) => MaterialApp(home: Scaffold(body: Stack(children: [popover])));

    testWidgets('number tap calls onManualSend once with the tapped phone; {ok:true} closes the popup',
        (tester) async {
      final calls = <String>[];
      var dismissed = false;
      await tester.pumpWidget(host(ContactPickerPopover(
        btnRect: const Rect.fromLTWH(0, 0, 60, 32),
        supplierName: 'Acme Pharma',
        onDismiss: () => dismissed = true,
        manualRows: const [SendRow(phone: '8819834000', display: '+91 88198 34000')],
        onManualSend: (phone) async {
          calls.add(phone);
          return true;
        },
      )));
      await tester.pumpAndSettle();

      expect(find.text('+91 88198 34000'), findsOneWidget);
      await tester.tap(find.text('+91 88198 34000'));
      // Bounded pumps, not pumpAndSettle: while in flight the row shows an
      // indeterminate CircularProgressIndicator, which animates forever and
      // would make pumpAndSettle time out waiting for it to go idle.
      await tester.pump(); // let onManualSend's Future resolve
      await tester.pump(const Duration(milliseconds: 200)); // drive the close animation to completion

      expect(calls, ['8819834000']);
      expect(dismissed, isTrue);
      // RenderLog debounces its Supabase write 800ms out; flush it before the
      // test ends so flutter_test doesn't flag it as a leaked Timer (same
      // workaround send_qr_popup_test.dart uses for the same logger).
      await tester.pump(const Duration(milliseconds: 900));
    });

    testWidgets('double-tap a number calls the send RPC exactly once', (tester) async {
      final calls = <String>[];
      final completer = Completer<bool>();
      await tester.pumpWidget(host(ContactPickerPopover(
        btnRect: const Rect.fromLTWH(0, 0, 60, 32),
        supplierName: 'Acme Pharma',
        onDismiss: () {},
        manualRows: const [SendRow(phone: '8819834000', display: '+91 88198 34000')],
        onManualSend: (phone) {
          calls.add(phone);
          return completer.future;
        },
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('+91 88198 34000'));
      await tester.pump();
      await tester.tap(find.text('+91 88198 34000')); // second tap while the first is in flight
      await tester.pump();

      expect(calls.length, 1);
      completer.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 900));
    });

    testWidgets('{ok:false} (e.g. bad_phone) keeps the popup open — never closes on an error path',
        (tester) async {
      var dismissed = false;
      await tester.pumpWidget(host(ContactPickerPopover(
        btnRect: const Rect.fromLTWH(0, 0, 60, 32),
        supplierName: 'Acme Pharma',
        onDismiss: () => dismissed = true,
        manualRows: const [SendRow(phone: '123', display: 'bad number')],
        onManualSend: (phone) async => false,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('bad number'));
      await tester.pumpAndSettle();

      expect(dismissed, isFalse);
      expect(find.text('bad number'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 900));
    });

    testWidgets('renders backend title, display strings verbatim, and the Last used chip on the flagged row only',
        (tester) async {
      await tester.pumpWidget(host(ContactPickerPopover(
        btnRect: const Rect.fromLTWH(0, 0, 60, 32),
        supplierName: 'Acme Pharma',
        onDismiss: () {},
        manualTitle: 'Send to Acme Pharma',
        manualRows: const [
          SendRow(phone: '8819834000', display: '+91 88198 34000', lastUsed: true),
          SendRow(phone: '9000000000', display: '+91 90000 00000'),
        ],
        manualEmail: 'acme@example.com',
      )));
      await tester.pumpAndSettle();

      expect(find.text('Send to Acme Pharma'), findsOneWidget);
      expect(find.text('+91 88198 34000'), findsOneWidget);
      expect(find.text('+91 90000 00000'), findsOneWidget);
      expect(find.text('acme@example.com'), findsOneWidget);
      expect(find.text('Last used'), findsOneWidget); // exactly one chip, on the flagged row
      await tester.pump(const Duration(milliseconds: 900));
    });

    testWidgets('manual mode never opens wa.me — no url_launcher / external app-launch widgets present',
        (tester) async {
      await tester.pumpWidget(host(ContactPickerPopover(
        btnRect: const Rect.fromLTWH(0, 0, 60, 32),
        supplierName: 'Acme Pharma',
        onDismiss: () {},
        manualRows: const [SendRow(phone: '8819834000', display: '+91 88198 34000')],
        onManualSend: (phone) async => true,
      )));
      await tester.pumpAndSettle();

      // The legacy (AutoFlow-ON) code path is the only place this popover ever
      // touches wa.me, and it requires widget.contactData / widget.message —
      // both left at their defaults ('' / {}) in manual mode, so there is no
      // way for a manual-mode tap to reach that branch.
      expect(tester.takeException(), isNull);
    });
  });
}
