// PROTECTED — CMD #2071.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the WhatsApp reply-cap behaviour, never to make an
// unrelated change go green.
//
// WHY THIS FILE EXISTS
// +91 88844 10295 is another business's bot. Ours answered it, it answered
// ours, and the pair produced 910 outbound and 910 inbound messages in a
// single day. The backend now caps automated replies at
// whatsapp_bot_config.bot_reply_cap_24h (25) per number per rolling 24 hours:
// the 26th bot reply is refused and logged with reason 'bot_reply_cap', while
// a reply an admin types, an OTP and an order/payment notification are not on
// the capped-route allowlist and still go out.
//
// The DECISION is the backend's — `wa_bot_reply_allowed()` — and the SQL proof
// of it lives in scripts/test_bot_reply_cap.sql, replayed on the build branch.
// What this file holds down is the half that lives in Dart, and the failure
// mode that would quietly put the decision back into the client:
//
//   1. **The 26th reply's refusal is rendered, never computed.** The chat row
//      and the thread header show the cap strip ONLY when the payload said
//      bot_capped:true AND sent the words. A payload carrying sent_24h:26
//      against cap:25 with bot_capped:false renders NOTHING — Flutter never
//      compares the two numbers, because that comparison is the cap and the
//      cap is the backend's.
//
//   2. **The words are the backend's, verbatim.** No 'Bot paused' sentence,
//      no count, no pluralisation is assembled here. A flag with no label
//      renders nothing rather than a Dart-written stand-in.
//
//   3. **A manual admin reply is never capped.** The cap flag reaches the
//      thread as a header strip and touches nothing else: the composer, the
//      send button and the send path carry no cap state at all, which is why
//      an admin can still type into a capped thread. Held down here as: the
//      parsed thread result exposes the cap ONLY as display fields.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/features/whatsapp/models/wa_conversation.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_conversation_tile.dart';
import 'package:pharma_b2b/utils/render_log.dart';

const String _kLabel = 'Bot paused — cap reached';

Map<String, dynamic> _row({
  bool? capped,
  String? label,
  int sent = 0,
  int cap = 25,
}) =>
    <String, dynamic>{
      'sender_phone': '918884410295',
      'sender_type': 'other',
      'name': null,
      'label': null,
      'linked_supplier': null,
      'total': 1815,
      // No timestamp: DateLabels would otherwise start a real 16 ms batching
      // Timer that outlives the test and tries to reach Supabase. The tile's
      // time text is not what this file holds down.
      'last_at': null,
      'last_text': 'hello',
      'unread': 4387,
      if (capped != null) 'bot_capped': capped,
      if (label != null) 'bot_cap_label': label,
      'bot_sent_24h': sent,
      'bot_cap': cap,
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> row) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          child: WaConversationTile(
            conversation: WaConversation.fromJson(row),
            onTap: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('WhatsApp bot reply cap — the chat row', () {
    testWidgets('prints the backend label verbatim when the backend capped it',
        (tester) async {
      await _pump(tester, _row(capped: true, label: _kLabel, sent: 25));
      expect(find.text(_kLabel), findsOneWidget);
    });

    testWidgets('shows nothing when the backend did not cap it',
        (tester) async {
      await _pump(tester, _row(capped: false, label: _kLabel, sent: 3));
      expect(find.text(_kLabel), findsNothing);
    });

    testWidgets('never derives the cap from the counts itself', (tester) async {
      // 26 replies against a cap of 25 — and the backend still says false.
      // The row must believe the flag, not the arithmetic. If this ever goes
      // green by showing the strip, the cap has moved into the client.
      await _pump(tester, _row(capped: false, label: _kLabel, sent: 26, cap: 25));
      expect(find.text(_kLabel), findsNothing);
    });

    testWidgets('a flag with no words renders no stand-in sentence',
        (tester) async {
      await _pump(tester, _row(capped: true, sent: 40));
      expect(find.byType(WaConversationTile), findsOneWidget);
      expect(find.textContaining('paused'), findsNothing);
      expect(find.textContaining('cap'), findsNothing);
    });

    testWidgets('renders whatever words arrive, not a remembered phrase',
        (tester) async {
      const other = 'Automatic replies are off for today';
      await _pump(tester, _row(capped: true, label: other, sent: 25));
      expect(find.text(other), findsOneWidget);
      expect(find.text(_kLabel), findsNothing);
    });

    testWidgets('a capped row still shows its name, preview and unread badge',
        (tester) async {
      // The cap pauses the BOT, it does not hide the conversation: an admin
      // has to be able to open it and answer by hand.
      await _pump(tester, _row(capped: true, label: _kLabel, sent: 25));
      expect(find.text('hello'), findsOneWidget);
      expect(find.text('4387'), findsOneWidget);
    });
  });

  group('WhatsApp bot reply cap — the parsed conversation', () {
    test('absent cap fields parse as not capped', () {
      final c = WaConversation.fromJson(_row());
      expect(c.botCapped, isFalse);
      expect(c.botCapLabel, isNull);
      expect(c.showsBotCap, isFalse);
    });

    test('capped + label is the only combination that shows the strip', () {
      expect(
          WaConversation.fromJson(_row(capped: true, label: _kLabel))
              .showsBotCap,
          isTrue);
      expect(WaConversation.fromJson(_row(capped: true)).showsBotCap, isFalse);
      expect(
          WaConversation.fromJson(_row(capped: false, label: _kLabel))
              .showsBotCap,
          isFalse);
    });

    test('an empty label is the same as no label', () {
      final c = WaConversation.fromJson(_row(capped: true, label: '   '));
      expect(c.botCapLabel, isNull);
      expect(c.showsBotCap, isFalse);
    });

    test('the cap survives an unread-badge copyWith', () {
      final c = WaConversation.fromJson(_row(capped: true, label: _kLabel))
          .copyWith(unread: 0);
      expect(c.showsBotCap, isTrue);
      expect(c.botCapLabel, _kLabel);
    });
  });
}
