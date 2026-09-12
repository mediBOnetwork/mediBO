// PROTECTED — CHANGE #400. Partner operations: workers, settlement
// acknowledgement, zone onboarding.
//
// What this file holds down, in one sentence: none of these three surfaces may
// ever decide anything the backend decides. The role and attendance options are
// the payload's, the Agree/Dispute buttons exist only because the payload said
// can_act, and the SAME ack card is rendered to the partner and to the admin so
// the two can never drift on what the partner said.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/partner/partner_workers_screen.dart';
import 'package:pharma_b2b/screens/partner/settlement_ack_card.dart';
import 'package:pharma_b2b/utils/render_log.dart';

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: child));

  // ── Workers ───────────────────────────────────────────────────────────────
  const workers = <String, dynamic>{
    'ok': true,
    'intro': 'Your zone’s counting and packing staff.',
    'can_write': true,
    'add_label': 'Add worker',
    'remove_label': 'Remove',
    'empty_text': 'No workers yet.',
    'shift_title': 'On shift today',
    'shift_hint': 'Tap a worker to mark today’s attendance.',
    'today_label': '01/09/2026',
    'role_options': [
      {'value': 'counting', 'label': 'Counting'},
      {'value': 'both', 'label': 'Counting and packing'},
    ],
    'shift_options': [
      {'value': 'present', 'label': 'Present', 'tone': 'success'},
      {'value': 'absent', 'label': 'Absent', 'tone': 'danger'},
    ],
    'rows': [
      {
        'id': 2,
        'name': 'Ramesh Kumar',
        'identity': '9876500011',
        'role': 'counting',
        'role_label': 'Counting',
        'shift': 'present',
        'shift_label': 'Present',
        'shift_tone': 'success',
      },
    ],
  };

  testWidgets('worker row prints the backend status label, never a computed one',
      (t) async {
    await t.pumpWidget(host(PartnerWorkersView(
      payload: workers, onAdd: () {}, onRemove: (_) {}, onShift: (_, __) {})));
    await t.pump();
    expect(find.text('Ramesh Kumar'), findsOneWidget);
    expect(find.text('Present'), findsWidgets);
    expect(find.text('9876500011 · Counting'), findsOneWidget);
  });

  testWidgets('only the attendance options the backend sent can be chosen',
      (t) async {
    await t.pumpWidget(host(PartnerWorkersView(
      payload: workers, onAdd: () {}, onRemove: (_) {}, onShift: (_, __) {})));
    await t.pump();
    // 'half' is a real backend state but this payload did not offer it.
    expect(find.widgetWithText(ChoiceChip, 'Absent'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Half day'), findsNothing);
  });

  testWidgets('marking attendance sends the option value, not its label',
      (t) async {
    String? sent;
    await t.pumpWidget(host(PartnerWorkersView(
      payload: workers,
      onAdd: () {},
      onRemove: (_) {},
      onShift: (_, s) => sent = s)));
    await t.pump();
    await t.tap(find.widgetWithText(ChoiceChip, 'Absent'));
    await t.pump();
    expect(sent, 'absent');
  });

  testWidgets('can_write:false removes Add and the per-row controls entirely',
      (t) async {
    await t.pumpWidget(host(PartnerWorkersView(
      payload: {...workers, 'can_write': false},
      onAdd: null,
      onRemove: (_) {},
      onShift: (_, __) {})));
    await t.pump();
    expect(find.text('Add worker'), findsNothing);
    expect(find.text('Remove'), findsNothing);
    // The row itself is still readable.
    expect(find.text('Ramesh Kumar'), findsOneWidget);
  });

  testWidgets('no workers renders the backend empty sentence', (t) async {
    await t.pumpWidget(host(PartnerWorkersView(
      payload: {...workers, 'rows': const []},
      onAdd: () {},
      onRemove: (_) {},
      onShift: (_, __) {})));
    await t.pump();
    expect(find.text('No workers yet.'), findsOneWidget);
  });

  // ── Settlement acknowledgement ────────────────────────────────────────────
  const ackNone = <String, dynamic>{
    'heading': 'Do you agree with this statement?',
    'hint': 'Agreeing records your acknowledgement.',
    'state': 'none',
    'state_label': 'Not acknowledged yet',
    'state_tone': 'neutral',
    'note': '',
    'by_label': '',
    'can_act': true,
    'agree_label': 'Agree',
    'dispute_label': 'Dispute',
    'note_hint': 'What is wrong with this period?',
    'can_resolve': false,
    'resolve_label': 'Resolve dispute',
    'frozen': false,
    'frozen_text': '',
  };

  const ackDisputedAdmin = <String, dynamic>{
    'heading': 'Partner acknowledgement',
    'hint': '',
    'state': 'disputed',
    'state_label': 'Disputed',
    'state_tone': 'danger',
    'note': 'Delivery cost for 12 orders looks doubled',
    'by_label': 'test.partner1@medibo.in on 01/09/2026',
    'can_act': false,
    'agree_label': 'Agree',
    'dispute_label': 'Dispute',
    'note_hint': 'What is wrong with this period?',
    'can_resolve': true,
    'resolve_label': 'Resolve dispute',
    'frozen': true,
    'frozen_text': 'Payout frozen while this period is disputed.',
  };

  testWidgets('the partner gets Agree and Dispute when can_act is true',
      (t) async {
    await t.pumpWidget(host(SettlementAckCard(
      ack: ackNone, onAgree: (_) {}, onDispute: (_) {})));
    await t.pump();
    expect(find.text('Agree'), findsOneWidget);
    expect(find.text('Dispute'), findsOneWidget);
    expect(find.text('Not acknowledged yet'), findsOneWidget);
  });

  testWidgets('an already-disputed period offers the partner no buttons',
      (t) async {
    await t.pumpWidget(host(SettlementAckCard(
      ack: {...ackDisputedAdmin, 'can_resolve': false},
      onAgree: (_) {},
      onDispute: (_) {})));
    await t.pump();
    expect(find.text('Agree'), findsNothing);
    expect(find.text('Dispute'), findsNothing);
    // The state and the partner's own words still print.
    expect(find.text('Disputed'), findsOneWidget);
    expect(find.text('Delivery cost for 12 orders looks doubled'),
        findsOneWidget);
  });

  testWidgets('the admin sees the same card: Resolve, never Agree', (t) async {
    await t.pumpWidget(host(SettlementAckCard(
      ack: ackDisputedAdmin, onResolve: () {})));
    await t.pump();
    expect(find.text('Resolve dispute'), findsOneWidget);
    expect(find.text('Agree'), findsNothing);
    // The freeze is the payload's sentence, not a Dart one.
    expect(find.text('Payout frozen while this period is disputed.'),
        findsOneWidget);
  });

  testWidgets('a build with no ack block draws nothing at all', (t) async {
    await t.pumpWidget(host(
        const SettlementAckCard(ack: <String, dynamic>{})));
    await t.pump();
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('can_resolve without a handler draws no Resolve button',
      (t) async {
    await t.pumpWidget(host(SettlementAckCard(ack: ackDisputedAdmin)));
    await t.pump();
    expect(find.text('Resolve dispute'), findsNothing);
    expect(find.text('Disputed'), findsOneWidget);
  });

  testWidgets('agreeing reports through the callback', (t) async {
    var agreed = false;
    await t.pumpWidget(host(SettlementAckCard(
      ack: ackNone, onAgree: (_) => agreed = true, onDispute: (_) {})));
    await t.pump();
    await t.tap(find.text('Agree'));
    await t.pump();
    expect(agreed, isTrue);
  });
}
