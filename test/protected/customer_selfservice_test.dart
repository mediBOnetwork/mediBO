// CMD #452 — the customer self-service layer, pinned.
//
// feature_gaps #130 (cancel), #131 (returns), #132 (support) and #133
// (timeline) all shipped as ONE rule: the buyer's surfaces render the
// backend's answer and decide nothing. These tests hold that rule down on the
// pure decision points, so a later "small tidy" cannot quietly put a window
// rule, a status word or a rupee back into Dart.
//
// Everything here runs on the Dart VM with inline payloads — no network, no
// Supabase, no goldens.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/services/customer_care_service.dart';
import 'package:pharma_b2b/screens/delivery/customer_track_sheet.dart'
    show OrderTimelineCard;
import 'package:pharma_b2b/screens/customer/order_return_sheet.dart'
    show OrderReturnsPanel;
import 'package:pharma_b2b/screens/customer/order_help_sheet.dart'
    show SupportStatusChip;
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  setUpAll(() {
    // The debounce inside RenderLog.write is a real Timer that would outlive
    // these tests and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  group('payload readers — absence is explicit', () {
    test('a missing string is empty, never a Dart fallback word', () {
      expect(careStr(const {}, 'label'), '');
      expect(careStr(null, 'label'), '');
      expect(careStr(const {'label': 'Cancel order'}, 'label'), 'Cancel order');
    });

    test('careRows tolerates a null, a scalar and a mixed list', () {
      expect(careRows(null), isEmpty);
      expect(careRows('nope'), isEmpty);
      expect(careRows(const [1, 'x']), isEmpty);
      expect(
          careRows(const [
            {'code': 'damaged'}
          ]).single['code'],
          'damaged');
    });
  });

  group('#133 — the timeline is the payload, not a comparison', () {
    // The BACKEND says which step is current. Dart never compares timestamps.
    final payload = {
      'heading': 'Order progress',
      'current': 'sourcing',
      'eta_label': 'Expected delivery',
      'eta_display': 'We will confirm a delivery date once suppliers confirm.',
      'steps': [
        {
          'key': 'placed',
          'label': 'Order placed',
          'state': 'done',
          'ts_label': '01 Sep 2026, 09:16 AM',
          'note': ''
        },
        {
          'key': 'sourcing',
          'label': 'Finding suppliers',
          'state': 'current',
          'ts_label': '01 Sep 2026, 10:02 AM',
          'note': ''
        },
        {
          'key': 'packed',
          'label': 'Packed',
          'state': 'pending',
          'ts_label': '',
          'note': 'Packing starts once the items are in.'
        },
      ],
    };

    testWidgets('every step label, stamp and note prints verbatim, in order',
        (tester) async {
      await tester.pumpWidget(_host(OrderTimelineCard(timeline: payload)));

      expect(find.text('Order progress'), findsOneWidget);
      expect(find.text('Order placed'), findsOneWidget);
      expect(find.text('Finding suppliers'), findsOneWidget);
      expect(find.text('Packed'), findsOneWidget);
      expect(find.text('01 Sep 2026, 09:16 AM'), findsOneWidget);
      expect(find.text('Packing starts once the items are in.'), findsOneWidget);
      expect(find.text('Expected delivery'), findsOneWidget);
      expect(
          find.text(
              'We will confirm a delivery date once suppliers confirm.'),
          findsOneWidget);

      // Payload order, not alphabetical and not re-sorted by state.
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      expect(labels.indexOf('Order placed'),
          lessThan(labels.indexOf('Finding suppliers')));
      expect(labels.indexOf('Finding suppliers'),
          lessThan(labels.indexOf('Packed')));
    });

    testWidgets('a step with no stamp shows none — never an invented one',
        (tester) async {
      await tester.pumpWidget(_host(OrderTimelineCard(timeline: payload)));
      // 'packed' carries ts_label:'' — no third timestamp is drawn.
      expect(find.textContaining('Sep 2026'), findsNWidgets(2));
    });

    testWidgets('an empty payload renders nothing at all', (tester) async {
      await tester.pumpWidget(_host(const OrderTimelineCard(timeline: {})));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('state drives the glyph — a "done" step is ticked',
        (tester) async {
      await tester.pumpWidget(_host(OrderTimelineCard(timeline: payload)));
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    });
  });

  group('#131 — returns and the credit note print, they do not compute', () {
    final panel = {
      'title': 'Returns on this order',
      'empty_note': 'No returns on this order yet.',
      'has_returns': true,
      'has_credit': true,
      'credit_total_label': 'Credit on this order',
      'credit_total_display': '₹1,234.50',
      'credit_note': 'Credit notes are set against your next bill.',
      'returns': [
        {
          'name': 'Megval 50mg Injection',
          'qty_label': '2',
          'reason_label': 'Damaged in transit',
          'condition_label': 'Damaged',
          'raised_label': '01 Sep 2026, 11:20 AM',
          'credit_display': '₹1,234.50',
          'status_label': 'Credited',
          'status_tone': 'success',
          'reject_reason': '',
        },
      ],
    };

    testWidgets('rupees and the status word are backend strings',
        (tester) async {
      await tester.pumpWidget(_host(OrderReturnsPanel(panel: panel)));
      expect(find.text('₹1,234.50'), findsNWidgets(2)); // line + total
      expect(find.text('Credited'), findsOneWidget);
      expect(find.text('Credit on this order'), findsOneWidget);
      expect(find.text('Credit notes are set against your next bill.'),
          findsOneWidget);
      // The reason/condition strip is joined from the payload's own words.
      expect(find.text('2 · Damaged in transit · Damaged'), findsOneWidget);
    });

    testWidgets('no credit on the order means no credit row', (tester) async {
      final noCredit = Map<String, dynamic>.from(panel)
        ..['has_credit'] = false;
      await tester.pumpWidget(_host(OrderReturnsPanel(panel: noCredit)));
      expect(find.text('Credit on this order'), findsNothing);
      expect(find.text('₹1,234.50'), findsOneWidget); // only the line's own
    });

    testWidgets('an empty returns list shows the backend empty note',
        (tester) async {
      await tester.pumpWidget(_host(OrderReturnsPanel(panel: const {
        'title': 'Returns on this order',
        'empty_note': 'No returns on this order yet.',
        'returns': [],
      })));
      expect(find.text('No returns on this order yet.'), findsOneWidget);
    });
  });

  group('#132 — the ticket status chip is the payload', () {
    testWidgets('label and tone both come from the row', (tester) async {
      await tester.pumpWidget(_host(const SupportStatusChip(ticket: {
        'status_label': 'Answered',
        'status_tone': 'info',
      })));
      expect(find.text('Answered'), findsOneWidget);
      final box = tester.widget<Container>(find.byType(Container).first);
      expect((box.decoration as BoxDecoration).color, Ds.c.infoSoft);
    });

    testWidgets('an unknown tone still renders — it never throws',
        (tester) async {
      await tester.pumpWidget(_host(const SupportStatusChip(ticket: {
        'status_label': 'Escalated',
        'status_tone': 'chartreuse',
      })));
      expect(find.text('Escalated'), findsOneWidget);
    });

    testWidgets('no label means no chip, not an empty box', (tester) async {
      await tester
          .pumpWidget(_host(const SupportStatusChip(ticket: {'status_tone': 'info'})));
      expect(find.byType(Container), findsNothing);
    });
  });
}
