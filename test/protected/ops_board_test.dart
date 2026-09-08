// PROTECTED — CHANGE #688.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes ops-board behaviour, never to make an unrelated change
// go green.
//
// What this holds down:
//
//   1. THE SORT IS THE BACKEND'S. ops_board() already ordered the rows red →
//      amber → green, most overdue first. The board renders them in PAYLOAD
//      ORDER. A client-side re-sort would be a second opinion about which
//      order is worst — and the whole feature is "the top row is the thing to
//      do next".
//
//   2. NOTHING ON A ROW IS COMPUTED IN DART. The clock ("35d 9h over"), the
//      SLA ("SLA 1h"), the tone word, the owner, the next action, the money and
//      the age all print verbatim. In particular the board never derives
//      "overdue" from a number of its own: `tone` and `clock_label` arrive
//      finished, and a row whose seconds_left says one thing while clock_label
//      says another still prints clock_label.
//
//   3. A TONE THIS BUILD HAS NEVER SEEN RENDERS NEUTRAL, never throws. That is
//      what lets the backend add a fourth tone to a fleet already in the field.
//
//   4. THE SLA BUTTON IS A BACKEND FLAG. `can_edit_sla:false` renders no button
//      at all — the panel is never hidden by a role check written in Dart.
//
//   5. A REFUSAL IS THE BACKEND'S SENTENCE. ok:false prints the payload's own
//      title and message instead of throwing or inventing wording, and the
//      empty state prints empty_title/empty_message.
//
//   6. THE ORDER TIMELINE reads the same way: steps in payload order, spent /
//      SLA labels verbatim, and a not-found detail renders the backend's copy.
//
// Fixture mirrors a real ops_board() response taken off the live database on
// 2026-09-03 (the day the clock was installed: 32 open orders, every one of
// them already breached, the worst 35 days over). No network, no Supabase.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/ops_board_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _row({
  required String code,
  required String tone,
  required String clock,
  String stage = 'Supplier order',
  String customer = 'Pallavi Pharmacy',
  String amount = '₹12,263.85',
  String sla = 'SLA 1h',
  String owner = 'Partner',
  String next = 'Raise the supplier order',
  int secondsLeft = -3057557,
}) =>
    {
      'order_id': 'id-$code',
      'order_code': code,
      'customer': customer,
      'amount_display': amount,
      'stage_key': 'supplier_order',
      'stage_label': stage,
      'owner_role': 'partner',
      'owner_label': owner,
      'next_action': next,
      'entered_label': '35d ago',
      'entered_at': '2026-07-29T19:37:38.946903+00:00',
      'age_label': '35 days',
      'sla_label': sla,
      'clock_label': clock,
      'overdue': secondsLeft <= 0,
      'seconds_left': secondsLeft,
      'tone': tone,
      'tone_label': tone == 'red'
          ? 'Breached'
          : tone == 'amber'
              ? 'Due soon'
              : 'On time',
    };

Map<String, dynamic> _board({
  List<Map<String, dynamic>>? rows,
  bool canEdit = true,
}) =>
    {
      'ok': true,
      'role': 'super_admin',
      'is_partner': false,
      'access': 'write',
      'zone_id': 1,
      'zone_label': 'Raipur Zone',
      'title': 'Ops board',
      'subtitle': 'Every open order, worst breach first',
      'rows': rows ??
          [
            _row(code: 'CPO260726PAL124O1', tone: 'red', clock: '35d 9h over'),
            _row(
                code: 'CPO010826NIT129O1',
                tone: 'amber',
                clock: '12m left',
                secondsLeft: 720),
            _row(
                code: 'CPO030926SHR131O1',
                tone: 'green',
                clock: '48m left',
                secondsLeft: 2880),
          ],
      'has_any': true,
      'total': 3,
      'counts': {'red': 1, 'amber': 1, 'green': 1},
      'chips': [
        {'tone': 'red', 'count': 1, 'label': 'Breached 1'},
        {'tone': 'amber', 'count': 1, 'label': 'Due soon 1'},
        {'tone': 'green', 'count': 1, 'label': 'On time 1'},
      ],
      'refresh_ms': 30000,
      'updated_label': 'Updated 11:26 AM',
      'can_edit_sla': canEdit,
      'sla_button': 'SLA settings',
      'empty_title': 'Nothing open',
      'empty_message': 'Every order in this zone is closed or cancelled.',
    };

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('ops board — the backend decides, the board prints', () {
    testWidgets('rows render in PAYLOAD ORDER, never re-sorted in Dart',
        (tester) async {
      // Deliberately handed to the widget worst-LAST. A board that sorts would
      // move the red row to the top; this one must not.
      final rows = [
        _row(code: 'GREEN-1', tone: 'green', clock: '48m left', secondsLeft: 2880),
        _row(code: 'AMBER-1', tone: 'amber', clock: '12m left', secondsLeft: 720),
        _row(code: 'RED-1', tone: 'red', clock: '35d 9h over'),
      ];
      await _pump(tester, OpsBoardView(payload: _board(rows: rows)));

      final codes = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s.endsWith('-1'))
          .toList();
      expect(codes, ['GREEN-1', 'AMBER-1', 'RED-1']);
    });

    testWidgets('every string on a row is the payload string', (tester) async {
      await _pump(tester, OpsBoardView(payload: _board()));

      expect(find.text('CPO260726PAL124O1'), findsOneWidget);
      expect(find.text('Pallavi Pharmacy'), findsWidgets);
      expect(find.text('₹12,263.85'), findsWidgets);
      expect(find.text('35d 9h over'), findsOneWidget);
      expect(find.text('12m left'), findsOneWidget);
      expect(find.text('SLA 1h'), findsWidgets);
      expect(find.text('Raise the supplier order'), findsWidgets);
      expect(find.text('Partner'), findsWidgets);
      // The chips are the backend's captions, not a count formatted here.
      expect(find.text('Breached 1'), findsOneWidget);
      expect(find.text('Due soon 1'), findsOneWidget);
      expect(find.text('On time 1'), findsOneWidget);
      expect(find.text('Updated 11:26 AM'), findsNothing); // joined with zone
      expect(find.textContaining('Raipur Zone'), findsOneWidget);
    });

    testWidgets('clock_label wins over seconds_left — no Dart arithmetic',
        (tester) async {
      // A row whose number disagrees with its sentence still prints the
      // sentence. The board must never compute a clock of its own.
      final rows = [
        _row(
            code: 'ODD-1',
            tone: 'red',
            clock: '2h 5m over',
            secondsLeft: 999999),
      ];
      await _pump(tester, OpsBoardView(payload: _board(rows: rows)));
      expect(find.text('2h 5m over'), findsOneWidget);
    });

    testWidgets('an unknown tone renders neutral instead of throwing',
        (tester) async {
      final rows = [
        _row(code: 'NEW-1', tone: 'ultraviolet', clock: '3h over'),
      ];
      await _pump(tester, OpsBoardView(payload: _board(rows: rows)));
      expect(find.text('NEW-1'), findsOneWidget);
      expect(find.text('3h over'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(OpsTone.fg('ultraviolet'), OpsTone.fg('not-a-tone'));
    });

    testWidgets('the SLA button is can_edit_sla, not a role check in Dart',
        (tester) async {
      await _pump(
          tester,
          OpsBoardView(
              payload: _board(canEdit: true), onEditSla: () {}));
      expect(find.text('SLA settings'), findsOneWidget);

      await _pump(
          tester,
          OpsBoardView(
              payload: _board(canEdit: false), onEditSla: () {}));
      expect(find.text('SLA settings'), findsNothing);
    });

    testWidgets('a tap carries the backend own order_id', (tester) async {
      Map<String, dynamic>? tapped;
      await _pump(
          tester,
          OpsBoardView(
              payload: _board(), onTapRow: (r) => tapped = r));
      await tester.tap(find.text('CPO260726PAL124O1'));
      await tester.pump();
      expect(tapped?['order_id'], 'id-CPO260726PAL124O1');
    });

    testWidgets('empty and refused states print the backend copy',
        (tester) async {
      await _pump(tester, OpsBoardView(payload: _board(rows: const [])));
      expect(find.text('Nothing open'), findsOneWidget);
      expect(find.text('Every order in this zone is closed or cancelled.'),
          findsOneWidget);

      await _pump(
          tester,
          const OpsBoardView(payload: {
            'ok': false,
            'error': 'not_authorized',
            'title': 'Ops board',
            'message': 'You do not have access to the ops board.',
            'rows': [],
          }));
      expect(find.text('You do not have access to the ops board.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('ops order detail — the stage timeline', () {
    const detail = {
      'ok': true,
      'order_id': 'id-1',
      'order_code': 'CPO260726PAL124O1',
      'customer': 'Pallavi Pharmacy',
      'amount_display': '₹12,263.85',
      'zone_label': 'Raipur Zone',
      'placed_label': 'Placed 26 Jul 2026, 4:12 PM',
      'status_label': 'Accepted',
      'current_stage': 'supplier_order',
      'next_action': 'Raise the supplier order',
      'timeline_title': 'Stage timeline',
      'steps': [
        {
          'stage_key': 'accept',
          'label': 'Accept',
          'owner_label': 'Partner',
          'is_current': false,
          'reached': true,
          'entered_label': '26 Jul 2026, 4:12 PM',
          'spent_label': '4m',
          'sla_label': 'SLA 30m',
          'tone': 'green',
        },
        {
          'stage_key': 'supplier_order',
          'label': 'Supplier order',
          'owner_label': 'Partner',
          'is_current': true,
          'reached': true,
          'entered_label': '29 Jul 2026, 1:07 AM',
          'spent_label': '35d 9h',
          'sla_label': 'SLA 1h',
          'tone': 'red',
        },
      ],
    };

    testWidgets('steps print in payload order with verbatim labels',
        (tester) async {
      await _pump(tester, const OpsOrderDetailView(payload: detail));
      expect(find.text('Stage timeline'), findsOneWidget);
      expect(find.text('4m'), findsOneWidget);
      expect(find.text('35d 9h'), findsOneWidget);
      expect(find.text('SLA 30m'), findsOneWidget);
      expect(find.text('SLA 1h'), findsOneWidget);

      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s == 'Accept' || s == 'Supplier order')
          .toList();
      expect(labels, ['Accept', 'Supplier order']);
    });

    testWidgets('a not-found detail renders the backend copy', (tester) async {
      await _pump(
          tester,
          const OpsOrderDetailView(payload: {
            'ok': false,
            'error': 'order_not_found',
            'title': 'Order not found',
            'message': 'This order is no longer on the board.',
          }));
      expect(find.text('This order is no longer on the board.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
