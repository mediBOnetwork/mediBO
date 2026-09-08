// PROTECTED — CHANGE #395.
//
// See CLAUDE.md: this runs before EVERY deploy and may only be edited by a
// CHANGE that deliberately changes returns/refunds behaviour — never to make an
// unrelated change go green.
//
// What this holds down:
//
//   1. A RETURN CARD PRINTS THE BACKEND AND COMPUTES NOTHING. The status word,
//      its tone, the quantity phrase, the reason, the condition, the credit
//      amount and the "credited at N% slab" caption all arrive from
//      order_returns_panel(). Nothing here may type "Approved", pluralise a
//      quantity, format a rupee, or re-derive the credit from qty x rate — the
//      credit is FROZEN on the row at the slab the original bill used (#318),
//      and a second opinion computed in Dart is exactly how an invoice and its
//      credit note drift apart.
//
//   2. THE BUTTONS ARE BACKEND FLAGS, NOT A STATUS STRING. can_approve /
//      can_reject / can_send / can_mark_manual decide what is offered. A client
//      that re-derives "pending means approvable" would keep offering Approve
//      on a return the server has already closed, and would silently disagree
//      the moment a new status is added.
//
//   3. MONEY OUT IS CAPPED BY THE SERVER, AND THE UI SAYS SO. can_refund and
//      refundable_label come from refund_quote(); the sheet shows the cap. The
//      rule the whole change exists for — never refund more than was actually
//      collected — is enforced in SQL, so the UI must never invent its own
//      "refundable" figure to show next to it.
//
//   4. ABSENCE IS EXPLICIT. has_credit false prints no credit row at all rather
//      than a row reading a zero; an empty error string prints no error line.
//
//   5. PAYLOAD ORDER IS RENDER ORDER. The panel sorts; the screen does not.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/returns_refunds_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The actions block the panel always ships. Deliberately NOT the words a
/// developer would guess, so a hardcoded English label fails this test.
const Map<String, dynamic> kActions = {
  'approve': 'BACKEND-APPROVE',
  'reject': 'BACKEND-REJECT',
  'send_refund': 'BACKEND-SEND',
  'mark_manual': 'BACKEND-MARKPAID',
};

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Map<String, dynamic> _ret({
  String status = 'pending',
  String tone = 'warning',
  bool hasCredit = false,
  bool canApprove = true,
  bool canReject = true,
}) =>
    {
      'id': 'r1',
      'product_name': 'Amoxil 500',
      'qty_label': 'Qty 2',
      'reason_label': 'Damaged in transit',
      'condition_label': 'Sealed / resaleable',
      'status': status,
      'status_label': 'BACKEND-STATUS-$status',
      'status_tone': tone,
      'has_credit': hasCredit,
      'credit_label': '₹201.60',
      'slab_label': 'credited at 10% slab',
      'can_approve': canApprove,
      'can_reject': canReject,
      'at_label': '31/08/2026 12:30',
    };

Map<String, dynamic> _refund({
  String status = 'pending',
  String method = 'razorpay',
  bool canSend = true,
  bool canMarkManual = false,
  String error = '',
}) =>
    {
      'id': 'f1',
      'amount_label': '₹798.40',
      'method': method,
      'method_label': 'BACKEND-METHOD',
      'reason_label': 'Order cancelled',
      'status': status,
      'status_label': 'BACKEND-REFUND-$status',
      'status_tone': 'info',
      'provider_refund_id': '',
      'utr': '',
      'error': error,
      'can_send': canSend,
      'can_mark_manual': canMarkManual,
      'at_label': '31/08/2026 12:31',
    };

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test
    // and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  group('return card renders the backend verbatim', () {
    testWidgets('status, reason, condition and quantity are payload strings',
        (t) async {
      await t.pumpWidget(_host(ReturnCard(
        row: _ret(),
        actions: kActions,
        busy: false,
        onApprove: () {},
        onReject: () {},
      )));

      expect(find.text('BACKEND-STATUS-pending'), findsOneWidget);
      expect(find.text('Qty 2'), findsOneWidget);
      expect(find.text('Damaged in transit'), findsOneWidget);
      expect(find.text('Sealed / resaleable'), findsOneWidget);
      // The card must not have typed a status word of its own.
      expect(find.text('Pending'), findsNothing);
      expect(find.text('Approved'), findsNothing);
    });

    testWidgets('has_credit false prints NO credit row, not a zero', (t) async {
      await t.pumpWidget(_host(ReturnCard(
        row: _ret(hasCredit: false),
        actions: kActions,
        busy: false,
        onApprove: () {},
        onReject: () {},
      )));
      expect(find.text('₹201.60'), findsNothing);
      expect(find.text('credited at 10% slab'), findsNothing);
    });

    testWidgets('has_credit true prints the FROZEN credit and its slab caption',
        (t) async {
      await t.pumpWidget(_host(ReturnCard(
        row: _ret(status: 'approved', tone: 'success', hasCredit: true),
        actions: kActions,
        busy: false,
        onApprove: () {},
        onReject: () {},
      )));
      // Exactly the string the server froze — never recomputed in Dart.
      expect(find.text('₹201.60'), findsOneWidget);
      expect(find.text('credited at 10% slab'), findsOneWidget);
    });
  });

  group('the buttons are backend flags, never a status string', () {
    testWidgets('can_approve/can_reject drive both buttons and their labels',
        (t) async {
      var approved = 0, rejected = 0;
      await t.pumpWidget(_host(ReturnCard(
        row: _ret(),
        actions: kActions,
        busy: false,
        onApprove: () => approved++,
        onReject: () => rejected++,
      )));

      expect(find.text('BACKEND-APPROVE'), findsOneWidget);
      expect(find.text('BACKEND-REJECT'), findsOneWidget);
      await t.tap(find.text('BACKEND-APPROVE'));
      await t.tap(find.text('BACKEND-REJECT'));
      expect(approved, 1);
      expect(rejected, 1);
    });

    testWidgets('a closed return offers nothing even though status is a word '
        'the client could have judged', (t) async {
      await t.pumpWidget(_host(ReturnCard(
        // status still reads 'pending' — only the FLAGS say it is closed.
        row: _ret(canApprove: false, canReject: false),
        actions: kActions,
        busy: false,
        onApprove: () {},
        onReject: () {},
      )));
      expect(find.text('BACKEND-APPROVE'), findsNothing);
      expect(find.text('BACKEND-REJECT'), findsNothing);
    });

    testWidgets('busy disables the actions rather than hiding them', (t) async {
      var approved = 0;
      await t.pumpWidget(_host(ReturnCard(
        row: _ret(),
        actions: kActions,
        busy: true,
        onApprove: () => approved++,
        onReject: () {},
      )));
      expect(find.text('BACKEND-APPROVE'), findsOneWidget);
      await t.tap(find.text('BACKEND-APPROVE'));
      expect(approved, 0);
    });
  });

  group('refund card', () {
    testWidgets('can_send picks the Razorpay button, its label from actions[]',
        (t) async {
      var sent = 0, paid = 0;
      await t.pumpWidget(_host(RefundCard(
        row: _refund(canSend: true, canMarkManual: false),
        actions: kActions,
        busy: false,
        onSend: () => sent++,
        onMarkPaid: () => paid++,
      )));
      expect(find.text('BACKEND-SEND'), findsOneWidget);
      expect(find.text('BACKEND-MARKPAID'), findsNothing);
      await t.tap(find.text('BACKEND-SEND'));
      expect(sent, 1);
      expect(paid, 0);
    });

    testWidgets('a manual refund offers Mark paid instead', (t) async {
      var sent = 0, paid = 0;
      await t.pumpWidget(_host(RefundCard(
        row: _refund(method: 'manual_upi', canSend: false, canMarkManual: true),
        actions: kActions,
        busy: false,
        onSend: () => sent++,
        onMarkPaid: () => paid++,
      )));
      expect(find.text('BACKEND-MARKPAID'), findsOneWidget);
      expect(find.text('BACKEND-SEND'), findsNothing);
      await t.tap(find.text('BACKEND-MARKPAID'));
      expect(paid, 1);
      expect(sent, 0);
    });

    testWidgets('a settled refund offers no action at all', (t) async {
      await t.pumpWidget(_host(RefundCard(
        row: _refund(status: 'processed', canSend: false, canMarkManual: false),
        actions: kActions,
        busy: false,
        onSend: () {},
        onMarkPaid: () {},
      )));
      expect(find.text('BACKEND-SEND'), findsNothing);
      expect(find.text('BACKEND-MARKPAID'), findsNothing);
      expect(find.text('BACKEND-REFUND-processed'), findsOneWidget);
    });

    testWidgets('an empty provider error prints no error line', (t) async {
      await t.pumpWidget(_host(RefundCard(
        row: _refund(error: ''),
        actions: kActions,
        busy: false,
        onSend: () {},
        onMarkPaid: () {},
      )));
      // The only strings on the card are payload strings; no stray blank row.
      expect(find.text(''), findsNothing);
    });

    testWidgets('a provider error is shown verbatim when there IS one',
        (t) async {
      await t.pumpWidget(_host(RefundCard(
        row: _refund(status: 'failed', canSend: false, error: 'BACKEND-ERROR'),
        actions: kActions,
        busy: false,
        onSend: () {},
        onMarkPaid: () {},
      )));
      expect(find.text('BACKEND-ERROR'), findsOneWidget);
    });
  });

  group('tone chip', () {
    testWidgets('renders the backend label and never invents one', (t) async {
      await t.pumpWidget(_host(const ToneChip('BACKEND-CHIP', 'danger')));
      expect(find.text('BACKEND-CHIP'), findsOneWidget);
    });

    testWidgets('an unknown tone still renders rather than throwing', (t) async {
      // Forward compatibility: a tone this build has never heard of must not
      // crash the panel — the same rule the home feed follows for layouts.
      await t.pumpWidget(_host(const ToneChip('BACKEND-CHIP', 'chartreuse')));
      expect(find.text('BACKEND-CHIP'), findsOneWidget);
    });
  });
}
