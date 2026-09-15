// PROTECTED — CMD #1839. The customer's fifteen stages are a PRINTER.
//
// Two views, one payload: the condensed dot strip on the Orders card
// (OrderProgressLine → OrderStageStrip) and the Track popup's full list
// (OrderTimelineCard → OrderStageList). Everything either of them shows is a
// string `_order_stage_engine()` already finished:
//
//   • which stage is current is `state`, never a timestamp comparison here;
//   • "Packing 14 of 15" is `count_label`, never assembled in Dart — the
//     fixture's count deliberately DISAGREES with its own stage list length,
//     so a widget that recomputed it fails;
//   • a dropped line has already left the count before the payload was built,
//     which is why the fixture says "14 of 14" while carrying 15 stages;
//   • the re-sourcing sentence is `dispute_note`, printed on the CURRENT stage
//     only and never pluralised here;
//   • no supplier can appear because none is ever sent: `events` in the payload
//     draws nothing at all after the customer event log was retired.
//
// Dart VM only — inline payloads, no network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/widgets/order_stage_strip.dart';
import 'package:pharma_b2b/widgets/order_card_lean.dart' show OrderProgressLine;
import 'package:pharma_b2b/screens/delivery/customer_track_sheet.dart'
    show OrderTimelineCard;
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Map<String, dynamic> _stage(
  String key,
  String label,
  String state, {
  String ts = '',
  String count = '',
}) =>
    {
      'key': key,
      'label': label,
      'state': state,
      'done': state == 'done',
      'current': state == 'current',
      'ts_label': ts,
      'has_ts': ts.isNotEmpty,
      'count_label': count,
      'has_count': count.isNotEmpty,
      'scope': 'order',
    };

/// A WhatsApp-origin order: fifteen stages, Lead first, sitting on Packing
/// with one line already dropped — so the count reads "14 of 14".
List<Map<String, dynamic>> _fifteen() => [
      _stage('lead', 'Lead', 'done', ts: '01 Sep 2026, 09:02 AM'),
      _stage('placed', 'Order placed', 'done', ts: '01 Sep 2026, 09:16 AM'),
      _stage('advance_paid', 'Advance paid', 'done'),
      _stage('confirmed', 'Order confirmed', 'done',
          ts: '01 Sep 2026, 10:02 AM'),
      _stage('processing', 'Processing order', 'done'),
      _stage('bill_sent', 'Bill sent', 'done'),
      _stage('balance_paid', 'Balance paid', 'done'),
      _stage('sourcing', 'Sourcing', 'done'),
      _stage('collected', 'Collected', 'done', ts: '02 Sep 2026, 11:40 AM'),
      _stage('packing', 'Packing', 'current', count: 'Packing 14 of 14'),
      _stage('packed', 'Packed', 'todo'),
      _stage('ready_dispatch', 'Ready to dispatch', 'todo'),
      _stage('assigned', 'Assigned to delivery', 'todo'),
      _stage('out_for_delivery', 'Out for delivery', 'todo'),
      _stage('delivered', 'Delivered', 'todo'),
    ];

/// A website order. The backend simply never sends a Lead stage, which is how
/// "website/app orders start at Order placed" is expressed — not by a Dart
/// filter and not by a permanently grey first dot.
List<Map<String, dynamic>> _fourteen() =>
    _fifteen().where((s) => s['key'] != 'lead').toList();

Map<String, dynamic> _timeline(List<Map<String, dynamic>> steps,
        {String note = ''}) =>
    {
      'heading': 'Order progress',
      'steps': steps,
      'dispute_note': note,
      'eta_label': 'Expected delivery',
      'eta_display': 'We will confirm a delivery date once suppliers confirm.',
      // Retired for the buyer. Present here purely to prove it draws NOTHING.
      'events': const [
        {'title': 'Asked Sagar Medicals', 'at_label': '02 Sep 2026'}
      ],
      'events_heading': '',
      'privacy_note': '',
    };

Color? _dotColour(WidgetTester t, int i) {
  final d = t.widgetList<OrderStageDot>(find.byType(OrderStageDot)).toList()[i];
  final box = t.widget<Container>(find.descendant(
    of: find.byWidget(d),
    matching: find.byType(Container),
  ));
  return (box.decoration as BoxDecoration).color;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the Track popup — all fifteen stages, in payload order', () {
    testWidgets('every label and stamp prints verbatim, in payload order',
        (tester) async {
      await tester
          .pumpWidget(_host(OrderTimelineCard(timeline: _timeline(_fifteen()))));

      for (final label in const [
        'Lead',
        'Order placed',
        'Advance paid',
        'Order confirmed',
        'Processing order',
        'Bill sent',
        'Balance paid',
        'Sourcing',
        'Collected',
        'Packing',
        'Packed',
        'Ready to dispatch',
        'Assigned to delivery',
        'Out for delivery',
        'Delivered',
      ]) {
        expect(find.text(label), findsOneWidget, reason: 'missing $label');
      }
      expect(find.byType(OrderStageDot), findsNWidgets(15));

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(texts.indexOf('Lead'), lessThan(texts.indexOf('Order placed')));
      expect(texts.indexOf('Collected'), lessThan(texts.indexOf('Packing')));
      expect(texts.indexOf('Packing'), lessThan(texts.indexOf('Delivered')));
    });

    testWidgets('a stage with no stamp shows none — never an invented one',
        (tester) async {
      await tester
          .pumpWidget(_host(OrderTimelineCard(timeline: _timeline(_fifteen()))));
      // Exactly the four stamps the payload carried.
      expect(find.textContaining('Sep 2026,'), findsNWidgets(4));
    });

    testWidgets('the count is the backend string, on the current stage only',
        (tester) async {
      await tester
          .pumpWidget(_host(OrderTimelineCard(timeline: _timeline(_fifteen()))));
      // Fifteen stages on screen, and the count still says 14 — because a
      // dropped line left the count in the BACKEND, not here.
      expect(find.text('Packing 14 of 14'), findsOneWidget);
      expect(find.textContaining(' of 15'), findsNothing);
    });

    testWidgets('the re-sourcing note prints verbatim, on the current stage',
        (tester) async {
      await tester.pumpWidget(_host(OrderTimelineCard(
          timeline:
              _timeline(_fifteen(), note: '1 item being re-sourced'))));
      expect(find.text('1 item being re-sourced'), findsOneWidget);
    });

    testWidgets('the retired event log draws nothing — no supplier name',
        (tester) async {
      await tester.pumpWidget(_host(OrderTimelineCard(
          timeline: _timeline(_fifteen(), note: '1 item being re-sourced'))));
      expect(find.textContaining('Sagar'), findsNothing);
      expect(find.textContaining('Order timeline'), findsNothing);
      expect(find.textContaining('kept private'), findsNothing);
    });

    testWidgets('an empty payload renders nothing at all', (tester) async {
      await tester.pumpWidget(_host(const OrderTimelineCard(timeline: {})));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('a website order simply has no Lead stage', (tester) async {
      await tester.pumpWidget(
          _host(OrderTimelineCard(timeline: _timeline(_fourteen()))));
      expect(find.text('Lead'), findsNothing);
      expect(find.text('Order placed'), findsOneWidget);
      expect(find.byType(OrderStageDot), findsNWidgets(14));
    });
  });

  group('state drives the dot — done solid, current hollow, future grey', () {
    testWidgets('the three states paint three different dots', (tester) async {
      await tester
          .pumpWidget(_host(OrderTimelineCard(timeline: _timeline(_fifteen()))));
      // 0 = Lead (done), 9 = Packing (current), 10 = Packed (todo).
      expect(_dotColour(tester, 0), Ds.c.brand);
      // A hollow ring is the surface colour with a brand border — NOT a fill.
      expect(_dotColour(tester, 9), Ds.c.surface);
      expect(_dotColour(tester, 10), Ds.c.divider);
    });

    testWidgets('an unknown state is treated as still ahead, never as done',
        (tester) async {
      await tester.pumpWidget(_host(OrderTimelineCard(
          timeline: _timeline([
        _stage('placed', 'Order placed', 'done'),
        _stage('sourcing', 'Sourcing', 'pending'),
      ]))));
      expect(_dotColour(tester, 1), Ds.c.divider);
    });
  });

  group('the card strip — condensed, and it computes nothing', () {
    testWidgets('one dot per stage and the caption verbatim', (tester) async {
      await tester.pumpWidget(_host(OrderProgressLine(
        steps: _fifteen(),
        caption: 'Packing 14 of 14',
      )));
      expect(find.byType(OrderStageDot), findsNWidgets(15));
      expect(find.text('Packing 14 of 14'), findsOneWidget);
      // Condensed means DOTS. Fifteen stage names would not fit a phone card,
      // so the strip carries the backend's one sentence instead of inventing
      // an abbreviation for each.
      expect(find.text('Ready to dispatch'), findsNothing);
    });

    testWidgets('no caption sent, no sentence drawn', (tester) async {
      await tester.pumpWidget(_host(OrderProgressLine(steps: _fifteen())));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('the dispute note rides the strip too', (tester) async {
      await tester.pumpWidget(_host(OrderProgressLine(
        steps: _fifteen(),
        caption: 'Packing 14 of 14',
        note: '2 items being re-sourced',
      )));
      expect(find.text('2 items being re-sourced'), findsOneWidget);
    });

    testWidgets('an empty stage list draws nothing', (tester) async {
      await tester.pumpWidget(
          _host(const OrderProgressLine(steps: [], caption: 'Packing')));
      expect(find.byType(OrderStageDot), findsNothing);
      expect(find.byType(Text), findsNothing);
    });
  });
}
