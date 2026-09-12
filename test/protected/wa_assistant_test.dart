// PROTECTED — CHANGE #714. The WhatsApp order assistant's console.
//
// What this file holds down:
//
//   * the console computes NOTHING. The intent name, the outcome word and its
//     tone, the confidence percentage and the timestamp are all strings from
//     wa_assistant_console(); the screen never maps an outcome to a colour of
//     its own and never turns a 0..1 confidence into a percentage here;
//   * rows render in PAYLOAD order — the newest-first ordering is the
//     backend's ORDER BY, not a sort on this side;
//   * the three switch families all speak ONE verb: the master switch sends
//     {enabled}, an intent sends the backend's own {intent_key, enabled}, a
//     zone sends {zone_id, enabled}. A toggle never invents a key;
//   * whatever an intent row says about itself is ONE backend string (`note`)
//     printed verbatim - never the internal defer_to key, never the master
//     switch's sentence borrowed for an always_handoff row (CHANGE #714 D);
//   * ok:false renders the backend's refusal and no switches at all — the
//     console must not offer a control to someone it just refused.
//
// No network, no Supabase: every RPC is a mocked payload.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/wa_assistant_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _payload({bool ok = true, bool enabled = true}) => ok
    ? {
        'ok': true,
        'title': 'WhatsApp assistant',
        'subtitle':
            'What the assistant answered, what it handed to a person, and the switches that govern it.',
        'empty_note': 'The assistant has not replied to anything yet.',
        'switch_label': 'Assistant is on',
        'switch_off_note': 'Off — every message goes straight to a person.',
        'intents_heading': 'Which questions it may answer',
        'replies_heading': 'Last 50 replies',
        'zone_heading': 'Per zone',
        'enabled': enabled,
        'min_confidence': 0.75,
        'intents': const [
          {
            'key': 'where_is_order',
            'label': 'Where is my order',
            'enabled': true,
            'always_handoff': false,
            'defer_to': '',
            'needs_order': true,
            // nothing to say about this one
            'note': '',
          },
          {
            'key': 'reorder',
            'label': 'Reorder',
            'enabled': true,
            'always_handoff': false,
            // another feature owns this one. defer_to is still in the payload
            // (the handler reads it); it is NOT what the admin is shown.
            'defer_to': 'reorder_wa_inbound',
            'needs_order': false,
            'note': 'Already answered by an existing automatic reply.',
          },
          {
            'key': 'complaint',
            'label': 'Complaint',
            // deliberately ON, so a screen that borrowed the master switch's
            // "Off — ..." sentence for always_handoff rows contradicts itself.
            'enabled': true,
            'always_handoff': true,
            'defer_to': '',
            'needs_order': false,
            'note': 'Always handed to a person.',
          },
        ],
        'zones': const [
          {'zone_id': 1, 'zone_name': 'Raipur Zone', 'enabled': true},
          {'zone_id': 2, 'zone_name': 'Bilaspur Zone', 'enabled': false},
        ],
        // deliberately NOT in timestamp order as a Dart sort would produce
        'rows': const [
          {
            'key': '2',
            'phone': '9000000001',
            'inbound': 'kahan hai mera order',
            'intent': 'Where is my order',
            'intent_key': 'where_is_order',
            'confidence': 0.95,
            // the percentage is the BACKEND's arithmetic and its own string
            'confidence_label': '95%',
            'sentiment': 'neutral',
            'outcome': 'answered',
            'outcome_label': 'Answered',
            'outcome_tone': 'success',
            'reason': '',
            'reply': 'Order CPO1 — Finding suppliers.',
            'at': '03 Sep, 8:12 pm',
          },
          {
            'key': '1',
            'phone': '9000000002',
            'inbound': 'ye kya bakwaas hai',
            'intent': 'Complaint',
            'intent_key': 'complaint',
            'confidence': 0.97,
            'confidence_label': '97%',
            'sentiment': 'negative',
            'outcome': 'handoff',
            'outcome_label': 'Handed to a person',
            'outcome_tone': 'warning',
            'reason': 'negative_sentiment',
            'reply': 'Thank you — a person from our team will reply shortly.',
            'at': '03 Sep, 8:09 pm',
          },
        ],
      }
    : {
        'ok': false,
        'error': 'not_authorized',
        'title': 'WhatsApp assistant',
        'message': 'Only mediBO staff can see the assistant console.',
      };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  tearDown(() => WaAssistantScreen.rpcTransport = null);

  // The console is a long page: master switch, intents, zones, then fifty
  // replies. In the default 800x600 viewport the reply cards sit below the
  // fold and a ListView never builds them, so the surface is sized to the
  // whole page rather than the assertions being weakened to match a crop.
  // (setSurfaceSize is only legal INSIDE a test, never in setUp.)
  Future<void> pump(WidgetTester t, Map<String, dynamic> p,
      {Future<void> Function(Map<String, dynamic>)? onSet}) async {
    await t.binding.setSurfaceSize(const Size(1200, 3000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: WaAssistantView(payload: p, onSet: onSet)),
    ));
  }

  group('the assistant console prints the payload', () {
    testWidgets('outcomes, confidence and times are backend strings',
        (t) async {
      await pump(t, _payload());
      await t.pumpAndSettle();

      expect(find.text('Answered'), findsOneWidget);
      expect(find.text('Handed to a person'), findsOneWidget);
      expect(find.text('95%'), findsOneWidget);
      expect(find.text('97%'), findsOneWidget);
      expect(find.text('03 Sep, 8:12 pm'), findsOneWidget);
      // the raw values behind those strings are never printed
      expect(find.text('0.95'), findsNothing);
      expect(find.text('answered'), findsNothing);
    });

    testWidgets('rows render in payload order, not sorted here', (t) async {
      await pump(t, _payload());
      await t.pumpAndSettle();
      expect(t.getTopLeft(find.text('kahan hai mera order')).dy,
          lessThan(t.getTopLeft(find.text('ye kya bakwaas hai')).dy));
    });

    testWidgets('the master switch sends {enabled} and nothing else',
        (t) async {
      Map<String, dynamic>? sent;
      await pump(t, _payload(), onSet: (p) async => sent = p);
      await t.pumpAndSettle();

      await t.tap(find.byType(SwitchListTile).first);
      await t.pumpAndSettle();
      expect(sent, {'enabled': false});
    });

    testWidgets('an intent toggle carries the backend key', (t) async {
      Map<String, dynamic>? sent;
      await pump(t, _payload(), onSet: (p) async => sent = p);
      await t.pumpAndSettle();

      // the first intent switch, after the master switch
      await t.tap(find.byType(SwitchListTile).at(1));
      await t.pumpAndSettle();
      expect(sent, {'intent_key': 'where_is_order', 'enabled': false});
    });

    testWidgets('a zone toggle carries the backend zone id', (t) async {
      Map<String, dynamic>? sent;
      await pump(t, _payload(), onSet: (p) async => sent = p);
      await t.pumpAndSettle();

      // Anchored on the zone's own name rather than counted from the top:
      // the index form silently moved every time an intent was added to the
      // fixture, which is a test measuring the fixture, not the screen.
      await t.tap(find.ancestor(
          of: find.text('Raipur Zone'), matching: find.byType(SwitchListTile)));
      await t.pumpAndSettle();
      expect(sent, {'zone_id': 1, 'enabled': false});
    });

    // CHANGE #714 (D). The first live screenshot of this console showed
    // `reorder_wa_inbound` under "Reorder" and "Off — every message goes
    // straight to a person." under "Complaint" while Complaint's own toggle
    // was on. Both were the SCREEN choosing a sentence. It no longer chooses.
    testWidgets('an intent note is the backend sentence, verbatim', (t) async {
      await pump(t, _payload());
      await t.pumpAndSettle();
      expect(find.text('Already answered by an existing automatic reply.'),
          findsOneWidget);
      expect(find.text('Always handed to a person.'), findsOneWidget);
    });

    testWidgets('no internal key is ever printed at an admin', (t) async {
      await pump(t, _payload());
      await t.pumpAndSettle();
      expect(find.text('reorder_wa_inbound'), findsNothing);
    });

    testWidgets('an intent with an empty note gets no subtitle at all',
        (t) async {
      await pump(t, _payload());
      await t.pumpAndSettle();
      final tile = t.widget<SwitchListTile>(find.ancestor(
          of: find.text('Where is my order'),
          matching: find.byType(SwitchListTile)));
      expect(tile.subtitle, isNull);
    });

    testWidgets('the master switch note never leaks onto an intent row',
        (t) async {
      // The payload is ON, so switch_off_note belongs nowhere on this screen.
      await pump(t, _payload());
      await t.pumpAndSettle();
      expect(find.text('Off — every message goes straight to a person.'),
          findsNothing);
    });

    testWidgets('off prints the backend note about what off means', (t) async {
      await pump(t, _payload(enabled: false));
      await t.pumpAndSettle();
      expect(find.text('Off — every message goes straight to a person.'),
          findsWidgets);
    });

    testWidgets('a refusal prints the message and offers no switches',
        (t) async {
      await pump(t, _payload(ok: false));
      await t.pumpAndSettle();
      expect(find.text('Only mediBO staff can see the assistant console.'),
          findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.text('Answered'), findsNothing);
    });

    testWidgets('no replies yet prints the backend empty line', (t) async {
      final p = _payload();
      p['rows'] = const [];
      await pump(t, p);
      await t.pumpAndSettle();
      expect(find.text('The assistant has not replied to anything yet.'),
          findsOneWidget);
    });
  });
}
