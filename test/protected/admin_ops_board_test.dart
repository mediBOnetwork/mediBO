// PROTECTED — CHANGE (cmd #356): feature_gaps #42 and #58, the admin surface's
// two critical register rows.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes send-fault-banner or ops-board behaviour.
//
// WHAT THIS HOLDS DOWN, and why each one is here:
//
//   #42 — "A WABA billing block stopped a real login OTP and no screen says so."
//   On 2026-08-30 wa_waba_state read APPROVED / GREEN / TIER_250 while Meta
//   refused our sends for billing; two of the refused sends were login OTPs, so
//   a real customer could not sign in and every screen stayed green. The bug was
//   not a missing figure — it was one card answering the OTHER question. So:
//     1. The banner appears above the Meta card exactly when the BACKEND says
//        show:true, and not otherwise. A screen that decided for itself when to
//        cry wolf would re-create the original bug in the other direction.
//     2. Meta's reason is printed VERBATIM. It is the string an admin pastes
//        into Meta support; a rephrasing here makes it useless there.
//     3. The sign-in line and the "the green card below answers a different
//        question" line are backend sentences, printed as given.
//
//   #58 — "Nothing anywhere answers 'what is stuck right now'."
//   Seven tables of stalled work with no shared surface and NO AGE anywhere.
//   So:
//     4. Classes render in PAYLOAD ORDER. admin_ops_board() ranks worst-first by
//        how far each queue is past ITS OWN deadline; the fixture is deliberately
//        NOT in count order, so any client-side sort by size fails this test.
//        "Biggest list first" is precisely the ranking the register row rejected.
//     5. Every count, age and stage is a backend string. Nothing is pluralised,
//        totalled or clock-computed in Dart.
//     6. An empty board is the backend's empty_label, not a crash and not a
//        hand-written "All good".
//     7. A refusal renders the backend's own message instead of throwing.
//
// No network, no Supabase, no goldens. Fixtures mirror payloads read off the
// live database on 2026-08-31.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_ops_board_screen.dart';
import 'package:pharma_b2b/screens/admin/wa_ops_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── Fixtures ────────────────────────────────────────────────────────────────

/// wa_waba_status().send_health as it read on 2026-08-31: the account card is
/// green, and 90 sends were refused for billing, 2 of them sign-in messages.
Map<String, dynamic> healthBlocking() => {
      'ok': true,
      'show': true,
      'tone': 'bad',
      'title': 'WhatsApp sending is blocked by a billing problem on the Meta account',
      'meta_reason': 'Business eligibility payment issue',
      'detail': 'Meta is refusing our sends for payment reasons.',
      'action_label': 'Open Meta Business Manager and clear the payment method',
      'count_label': '90 sends refused for this reason',
      'last_label': 'Last 31 Aug, 08:20 PM',
      'auth_blocked': true,
      'auth_count': 2,
      'auth_label': '2 of them were sign-in messages — those people could not log in',
      'contradiction_label':
          "Meta's account health below still reads healthy — it reports the account review, not our sends.",
    };

/// wa_waba_status() as it read on 2026-08-31 — the green Meta card that made
/// #42 invisible, now carrying send_health beside it.
Map<String, dynamic> wabaStatus({required bool blocked}) => {
      'waba_name': 'mediBO',
      'review_status': 'APPROVED',
      'templates_label': '4 of 250 templates used',
      'templates_used': 4,
      'templates_limit': 250,
      'templates_pct': 2,
      'templates_tone': 'good',
      'tier_label': 'Messaging tier: TIER_250',
      'quality_label': 'Number quality: GREEN',
      'quality_tone': 'good',
      'checked_label': 'Checked 31 Aug, 08:13 PM',
      'error': null,
      'note': 'Meta caps a WhatsApp Business Account at 250 templates.',
      'send_health': blocked
          ? healthBlocking()
          : {...healthBlocking(), 'show': false, 'tone': 'good'},
    };

/// The rest of the Ops screen's reads, stubbed empty so only the health section
/// has anything to paint.
Widget waOps({required bool blocked}) => MaterialApp(
      home: WaOpsScreen(
        refreshDelay: Duration.zero,
        routesRpc: () async => {'rows': const []},
        wabaStatusRpc: () async => wabaStatus(blocked: blocked),
        wabaRefreshRpc: () async => const <String, dynamic>{},
        ledgerRpc: (_, __) async => {'rows': const []},
        zonesRpc: () async => {'rows': const []},
      ),
    );

/// Deliberately NOT in count order: the 6-item class outranks the 46-item one
/// because it is further past its own deadline. Payload order is the ranking.
Map<String, dynamic> boardPayload() => {
      'ok': true,
      'title': 'What is stuck right now',
      'subtitle': '174 items waiting, 142 past their deadline',
      'headline_label': '142 overdue',
      'headline_count': 174,
      'headline_tone': 'bad',
      'worst_label': 'Worst: Payment claims not verified',
      'empty_label': 'Nothing is stuck. Every queue is inside its deadline.',
      'checked_label': 'Read 31 Aug, 09:11 PM',
      'note': 'Worst-first is measured against each queue\'s own deadline.',
      'items': [
        {
          'key': 'claims_unverified',
          'title': 'Payment claims not verified',
          'stage_label': 'Payment claimed',
          'owner_label': 'Waiting on: Admin',
          'action_label': 'Verify the UTR against the bank',
          'action_route': 'payments',
          'count': 6,
          'count_label': '6 claims',
          'age_label': 'oldest 41 days',
          'over_sla': 6,
          'over_sla_label': '6 past 24h',
          'tone': 'bad',
          'items': [
            {
              'id': 'a1',
              'label': 'UTR 552211',
              'sub_label': 'Chandra Medical',
              'age_label': '41 days',
              'over_sla': true,
            },
          ],
        },
        {
          'key': 'supplier_unsettled',
          'title': 'Supplier orders not settled',
          'stage_label': 'Supplier order placed',
          'owner_label': 'Waiting on: Admin',
          'action_label': 'Settle the supplier order',
          'action_route': 'suppliers',
          'count': 46,
          'count_label': '46 supplier orders',
          'age_label': 'oldest 42 days',
          'over_sla': 40,
          'over_sla_label': '40 past 72h',
          'tone': 'bad',
          'items': const [],
        },
      ],
    };

Map<String, dynamic> boardEmpty() => {
      'ok': true,
      'title': 'What is stuck right now',
      'subtitle': 'Nothing is waiting past its deadline.',
      'headline_label': 'All clear',
      'headline_count': 0,
      'headline_tone': 'good',
      'worst_label': '',
      'empty_label': 'Nothing is stuck. Every queue is inside its deadline.',
      'checked_label': 'Read 31 Aug, 09:11 PM',
      'note': '',
      'items': const [],
    };

Widget host(Widget child) => MaterialApp(home: child);

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  // ── #58 — the ops board ───────────────────────────────────────────────────

  group('feature_gaps #58 — the ops board answers "what is stuck right now"',
      () {
    testWidgets('classes render in PAYLOAD order, not by size', (t) async {
      await t.pumpWidget(host(AdminOpsBoardScreen(
        boardRpc: (_) async => boardPayload(),
      )));
      await t.pumpAndSettle();

      final claims = t.getTopLeft(find.byKey(const Key('ops_board_class_claims_unverified'))).dy;
      final suppliers = t.getTopLeft(find.byKey(const Key('ops_board_class_supplier_unsettled'))).dy;

      // 6 claims sit ABOVE 46 supplier orders because the backend ranked them
      // that way. Sorting by count in Dart would flip this and pass nothing.
      expect(claims, lessThan(suppliers));
    });

    testWidgets('counts, ages and stages are backend strings, printed verbatim',
        (t) async {
      await t.pumpWidget(host(AdminOpsBoardScreen(
        boardRpc: (_) async => boardPayload(),
      )));
      await t.pumpAndSettle();

      expect(find.text('142 overdue'), findsOneWidget);
      expect(find.text('174 items waiting, 142 past their deadline'), findsOneWidget);
      expect(find.text('Worst: Payment claims not verified'), findsOneWidget);
      expect(find.text('6 claims'), findsOneWidget);
      expect(find.text('46 supplier orders'), findsOneWidget);
      expect(find.text('oldest 41 days'), findsOneWidget);
      expect(find.text('6 past 24h'), findsOneWidget);
      expect(find.text('Waiting on: Admin'), findsNWidgets(2));
      expect(find.text('Payment claimed'), findsOneWidget);

      // The example row and its age come from the payload too.
      expect(find.text('UTR 552211'), findsOneWidget);
      expect(find.text('41 days'), findsOneWidget);

      // Nothing invented: the screen never writes its own total.
      expect(find.text('174'), findsNothing);
    });

    testWidgets('the action carries the backend route key', (t) async {
      final taps = <String>[];
      await t.pumpWidget(host(AdminOpsBoardScreen(
        boardRpc: (_) async => boardPayload(),
        onNavigate: taps.add,
      )));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('ops_board_action_claims_unverified')));
      await t.pumpAndSettle();

      expect(taps, ['payments']);
    });

    testWidgets('an empty board is the backend empty state, not a crash',
        (t) async {
      await t.pumpWidget(host(AdminOpsBoardScreen(
        boardRpc: (_) async => boardEmpty(),
      )));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('ops_board_empty')), findsOneWidget);
      expect(find.text('Nothing is stuck. Every queue is inside its deadline.'),
          findsOneWidget);
      expect(find.text('All clear'), findsOneWidget);
    });

    testWidgets('a refusal prints the backend message instead of throwing',
        (t) async {
      await t.pumpWidget(host(AdminOpsBoardScreen(
        boardRpc: (_) async => {'ok': false, 'error': 'not_authorized'},
      )));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('ops_board_error')), findsOneWidget);
      expect(find.text('not_authorized'), findsOneWidget);
    });
  });

  // ── #42 — the send-fault banner ───────────────────────────────────────────
  //
  // The banner lives inside wa_ops_screen's account-health section, which owns
  // three other RPCs. Rather than stand that whole screen up, these tests hold
  // the CONTRACT the banner is built on: `show` is the backend's decision, and
  // every visible string comes from the payload untouched. The widget reads
  // exactly these keys and nothing else.

  group('feature_gaps #42 — the send-fault banner sits above the Meta card', () {
    testWidgets('it appears when the backend says show, ABOVE the green card',
        (t) async {
      await t.pumpWidget(waOps(blocked: true));
      await t.pumpAndSettle();

      final banner = find.byKey(const Key('wa_ops_send_fault'));
      expect(banner, findsOneWidget);

      // Above the Meta figures, not below them: an admin reading top-down must
      // hit the block before the reassurance.
      final bannerY = t.getTopLeft(banner).dy;
      final metaY = t.getTopLeft(find.text('4 of 250 templates used')).dy;
      expect(bannerY, lessThan(metaY));
    });

    testWidgets('Meta\'s reason is printed VERBATIM', (t) async {
      await t.pumpWidget(waOps(blocked: true));
      await t.pumpAndSettle();

      // The exact string wa_send_attempts.reason held on 2026-08-30. It is what
      // an admin pastes into Meta support; title-casing or "friendlier" copy
      // here makes it unmatchable there.
      expect(find.text('Business eligibility payment issue'), findsOneWidget);
      expect(find.byKey(const Key('wa_ops_send_fault_reason')), findsOneWidget);
    });

    testWidgets('the sign-in consequence and the contradiction are printed',
        (t) async {
      await t.pumpWidget(waOps(blocked: true));
      await t.pumpAndSettle();

      expect(
          find.text(
              '2 of them were sign-in messages — those people could not log in'),
          findsOneWidget);
      // The whole point of the row: the banner says out loud that the green
      // Meta card below it is answering a different question.
      expect(find.byKey(const Key('wa_ops_send_fault_contradiction')),
          findsOneWidget);

      // And the card underneath still reports what Meta says, unchanged — the
      // fix adds a second answer, it does not silence the first.
      expect(find.text('APPROVED'), findsOneWidget);
    });

    testWidgets('show:false paints no banner — the screen never cries wolf',
        (t) async {
      // 1084 undeliverable numbers is noise, not an outage. `show` is the
      // backend's decision; a screen that raised the banner off a raw failure
      // count would re-create the original bug in the other direction.
      await t.pumpWidget(waOps(blocked: false));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('wa_ops_send_fault')), findsNothing);
      expect(find.text('APPROVED'), findsOneWidget);
    });
  });
}
