// CHANGE #630 — the customer Orders tab, and the ONE change window.
//
// What this file holds down, in the order Om asked for it:
//
//  PART A — the tab is ORDERS. One card, one truth, one thing to tap. The card
//  is incapable of computing: the money string, the item count, the stage
//  sentence, the four-step progress line and WHICH action the order gets are
//  all backend strings. ₹0.00 is never printed as a price — the backend sends
//  "Not billed" or "Rate on confirmation" and the card prints what it is given.
//
//  PART B — a customer may edit or cancel ONLY before the order enters
//  sourcing. The gate is `_order_change_gate()`; the client renders
//  `actions[]`. When the window is shut the actions are ABSENT, not disabled,
//  and the reason is the backend's sentence. Nothing here re-derives the gate
//  from a status string, which is exactly the second implementation this
//  change deleted.
//
// No network, no Supabase: every payload is a literal, the way the RPC sends it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/order_card_lean.dart';
import 'package:pharma_b2b/widgets/order_stage_strip.dart' show OrderStageDot;

Map<String, dynamic> _card({
  String amountLabel = '₹1,240.00',
  bool amountIsMoney = true,
  String stageLabel = 'Packed · out for delivery today',
  String actionKey = 'track',
  String actionLabel = 'Track',
  String actionTone = 'brand',
  bool progressShow = true,
}) =>
    {
      'id': 'o-1',
      'order_code': 'CPO010926PAL001',
      'date_label': '1 Sep 26, 10:12 AM',
      'item_count_label': '4 items',
      'amount_label': amountLabel,
      'amount_is_money': amountIsMoney,
      'stage_key': 'packed',
      'stage_label': stageLabel,
      'situation': 'active',
      'progress': {
        'show': progressShow,
        'index': 2,
        // CMD #1839 — the strip's one sentence, already finished server-side.
        'caption': 'Packed 3 of 4',
        'dispute_note': '',
        'steps': [
          {'key': 'confirmed', 'label': 'Confirmed', 'state': 'done'},
          {'key': 'sourcing', 'label': 'Sourcing', 'state': 'done'},
          {'key': 'packed', 'label': 'Packed', 'state': 'current'},
          {
            'key': 'out_for_delivery',
            'label': 'Out for delivery',
            'state': 'todo'
          },
        ],
      },
      'primary_action': {
        'key': actionKey,
        'label': actionLabel,
        'tone': actionTone
      },
      'placed_by_admin': false,
      'placed_by_admin_label': '',
    };

Future<void> _pumpCard(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  void Function(String)? onAction,
  VoidCallback? onOpen,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: OrderCardLean(
        card: CustomerOrderCard.fromPayload(payload),
        onOpen: onOpen ?? () {},
        onAction: onAction ?? (_) {},
      ),
    ),
  ));
}

void main() {
  group('PART A — one card, one truth', () {
    testWidgets('every line on the card is a backend string, printed verbatim',
        (tester) async {
      await _pumpCard(tester, _card());
      expect(find.text('CPO010926PAL001'), findsOneWidget);
      expect(find.text('1 Sep 26, 10:12 AM'), findsOneWidget);
      // "4 items" is pluralised by the backend. The card never counts and never
      // appends an 's'.
      expect(find.text('4 items'), findsOneWidget);
      expect(find.text('₹1,240.00'), findsOneWidget);
      // The stage in plain words — not a warehouse status pill.
      expect(find.text('Packed · out for delivery today'), findsOneWidget);
    });

    testWidgets('a zero amount is the backend\'s sentence, never ₹0.00',
        (tester) async {
      // The bug this closes: a live, unpriced order rendered "₹0.00" and read
      // like a broken bill. The backend decides which sentence applies; the
      // card cannot tell the two apart and must not try.
      await _pumpCard(
          tester,
          _card(
              amountLabel: 'Rate on confirmation', amountIsMoney: false));
      expect(find.text('Rate on confirmation'), findsOneWidget);
      expect(find.textContaining('₹'), findsNothing);

      await _pumpCard(
          tester, _card(amountLabel: 'Not billed', amountIsMoney: false));
      expect(find.text('Not billed'), findsOneWidget);
      expect(find.textContaining('0.00'), findsNothing);
    });

    testWidgets('exactly ONE action, and it is the one the backend named',
        (tester) async {
      // The live screenshot Om sent showed a Pending order carrying five
      // stacked actions (Edit · Cancel · Need help · Reorder · a chip row that
      // ran off the right edge). One card offers one button.
      await _pumpCard(tester, _card());
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.text('Track'), findsOneWidget);
      // None of the doors that used to live on the row are on it any more.
      expect(find.text('Reorder'), findsNothing);
      expect(find.text('Need help'), findsNothing);
      expect(find.text('Cancel order'), findsNothing);
    });

    testWidgets('the action KEY is handed back untranslated', (tester) async {
      // Om, live on this command: a Pending order that has not entered
      // sourcing offers the change window, not a tracker. Which situation gets
      // which action is a row in app_settings — so the card must route
      // whatever key arrives and never map a label back to an intent.
      final keys = <String>[];
      await _pumpCard(
          tester,
          _card(
              actionKey: 'edit',
              actionLabel: 'Edit order',
              actionTone: 'outline'),
          onAction: keys.add);
      expect(find.text('Edit order'), findsOneWidget);
      // 'outline' tone is a secondary button — one brand-filled action per card.
      expect(find.byType(OutlinedButton), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      await tester.tap(find.text('Edit order'));
      expect(keys, ['edit']);
    });

    testWidgets('an action key this build has never heard of still renders',
        (tester) async {
      // Forward compatibility: a new action is an UPDATE on the backend. The
      // card draws the label it was sent and hands the key up; only the router
      // decides it does not know it.
      final keys = <String>[];
      await _pumpCard(
          tester,
          _card(actionKey: 'dispute', actionLabel: 'Raise a dispute'),
          onAction: keys.add);
      expect(find.text('Raise a dispute'), findsOneWidget);
      await tester.tap(find.text('Raise a dispute'));
      expect(keys, ['dispute']);
    });

    testWidgets('no action sent means no button — never a word from Dart',
        (tester) async {
      await _pumpCard(
          tester, _card(actionKey: '', actionLabel: '', actionTone: ''));
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('tapping the card body opens the order', (tester) async {
      // PART A5/A6 — Items · Payment · Bill · Help are tabs INSIDE the order
      // now, so the row itself is the way in.
      var opened = 0;
      await _pumpCard(tester, _card(), onOpen: () => opened++);
      await tester.tap(find.text('CPO010926PAL001'));
      expect(opened, 1);
    });
  });

  group('PART A7 — the progress line (CMD #1839: condensed, cumulative)', () {
    testWidgets('one dot per stage, in payload order, and ONE backend sentence',
        (tester) async {
      // Fifteen stages will not fit fifteen labels on a phone card, so the
      // condensed strip is dots plus the payload's own `caption`. The card
      // still writes nothing: the sentence arrives finished, counts and all.
      await _pumpCard(tester, _card());
      final line = tester
          .widgetList<OrderProgressLine>(find.byType(OrderProgressLine))
          .single;
      expect(line.steps.map((s) => s['key']).toList(),
          ['confirmed', 'sourcing', 'packed', 'out_for_delivery']);
      expect(find.byType(OrderStageDot), findsNWidgets(4));
      expect(find.text('Packed 3 of 4'), findsOneWidget);
      // The stage names are NOT redrawn under the dots any more.
      expect(find.text('Out for delivery'), findsNothing);
    });

    testWidgets('show:false hides the line even though steps arrived',
        (tester) async {
      // The backend decides whether an order has a live progress line — a
      // cancelled one does not. The card must not substitute "the array is
      // non-empty" for that answer.
      await _pumpCard(tester, _card(progressShow: false));
      expect(find.byType(OrderProgressLine), findsNothing);
      expect(find.byType(OrderStageDot), findsNothing);
      expect(find.text('Packed 3 of 4'), findsNothing);
    });
  });

  group('PART A2 — the filter row', () {
    testWidgets('label and count print verbatim; 0 shows no bracket',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            OrdersFilterChip(
                label: 'Active', count: 3, selected: true, onTap: () {}),
            OrdersFilterChip(
                label: 'Cancelled', count: 0, selected: false, onTap: () {}),
          ]),
        ),
      ));
      expect(find.text('Active (3)'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
    });
  });

  group('PART B — the change window is the backend\'s, not the client\'s', () {
    test('an open window carries its doors, in payload order', () {
      final w = OrderChangeWindow.fromDetail({
        'ok': true,
        'change_window': {'open': true, 'can_edit': true, 'can_cancel': true},
        'window_note': '',
        'actions': [
          {'key': 'edit', 'label': 'Edit order', 'enabled': true},
          {'key': 'cancel', 'label': 'Cancel order', 'enabled': true},
          {'key': 'help', 'label': 'Need help', 'enabled': true},
        ],
      });
      expect(w.open, isTrue);
      expect(w.note, '');
      expect(w.actions.map((a) => a['key']).toList(),
          ['edit', 'cancel', 'help']);
    });

    test('a shut window sends NO edit or cancel — they are absent, not disabled',
        () {
      // Om's rule: the window closes the moment the inquiry starts for that
      // order. The old cancel gate never looked at the inquiry at all and let a
      // cancel through after the waterfall had already asked suppliers; the old
      // edit gate closed correctly. One gate now, and when it is shut the
      // affordance is GONE rather than rendered disabled so it can refuse the
      // tap.
      final w = OrderChangeWindow.fromDetail({
        'ok': true,
        'change_window': {
          'open': false,
          'can_edit': false,
          'can_cancel': false,
          'reason_code': 'inquiry_started',
          'reason': 'Sourcing has started — contact support to change this order',
        },
        'window_note':
            'Sourcing has started — contact support to change this order',
        'actions': [
          {'key': 'help', 'label': 'Need help', 'enabled': true},
        ],
      });
      expect(w.open, isFalse);
      expect(w.actions.any((a) => a['key'] == 'edit'), isFalse);
      expect(w.actions.any((a) => a['key'] == 'cancel'), isFalse);
      // The reason is the backend's sentence, kept word for word.
      expect(w.note,
          'Sourcing has started — contact support to change this order');
    });

    test('order hours closing shuts the same one window', () {
      final w = OrderChangeWindow.fromDetail({
        'ok': true,
        'change_window': {
          'open': false,
          'reason_code': 'hours_closed',
          'reason': 'Order hours are closed — you can change this order when they reopen.',
        },
        'window_note':
            'Order hours are closed — you can change this order when they reopen.',
        'actions': const [],
      });
      expect(w.open, isFalse);
      expect(w.actions, isEmpty);
      expect(w.note, contains('Order hours are closed'));
    });

    test('the client never second-guesses the gate from the order status', () {
      // A payload that says the window is OPEN on an order whose status this
      // build would have called finished. The backend is the only authority:
      // if it says open, the doors render. Any Dart branch on status here is
      // the bug Part B deleted.
      final w = OrderChangeWindow.fromDetail({
        'ok': true,
        'order': {'status': 'delivered'},
        'change_window': {'open': true},
        'window_note': '',
        'actions': [
          {'key': 'edit', 'label': 'Edit order', 'enabled': true},
        ],
      });
      expect(w.open, isTrue);
      expect(w.actions.single['key'], 'edit');
    });

    test('a payload with no gate block is shut, and says nothing of its own',
        () {
      final w = OrderChangeWindow.fromDetail({'ok': true});
      expect(w.open, isFalse);
      expect(w.actions, isEmpty);
      expect(w.note, '');
    });
  });
}
