// PROTECTED — CMD #1931.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes payment-listener behaviour, never to make an unrelated
// change go green.
//
// What this holds down.
//
//   1. `show:false` draws NOTHING. That is the only thing keeping the
//      notification-listener card off web and off iOS — there is no
//      `if (Platform.isAndroid)` anywhere in the widget, by design, because
//      staff_home_native_card decides it and one UPDATE has to be able to turn
//      the card off on every phone at once.
//
//   2. The card is a PRINTER. The fixture deliberately pairs a status label of
//      "Listening, allegedly" with `enabled:false` and a tone of `success`, so
//      a card that re-derives its own label or its own colour from `enabled`
//      fails here. Same for the button: the label says "Manage" while the
//      grant is off.
//
//   3. The mute state is the backend's word, not the switch's. `speak_state`
//      is printed verbatim next to the switch.
//
//   4. Nothing is computed. No rupee string, no "last heard" date, no plural.
//      `last_alert` and `queued_label` are printed exactly as they arrived,
//      and an empty `queued_label` removes its row rather than printing blank.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/payment_listener_card.dart';

Map<String, dynamic> _payload({
  bool show = true,
  String queued = '',
  bool speakOn = true,
}) => <String, dynamic>{
  'ok': true,
  'show': show,
  'device_id': 'test-device',
  'title': 'Hear every payment',
  'body': 'A body the backend wrote.',
  'bullets': const ['Only listed apps.', 'A payment line only.', 'Off any time.'],
  'enabled': false,
  'status_label': 'Listening, allegedly',
  'status_sub': 'A sub-line the backend wrote.',
  'status_tone': 'success',
  'cta_label': 'Manage notification access',
  'speak_label': 'Speak the amount out loud',
  'speak_on': speakOn,
  'speak_state': speakOn ? 'On' : 'Muted',
  'volume': 70,
  'volume_label': 'Volume',
  'privacy_label': 'How we use this — Privacy Policy',
  'privacy_slug': 'privacy',
  'last_alert': 'Last payment heard 14 Sep, 01:12 pm.',
  'queued_label': queued,
};

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PaymentListenerCard(loader: () async => payload),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('show:false draws nothing at all', (tester) async {
    await _pump(tester, _payload(show: false));
    expect(find.byKey(const Key('c1931_listener_card')), findsNothing);
    expect(find.text('Hear every payment'), findsNothing);
  });

  testWidgets('every word is the payload\'s, none of it re-derived', (
    tester,
  ) async {
    await _pump(tester, _payload());
    expect(find.byKey(const Key('c1931_listener_card')), findsOneWidget);

    // The status chip says what the backend said, not what `enabled` implies.
    expect(find.text('Listening, allegedly'), findsOneWidget);
    expect(find.text('A sub-line the backend wrote.'), findsOneWidget);

    // The button label is the backend's too — "Manage" while the grant is off.
    expect(find.text('Manage notification access'), findsOneWidget);

    // Title, body and every bullet, verbatim.
    expect(find.text('Hear every payment'), findsOneWidget);
    expect(find.text('A body the backend wrote.'), findsOneWidget);
    expect(find.text('Only listed apps.'), findsOneWidget);
    expect(find.text('A payment line only.'), findsOneWidget);
    expect(find.text('Off any time.'), findsOneWidget);

    // The mute state, and the last-heard line, exactly as they arrived.
    expect(find.text('Speak the amount out loud'), findsOneWidget);
    expect(find.text('On'), findsOneWidget);
    expect(find.text('Last payment heard 14 Sep, 01:12 pm.'), findsOneWidget);
  });

  testWidgets('a muted phone prints the backend\'s muted word', (tester) async {
    await _pump(tester, _payload(speakOn: false));
    expect(find.text('Muted'), findsOneWidget);
    // Volume has nothing to say while the phone is muted.
    expect(find.text('Volume'), findsNothing);
  });

  testWidgets('an empty queue line removes its row, never prints blank', (
    tester,
  ) async {
    await _pump(tester, _payload());
    expect(find.text('3 waiting to send.'), findsNothing);
  });

  testWidgets('a queue line is printed exactly as the backend counted it', (
    tester,
  ) async {
    await _pump(tester, _payload(queued: '3 waiting to send.'));
    expect(find.text('3 waiting to send.'), findsOneWidget);
  });

  testWidgets('the primary action is full-width and at least 44 high', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, _payload());
    final box = tester.getSize(find.byKey(const Key('c1931_listener_cta')));
    expect(box.height, greaterThanOrEqualTo(44));
    // 360px phone, 16px card margin each side, 16px card padding each side.
    expect(box.width, greaterThan(280));
  });
}
