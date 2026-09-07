// PROTECTED — CMD #1849.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes what a test session's outbound receipt shows.
//
// THE POINT. A test session used to go silent. Silence proves nothing: you
// cannot tell a working inquiry waterfall from one that never fired. It now
// produces a receipt — every message, charge and page it WOULD have sent — and
// this holds down that the receipt is PRINTED, never computed.
//
// What this holds down:
//
//   1. THE SHEET COMPUTES NOTHING. The fixture's payment line deliberately
//      disagrees with its own `amount` and `channel`: the payload says
//      "Would have charged ₹1,240.00 to Sharma Medicos" while carrying
//      amount 999 on channel 'payment'. A sheet that formatted the rupee value
//      itself, or derived the sentence from the channel, fails here.
//
//   2. PAYLOAD ORDER IS THE TRANSCRIPT. The groups are deliberately NOT in
//      alphabetical order and neither are the lines inside them — that order is
//      the order the effects happened in, which is the whole reason the
//      waterfall is readable ("supplier A, then supplier B after no answer").
//
//   3. A PAYMENT IS A LINE, NEVER A BUTTON. Razorpay is live money. While a
//      session is running, a payment appears on the receipt as text and the
//      sheet offers no action that could reach it — there is no tappable
//      anywhere in the receipt.
//
//   4. ABSENCE IS EXPLICIT. has:false draws nothing at all; a session with no
//      effects yet draws the backend's own empty sentence, not an empty list
//      and not a dash.
//
//   5. TONE IS ONE LOOKUP. A tone this build has never heard of stays neutral
//      instead of being guessed from the words beside it.
//
//   6. NOTHING IS PLURALISED IN DART. `count_label` and each group's
//      `count_label` print exactly as sent, including a deliberately odd one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/outbound_receipt_sheet.dart';

/// A session that messaged one supplier, waited, messaged a second, asked for
/// money and paged the admin — in that order.
Map<String, dynamic> _receipt() => {
      'has': true,
      'session_id': 42,
      'title': 'What this session would have sent',
      'subtitle': 'Nothing below left the building.',
      'empty_label': 'Nothing has tried to leave yet.',
      'count_label': '5 outbound effects recorded',
      'count': 5,
      'groups': [
        {
          'channel': 'whatsapp',
          'label': 'WhatsApp',
          'count_label': '3 lines',
          'lines': [
            {
              'id': 1,
              'channel': 'whatsapp',
              'channel_label': 'WhatsApp',
              'at_label': '9:04 AM',
              'line': 'Would have messaged Sharma Medicos on WhatsApp on MB-1042',
              'template': 'supplier_inquiry',
              'verdict': 'sandboxed',
              'verdict_label': 'recorded',
              'tone': 'info',
            },
            {
              'id': 2,
              'channel': 'whatsapp',
              'channel_label': 'WhatsApp',
              'at_label': '9:11 AM',
              'line': 'Would have messaged Verma Pharma on WhatsApp on MB-1042',
              'template': 'supplier_inquiry',
              'verdict': 'sandboxed',
              'verdict_label': 'recorded',
              'tone': 'info',
            },
            {
              'id': 3,
              'channel': 'whatsapp',
              'channel_label': 'WhatsApp',
              'at_label': '9:12 AM',
              'line': 'Would have messaged Nanda Agencies on WhatsApp on MB-1042',
              'template': 'supplier_inquiry',
              'verdict': 'held',
              'verdict_label': 'held — could not tell whether this was a test row',
              'tone': 'warning',
            },
          ],
        },
        {
          'channel': 'payment',
          'label': 'Payment',
          'count_label': '1 line',
          'lines': [
            {
              'id': 4,
              'channel': 'payment',
              'channel_label': 'Payment',
              'at_label': '9:20 AM',
              // Deliberately disagrees with `amount` below: the sentence is the
              // backend's, and nothing here re-derives it.
              'line': 'Would have charged ₹1,240.00 to Sharma Medicos on MB-1042',
              'amount': 999,
              'template': 'rzp_checkout',
              'verdict': 'sandboxed',
              'verdict_label': 'recorded',
              'tone': 'info',
            },
          ],
        },
        {
          'channel': 'admin_page',
          'label': 'Admin paging',
          'count_label': '1 line',
          'lines': [
            {
              'id': 5,
              'channel': 'admin_page',
              'channel_label': 'Admin paging',
              'at_label': '9:22 AM',
              'line': 'Would have paged the admin on MB-1042',
              'template': 'order_alert',
              'verdict': 'leaked_blocked',
              'verdict_label': 'blocked at the wire — this call site is not routed yet',
              // A tone this build has never heard of.
              'tone': 'chartreuse',
            },
          ],
        },
      ],
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: OutboundReceiptView(payload: payload)),
    ),
  ));
}

void main() {
  testWidgets('1 — every string is the payload, including a rupee value that '
      'disagrees with its own amount field', (tester) async {
    await _pump(tester, _receipt());

    expect(find.text('What this session would have sent'), findsOneWidget);
    expect(find.text('5 outbound effects recorded'), findsOneWidget);
    // The backend's sentence, not a Dart-formatted 999.
    expect(find.text('Would have charged ₹1,240.00 to Sharma Medicos on MB-1042'),
        findsOneWidget);
    expect(find.textContaining('999'), findsNothing);
    // Channel names are the payload's own labels.
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Payment'), findsOneWidget);
    expect(find.text('Admin paging'), findsOneWidget);
  });

  testWidgets('2 — groups and lines render in payload order, not sorted',
      (tester) async {
    await _pump(tester, _receipt());

    double dy(String text) => tester.getTopLeft(find.text(text)).dy;

    // Groups: WhatsApp, then Payment, then Admin paging — alphabetical would
    // put Admin paging first.
    expect(dy('WhatsApp') < dy('Payment'), isTrue);
    expect(dy('Payment') < dy('Admin paging'), isTrue);

    // The waterfall: supplier A, then supplier B after no answer, then C.
    expect(
        dy('Would have messaged Sharma Medicos on WhatsApp on MB-1042') <
            dy('Would have messaged Verma Pharma on WhatsApp on MB-1042'),
        isTrue);
    expect(
        dy('Would have messaged Verma Pharma on WhatsApp on MB-1042') <
            dy('Would have messaged Nanda Agencies on WhatsApp on MB-1042'),
        isTrue);
  });

  testWidgets('3 — a payment is a line of text and nothing tappable',
      (tester) async {
    await _pump(tester, _receipt());

    // Razorpay is live money. The receipt reports; it never offers a way in.
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(GestureDetector), findsNothing);
  });

  testWidgets('4 — has:false draws nothing; an empty session draws the '
      "backend's own sentence", (tester) async {
    await _pump(tester, {'has': false});
    expect(find.byKey(const ValueKey('outbound_receipt')), findsNothing);
    expect(find.byType(Text), findsNothing);

    await _pump(tester, {
      'has': true,
      'title': 'What this session would have sent',
      'empty_label': 'Nothing has tried to leave yet.',
      'count_label': '',
      'count': 0,
      'groups': <dynamic>[],
    });
    expect(find.byKey(const ValueKey('outbound_receipt_empty')), findsOneWidget);
    expect(find.text('Nothing has tried to leave yet.'), findsOneWidget);
  });

  testWidgets('5 — an unknown tone stays neutral instead of being guessed',
      (tester) async {
    await _pump(tester, _receipt());

    Color chipColour(String verdict) {
      final box = tester.widget<Container>(find.ancestor(
        of: find.text(verdict),
        matching: find.byType(Container),
      ).first);
      return ((box.decoration as BoxDecoration).color)!;
    }

    final known = chipColour('recorded');
    final unknown =
        chipColour('blocked at the wire — this call site is not routed yet');
    expect(unknown, isNot(known));
    // Neutral is the page ground, never a colour borrowed from a nearby tone.
    expect(
        chipColour('held — could not tell whether this was a test row'),
        isNot(unknown));
  });

  testWidgets('6 — counts print verbatim, never pluralised here',
      (tester) async {
    final p = _receipt();
    (p['groups'] as List)[1]['count_label'] = '1 line (a charge)';
    p['count_label'] = '5 outbound effects recorded';
    await _pump(tester, p);

    expect(find.text('1 line (a charge)'), findsOneWidget);
    expect(find.text('3 lines'), findsOneWidget);
    expect(find.text('5 outbound effects recorded'), findsOneWidget);
  });
}
