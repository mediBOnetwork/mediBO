// PROTECTED — CHANGE #689 (feature_gaps #75).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes order-timeline behaviour, never to make an unrelated
// change go green.
//
// The timeline is the whole answer to "where is this order", so the one thing
// it must never do is have an opinion. What this holds down:
//
//   1. PAYLOAD ORDER IS THE ORDER. order_timeline() assembled ten tables into
//      one list and sorted it. The fixture is deliberately NOT chronological by
//      ts_label, so any client-side sort fails here.
//
//   2. NOTHING IS RECOMPUTED. label, detail, ts_label, age_label, tone, late
//      and late_label all print verbatim. The fixture's `late:true` sits on an
//      event whose stamp is minutes old and whose tone is red — a Dart clock
//      would disagree, and must never get the chance.
//
//   3. AN ABSENT ACTOR IS `has:false`, not a blank line or a dash — and a
//      customer's payload simply arrives with no phone, which is why the buyer
//      sees none. The filtering is Postgres's; this widget does not know a
//      supplier's name is a secret.
//
//   4. THE ACTION IS THE EVENT'S. The button calls the `rpc` the event named
//      with the `args` it carried, verbatim — Dart never picks the function,
//      never builds the arguments, and never invents a label. A half-built
//      action (no rpc, or no label) renders NOTHING rather than throwing, so a
//      backend mid-rollout cannot white-screen an order.
//
//   5. A CHOICE IS THE BACKEND'S LIST. `needs_choice` hands back the riders it
//      will accept; picking one calls the SAME action again with the payload's
//      own `choice_key`. No rider is ever chosen in Dart.
//
//   6. `access:'none'` RENDERS NOTHING AT ALL. Refusal is absence, not an
//      error box, and never an accusation.
//
// Fixture shape mirrors a real order_timeline() reply (verified against the
// live database on 2026-09-03 by scripts/c689_timeline_proof.sql). No network,
// no Supabase.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/order_timeline_view.dart';
import 'package:pharma_b2b/widgets/order_event_timeline.dart';

Map<String, dynamic> _event({
  required String label,
  String stage = 'sourcing',
  String detail = '',
  String tsLabel = '03/09/26 9:16 AM',
  String ageLabel = '2h ago',
  String tone = 'neutral',
  bool late = false,
  String lateLabel = '',
  bool isCurrent = false,
  Map<String, dynamic>? actor,
  Map<String, dynamic>? action,
}) =>
    {
      'ts': '2026-09-03T03:46:10.033066+00:00',
      'ts_label': tsLabel,
      'age_label': ageLabel,
      'stage': stage,
      'label': label,
      'detail': detail,
      'has_detail': detail.isNotEmpty,
      'tone': tone,
      'late': late,
      'late_label': lateLabel,
      'is_current': isCurrent,
      'actor': actor ?? {'has': false},
      'action': action ?? {'has': false},
    };

Map<String, dynamic> _actor(String kind, String name, String phone) => {
      'has': true,
      'kind': kind,
      'name': name,
      'phone': phone,
      'has_phone': phone.isNotEmpty,
      'label': '${kind[0].toUpperCase()}${kind.substring(1)} · $name',
    };

Map<String, dynamic> _action(String kind, String label,
        {String tone = 'neutral',
        String rpc = 'order_timeline_act',
        Map<String, dynamic>? args}) =>
    {
      'has': true,
      'kind': kind,
      'label': label,
      'tone': tone,
      'rpc': rpc,
      'args': args ??
          {
            'p_order_id': 'ord-1',
            'p_action': kind,
            'p_args': {'supplier_name': 'BHARAT SALES'},
          },
    };

Map<String, dynamic> _payload({
  String access = 'full',
  bool canAct = true,
  List<Map<String, dynamic>>? events,
  String privacy = '',
  String empty = 'Nothing has happened on this order yet.',
}) =>
    {
      'ok': true,
      'access': access,
      'can_act': canAct,
      'events_heading': 'Order timeline',
      'events_empty': empty,
      'privacy_note': privacy,
      'event_count': (events ?? const []).length,
      'events': events ?? const <Map<String, dynamic>>[],
    };

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  // ── 1. payload order ──────────────────────────────────────────────────────
  testWidgets('events render in payload order, never re-sorted by stamp',
      (tester) async {
    final p = _payload(events: [
      _event(label: 'Asked BHARAT SALES', tsLabel: '03/09/26 9:16 AM'),
      // Deliberately EARLIER on the clock than the row above it: the backend
      // put it second, so it stays second.
      _event(label: 'Order placed', stage: 'placed', tsLabel: '01/09/26 7:02 AM'),
      _event(label: 'Delivered', stage: 'delivery', tsLabel: '02/09/26 4:30 PM'),
    ]);
    await _pump(
        tester,
        SingleChildScrollView(
            child: OrderEventTimeline(view: OrderTimelineView.from(p))));

    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((d) => d == 'Asked BHARAT SALES' || d == 'Order placed' || d == 'Delivered')
        .toList();
    expect(labels, ['Asked BHARAT SALES', 'Order placed', 'Delivered']);
  });

  // ── 2. nothing recomputed ─────────────────────────────────────────────────
  testWidgets('label, detail, stamp and the late badge all print verbatim',
      (tester) async {
    final p = _payload(events: [
      _event(
        label: 'Supplier order sent to BHARAT SALES',
        detail: '5 items on the inquiry',
        tsLabel: '03/09/26 9:16 AM',
        tone: 'red',
        late: true,
        lateLabel: 'Late',
        isCurrent: true,
        actor: _actor('supplier', 'BHARAT SALES', '+919000000001'),
      ),
    ]);
    await _pump(tester, OrderEventTimeline(view: OrderTimelineView.from(p)));

    expect(find.text('Supplier order sent to BHARAT SALES'), findsOneWidget);
    expect(find.text('5 items on the inquiry'), findsOneWidget);
    expect(find.text('03/09/26 9:16 AM'), findsOneWidget);
    // The badge is the backend's word, not a string this build assembled.
    expect(find.text('Late'), findsOneWidget);
    expect(find.text('Supplier · BHARAT SALES · +919000000001'), findsOneWidget);
  });

  testWidgets('an event the backend did not mark late shows no badge',
      (tester) async {
    final p = _payload(events: [
      // Same red tone, no late flag and no label: the badge is `late_label`,
      // never derived from the tone or from the age.
      _event(label: 'Delivery attempt failed', tone: 'red', ageLabel: '9 days'),
    ]);
    await _pump(tester, OrderEventTimeline(view: OrderTimelineView.from(p)));
    expect(find.text('Delivery attempt failed'), findsOneWidget);
    expect(find.text('Late'), findsNothing);
  });

  // ── 3. the actor block ────────────────────────────────────────────────────
  testWidgets('an absent actor draws no row at all', (tester) async {
    final p = _payload(events: [_event(label: 'Bags allocated')]);
    await _pump(tester, OrderEventTimeline(view: OrderTimelineView.from(p)));
    expect(find.text('Bags allocated'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets("the buyer's payload carries no phone, so none is drawn",
      (tester) async {
    final p = _payload(
      access: 'customer',
      canAct: false,
      privacy: 'Supplier details are kept private.',
      events: [
        _event(
          label: 'Supplier order sent to a supplier',
          // The BACKEND masked the name and stripped the number.
          actor: _actor('supplier', 'a supplier', ''),
        ),
      ],
    );
    await _pump(tester, OrderEventTimeline(view: OrderTimelineView.from(p)));
    expect(find.text('Supplier · a supplier'), findsOneWidget);
    expect(find.textContaining('+91'), findsNothing);
    expect(find.text('Supplier details are kept private.'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  // ── 4. the action is the event's ──────────────────────────────────────────
  testWidgets('tapping the action calls the payload rpc with the payload args',
      (tester) async {
    String? calledRpc;
    Map<String, dynamic>? calledArgs;
    final p = _payload(events: [
      _event(
        label: 'Asked BHARAT SALES',
        tone: 'red',
        late: true,
        lateLabel: 'Late',
        actor: _actor('supplier', 'BHARAT SALES', '+919000000001'),
        action: _action('nudge_supplier', 'Nudge supplier', tone: 'red'),
      ),
    ]);
    await _pump(
      tester,
      OrderEventTimeline(
        view: OrderTimelineView.from(p),
        onAct: (a, extra) async {
          calledRpc = a.rpc;
          calledArgs = a.args;
          return TimelineActionResult.from(
              {'ok': true, 'message': 'Reminder sent.', 'timeline': {}});
        },
      ),
    );

    expect(find.text('Nudge supplier'), findsOneWidget);
    await tester.tap(find.text('Nudge supplier'));
    await tester.pumpAndSettle();

    expect(calledRpc, 'order_timeline_act');
    expect(calledArgs?['p_action'], 'nudge_supplier');
    expect((calledArgs?['p_args'] as Map)['supplier_name'], 'BHARAT SALES');
    // The confirmation is the backend's sentence, not a Dart "Done".
    expect(find.text('Reminder sent.'), findsOneWidget);
  });

  testWidgets('a half-built action renders nothing rather than throwing',
      (tester) async {
    final p = _payload(events: [
      _event(
          label: 'Assigned to Tittu',
          action: {'has': true, 'kind': 'reassign', 'label': '', 'rpc': ''}),
    ]);
    await _pump(
      tester,
      OrderEventTimeline(
          view: OrderTimelineView.from(p), onAct: (a, e) async => throw 'never'),
    );
    expect(find.text('Assigned to Tittu'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('a host that cannot act draws no button even when one was sent',
      (tester) async {
    final p = _payload(events: [
      _event(label: 'Out for delivery', action: _action('call_rider', 'Call rider')),
    ]);
    await _pump(tester, OrderEventTimeline(view: OrderTimelineView.from(p)));
    expect(find.byType(OutlinedButton), findsNothing);
  });

  // ── 5. a choice is the backend's list ─────────────────────────────────────
  testWidgets('needs_choice offers the backend riders and calls back with its key',
      (tester) async {
    final calls = <Map<String, dynamic>>[];
    final p = _payload(events: [
      _event(
        label: 'Assigned to Tittu',
        stage: 'dispatch',
        actor: _actor('rider', 'Tittu', '+919000000002'),
        action: _action('reassign', 'Reassign rider',
            args: {'p_order_id': 'ord-1', 'p_action': 'reassign', 'p_args': {}}),
      ),
    ]);
    await _pump(
      tester,
      OrderEventTimeline(
        view: OrderTimelineView.from(p),
        onAct: (a, extra) async {
          calls.add(Map<String, dynamic>.from(extra));
          if (calls.length == 1) {
            return TimelineActionResult.from({
              'ok': false,
              'needs_choice': true,
              'choice_key': 'partner_id',
              'title': 'Pick a rider',
              'choices': [
                {'id': 'rider-9', 'label': 'Anita'},
                {'id': 'rider-3', 'label': 'Vikram'},
              ],
            });
          }
          return TimelineActionResult.from(
              {'ok': true, 'message': 'Reassigned to Anita.'});
        },
      ),
    );

    await tester.tap(find.text('Reassign rider'));
    await tester.pumpAndSettle();
    expect(find.text('Pick a rider'), findsOneWidget);
    expect(find.text('Anita'), findsOneWidget);
    expect(find.text('Vikram'), findsOneWidget);

    await tester.tap(find.text('Anita'));
    await tester.pumpAndSettle();

    expect(calls.length, 2);
    expect(calls.first, isEmpty);
    // The key came off the payload — nothing here knows what a rider id is
    // called.
    expect(calls[1], {'partner_id': 'rider-9'});
    expect(find.text('Reassigned to Anita.'), findsOneWidget);
  });

  // ── 6. refusal and emptiness ──────────────────────────────────────────────
  testWidgets('access none renders nothing at all', (tester) async {
    final p = _payload(access: 'none', canAct: false, events: [
      _event(label: 'Order placed'),
    ]);
    await _pump(tester, OrderEventTimeline(view: OrderTimelineView.from(p)));
    expect(find.text('Order placed'), findsNothing);
    expect(find.text('Order timeline'), findsNothing);
  });

  testWidgets('an empty list prints the backend sentence, not an invented one',
      (tester) async {
    await _pump(
        tester,
        OrderEventTimeline(
            view: OrderTimelineView.from(_payload(events: const []))));
    expect(find.text('Nothing has happened on this order yet.'), findsOneWidget);
  });

  test('a payload that is not a map is an absent block, never a crash', () {
    expect(OrderTimelineView.from(null).visible, isFalse);
    expect(OrderTimelineView.from('boom').events, isEmpty);
    expect(TimelineActor.from(null).has, isFalse);
    expect(TimelineAction.from(const {'has': false}).has, isFalse);
  });
}
