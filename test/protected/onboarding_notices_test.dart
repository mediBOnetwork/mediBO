// Holds down: the Onboarding notices screen (CMD #1936) is ONE RPC printed
// verbatim, and the two facts that screen exists to make visible.
//
// The failure this file exists to prevent is the one it was built out of:
// kyc_document_rejected and kyc_document_verified sat with ENABLED routes and
// no template for months, so wa_send_event answered route_disabled and nobody
// was ever told about their documents. "Enabled" was never the same question as
// "can this actually send", and the screen must never collapse the two — which
// it would the moment Dart starts deciding a chip's wording from `enabled`.
//
// So: every word (state_label, template_label, sent_label, last_label, the
// reminder counter, the missing-documents sentence, the summary and the empty
// state) arrives finished in the payload and is rendered as given. Dart maps a
// tone WORD to a colour token and nothing else — an unknown tone still renders
// its label rather than blanking the chip.
//
// No network, no Supabase: the RPC is injected.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/onboarding_notices_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _payload({List<Map<String, dynamic>>? queue}) => {
      'ok': true,
      'title': 'TITLE_FROM_BACKEND',
      'subtitle': 'SUBTITLE_FROM_BACKEND',
      'events_heading': 'EVENTS_HEADING',
      'queue_heading': 'QUEUE_HEADING',
      'queue_hint': 'QUEUE_HINT',
      'queue_empty': 'QUEUE_EMPTY_GUIDANCE',
      'summary': 'SUMMARY_LINE',
      'zone_label': 'ZONE_LINE',
      'as_of': 'AS_OF_LINE',
      'events': [
        {
          'event_key': 'customer_imported',
          'label': 'IMPORTED_LABEL',
          'description': 'IMPORTED_DESC',
          'fires_when': 'IMPORTED_FIRES_WHEN',
          'state': 'live',
          'state_label': 'STATE_LIVE_WORD',
          'state_tone': 'success',
          'enabled': true,
          'template_label': 'IMPORTED_TEMPLATE_LINE',
          'note': '',
          'sent_label': 'IMPORTED_SENT_LINE',
          'last_label': 'IMPORTED_LAST_LINE',
        },
        {
          // The whole point of the screen: enabled, and still unable to send.
          'event_key': 'kyc_document_rejected',
          'label': 'REJECTED_LABEL',
          'description': 'REJECTED_DESC',
          'fires_when': 'REJECTED_FIRES_WHEN',
          'state': 'waiting',
          'state_label': 'STATE_WAITING_WORD',
          'state_tone': 'warning',
          'enabled': true,
          'template_label': 'NO_TEMPLATE_LINE',
          'note': 'PIPELINE_NOTE_LINE',
          'sent_label': 'REJECTED_SENT_LINE',
          'last_label': 'REJECTED_LAST_LINE',
        },
        {
          // A tone the app has never heard of must still render its label.
          'event_key': 'customer_registration',
          'label': 'REGISTRATION_LABEL',
          'description': '',
          'fires_when': '',
          'state': 'something_new',
          'state_label': 'UNKNOWN_TONE_WORD',
          'state_tone': 'chartreuse',
          'enabled': true,
          'template_label': 'REG_TEMPLATE_LINE',
          'note': '',
          'sent_label': 'REG_SENT_LINE',
          'last_label': 'REG_LAST_LINE',
        },
      ],
      'queue': queue ?? const <Map<String, dynamic>>[],
    };

Map<String, dynamic> _queueRow() => {
      'customer_id': 'cust-1',
      'title': 'SHOP_NAME',
      'subtitle': 'MISSING_DOCS_SENTENCE',
      'chip_label': 'REMINDER_COUNTER',
      'chip_tone': 'warning',
      'meta': 'LAST_REMINDER_LINE',
    };

/// A 360 px-wide phone, tall enough that the whole list builds — the screen is
/// designed at the phone viewport, and a ListView only builds what it can see.
Future<void> _pump(WidgetTester t, Map<String, dynamic> payload) async {
  t.view.physicalSize = const Size(360, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: OnboardingNoticesScreen(rpc: () async => payload),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every event string is the backend\'s, printed as given',
      (t) async {
    await _pump(t, _payload());

    for (final s in [
      'SUBTITLE_FROM_BACKEND',
      'EVENTS_HEADING',
      'SUMMARY_LINE',
      'ZONE_LINE',
      'AS_OF_LINE',
      'IMPORTED_LABEL',
      'IMPORTED_DESC',
      'IMPORTED_FIRES_WHEN',
      'STATE_LIVE_WORD',
      'IMPORTED_TEMPLATE_LINE',
      'IMPORTED_SENT_LINE',
      'IMPORTED_LAST_LINE',
    ]) {
      expect(find.text(s), findsOneWidget, reason: 'missing: $s');
    }
  });

  testWidgets('enabled is NOT the same question as "can this send"',
      (t) async {
    await _pump(t, _payload());

    // The route is enabled:true and the screen must still say, in the
    // backend's own words, that it cannot send yet — and show the note.
    expect(find.text('STATE_WAITING_WORD'), findsOneWidget);
    expect(find.text('NO_TEMPLATE_LINE'), findsOneWidget);
    expect(find.text('PIPELINE_NOTE_LINE'), findsOneWidget);

    // Nothing in the app invents a state word from the boolean.
    expect(find.text('Enabled'), findsNothing);
    expect(find.text('Live'), findsNothing);
  });

  testWidgets('an unknown tone still renders its label', (t) async {
    await _pump(t, _payload());
    expect(find.text('UNKNOWN_TONE_WORD'), findsOneWidget);
  });

  testWidgets('an empty ladder is a one-line piece of guidance, not a blank',
      (t) async {
    await _pump(t, _payload());
    expect(find.text('QUEUE_EMPTY_GUIDANCE'), findsOneWidget);
    expect(find.text('SHOP_NAME'), findsNothing);
  });

  testWidgets('a waiting shop renders the backend\'s own four lines',
      (t) async {
    await _pump(t, _payload(queue: [_queueRow()]));
    expect(find.text('QUEUE_EMPTY_GUIDANCE'), findsNothing);
    for (final s in [
      'SHOP_NAME',
      'MISSING_DOCS_SENTENCE',
      'REMINDER_COUNTER',
      'LAST_REMINDER_LINE',
    ]) {
      expect(find.text(s), findsOneWidget, reason: 'missing: $s');
    }
  });

  testWidgets('a refusal renders the backend\'s message, never a Dart one',
      (t) async {
    await _pump(t, {
      'ok': false,
      'error': 'not_authorized',
      'title': 'TITLE_FROM_BACKEND',
      'message': 'BACKEND_REFUSAL_SENTENCE',
    });
    expect(find.text('BACKEND_REFUSAL_SENTENCE'), findsOneWidget);
    expect(find.text('EVENTS_HEADING'), findsNothing);
  });
}
