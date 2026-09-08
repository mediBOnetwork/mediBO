// CHANGE #300 — the Razorpay webhook delivery card renders the payload and
// decides nothing.
//
// The payload fixture below is a VERBATIM copy of what
// rzp_webhook_log_recent() answered on production while #300 was being built —
// including the deliberately deceptive bits: the label for handled:false is
// "Acknowledged" (not "Ignored"), the count is pluralised server-side, and the
// tone words are the backend's. If the card ever starts computing any of these
// in Dart, one of these tests goes red.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/webhook_log_card.dart';
import 'package:pharma_b2b/design_tokens.dart';

Map<String, dynamic> live({bool has = true, List? rows}) => {
      'ok': true,
      'has': has,
      'title': 'Webhook deliveries',
      'subtitle': 'What Razorpay has sent this endpoint',
      'empty':
          'No deliveries yet. Razorpay posts here the moment a QR is paid or closed.',
      'count_label': '2 deliveries',
      'rows': rows ??
          [
            {
              'event': 'qr_code.credited',
              'handled': true,
              'status_label': 'Acted on',
              'status_tone': 'success',
              'payload_id': 'pay_TT8rVc4p51Kt1E',
              'at_label': '23 Aug, 5:03 pm',
            },
            {
              'event': 'payment.authorized',
              'handled': false,
              'status_label': 'Acknowledged',
              'status_tone': 'neutral',
              'payload_id': 'pay_selftest_293',
              'at_label': '23 Aug, 2:42 pm',
            },
          ],
    };

Future<void> pump(WidgetTester t, Map<String, dynamic> payload) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: WebhookLogCard(payload: payload)),
    ),
  ));
}

void main() {
  testWidgets('title, subtitle and count come from the payload', (t) async {
    await pump(t, live());
    expect(find.text('Webhook deliveries'), findsOneWidget);
    expect(find.text('What Razorpay has sent this endpoint'), findsOneWidget);
    // pluralised by the BACKEND — Dart must never append an "s"
    expect(find.text('2 deliveries'), findsOneWidget);
  });

  testWidgets('the chip is the backend word, not a rendering of handled',
      (t) async {
    await pump(t, live());
    expect(find.text('Acted on'), findsOneWidget);
    // handled:false is "Acknowledged" here. A card that derived the label from
    // the boolean would almost certainly print "Ignored" or "Not handled".
    expect(find.text('Acknowledged'), findsOneWidget);
    expect(find.text('Ignored'), findsNothing);
    expect(find.text('Not handled'), findsNothing);
  });

  testWidgets('rows render in payload order, event and id verbatim', (t) async {
    await pump(t, live());
    final events = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => s.startsWith('qr_code.') || s.startsWith('payment.'))
        .toList();
    expect(events, ['qr_code.credited', 'payment.authorized']);
    expect(find.text('23 Aug, 5:03 pm · pay_TT8rVc4p51Kt1E'), findsOneWidget);
  });

  testWidgets('a row with no payload_id shows the time alone, no stray dot',
      (t) async {
    await pump(
        t,
        live(rows: [
          {
            'event': 'qr_code.closed',
            'handled': false,
            'status_label': 'Acknowledged',
            'status_tone': 'neutral',
            'payload_id': '',
            'at_label': '23 Aug, 6:00 pm',
          }
        ]));
    expect(find.text('23 Aug, 6:00 pm'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets('emptiness is the backend flag, not rows.isEmpty', (t) async {
    // has:false while rows still carries entries — the backend is the authority
    await pump(t, live(has: false));
    expect(
        find.text(
            'No deliveries yet. Razorpay posts here the moment a QR is paid or closed.'),
        findsOneWidget);
    expect(find.text('qr_code.credited'), findsNothing);
  });

  testWidgets('an unknown tone degrades to neutral instead of throwing',
      (t) async {
    await pump(
        t,
        live(rows: [
          {
            'event': 'refund.processed',
            'handled': false,
            'status_label': 'Something new',
            'status_tone': 'ultraviolet',
            'payload_id': 'rfnd_1',
            'at_label': '23 Aug, 7:00 pm',
          }
        ]));
    expect(find.text('Something new'), findsOneWidget);
    expect(WebhookLogCard.toneBg('ultraviolet'), Ds.c.bg);
    expect(WebhookLogCard.toneFg('ultraviolet'), Ds.c.textSecondary);
  });
}
