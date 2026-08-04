// PROTECTED — WhatsApp campaign console.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes campaign-list behaviour.
//
// What this holds down:
//
//   1. STATUS COMES FROM THE PAYLOAD. status_label and status_tone are printed
//      and coloured as given. The app owns no status -> words map and no
//      status -> colour map, so a backend that renames "running" to something
//      else needs no deploy.
//
//   2. summary_label and result_label are printed VERBATIM. They are pre-built
//      sentences containing counts, a rupee total and separators. The moment
//      Dart assembles either one from stats{}, the card and the backend hold
//      two renderings of the same numbers and can disagree.
//
//   3. BUTTONS FOLLOW FLAGS, NOT STATUS. A running campaign shows Pause and
//      must NOT show Schedule — even though a reader of `status` could infer
//      either. The backend already decided; the app asks.
//
//   4. THE POLICY STRIP IS DATA. It prints the payload's own sentences. A
//      fixture with a 7:00–22:00 window must render 7:00–22:00, which a
//      hardcoded "9:00–20:00 IST" would fail. This is the test that keeps a
//      threshold change from becoming a deploy.
//
//   5. AN UNKNOWN TONE IS NOT A CRASH. wa_campaign_detail already emits a tone
//      ('blue') that the list RPC never emits; a sixth added tomorrow must
//      render grey with its label intact rather than blank an admin's screen.
//
// Fixtures mirror the real wa_campaigns_screen() payload, read off the live
// database on 2026-08-04. No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/ui/wa_campaign_chips.dart';
import 'package:pharma_b2b/screens/admin/wa_campaigns_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _campaign({
  String id = 'c1',
  String name = 'August refill push',
  String status = 'running',
  String statusLabel = 'Sending',
  String statusTone = 'green',
  String? pausedReason,
  bool canEdit = false,
  bool canSchedule = false,
  bool canApprove = false,
  bool canPause = true,
  bool canResume = false,
  bool canResendFailed = false,
}) =>
    {
      'id': id,
      'name': name,
      'template': 'refill_reminder',
      'category': 'MARKETING',
      'status': status,
      'status_label': statusLabel,
      'status_tone': statusTone,
      'audience_label': 'Segment: all approved',
      'schedule_label': '05 Aug, 10:00 am',
      'paused_reason': pausedReason,
      'stats': {
        'total': 500,
        'sent': 420,
        'delivered': 310,
        'read': 180,
        'failed': 4,
        'skipped': 12,
        'clicks': 44,
        'orders': 9,
        'revenue': 47000,
      },
      'summary_label': '420 sent · 310 delivered · 180 read · 4 failed',
      'result_label': '44 clicks · 9 orders · ₹47,000.00',
      'can_edit': canEdit,
      'can_schedule': canSchedule,
      'can_approve': canApprove,
      'can_pause': canPause,
      'can_resume': canResume,
      'can_resend_failed': canResendFailed,
    };

/// Deliberately NOT the live values — a hardcoded strip would pass against
/// 9:00–20:00 and fail here, which is the whole point.
Map<String, dynamic> _policy() => {
      'send_window': {'start_hour': 7, 'end_hour': 22, 'tz': 'Asia/Kolkata'},
      'frequency_cap': {'marketing_per_days': 5},
      'auto_pause': {'min_attempts': 40, 'failure_rate_pct': 15},
      'approval': {'required_above_recipients': 250},
      'cost_per_conversation': {
        'MARKETING': 0.7846,
        'UTILITY': 0.115,
        'AUTHENTICATION': 0.115,
        'currency': '₹',
      },
      'send_window_label': 'Sends 7:00–22:00 IST',
      'frequency_cap_label': 'One marketing message per customer every 5 days',
      'auto_pause_label': 'Auto-pauses above 15% failures after 40 attempts',
      'approval_label': 'Needs approval above 250 recipients',
    };

Map<String, dynamic> _payload({
  List<Map<String, dynamic>>? campaigns,
  int suppressed = 37,
}) =>
    {
      'ok': true,
      'campaigns': campaigns ?? [_campaign()],
      'audiences': [
        {'key': 'all_approved', 'label': 'All approved customers'},
        {'key': 'zone', 'label': 'By zone', 'needs': 'zone_id'},
      ],
      'triggers': [
        {'key': 'payment_due', 'label': 'Payment pending', 'needs': 'days'},
      ],
      'policy': _policy(),
      'suppressed_count': suppressed,
      'suppressed_label': '$suppressed customers opted out',
      'empty': {
        'title': 'No campaigns yet',
        'note': 'Pick an approved template, choose an audience, schedule it',
      },
    };

/// `key` matters when one test pumps twice: without a distinct key Flutter
/// reuses the existing State, initState never re-runs and the second payload is
/// silently ignored — the test would then pass against stale UI.
Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  String key = 'a',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: WaCampaignsScreen(
        key: ValueKey(key),
        screenRpc: () async => payload,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // No network from the protected suite: RenderLog's debounced Supabase flush
  // is a real Timer and would outlive the widget tree.
  setUpAll(() => RenderLog.flushEnabled = false);

  group('campaign card renders the payload verbatim', () {
    testWidgets('status chip prints the backend label with its tone',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.text('Sending'), findsOneWidget);
      // "Sending" is not derivable from status 'running' by any rule the app
      // holds — it can only have come from status_label.
      expect(find.text('running'), findsNothing);

      final chip = tester.widget<WaToneChip>(
        find.widgetWithText(WaToneChip, 'Sending'),
      );
      expect(chip.tone, 'green');
      expect(waToneColors('green'), waToneColors(chip.tone));
    });

    testWidgets('summary_label and result_label are printed as given',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.text('420 sent · 310 delivered · 180 read · 4 failed'),
          findsOneWidget);
      expect(find.text('44 clicks · 9 orders · ₹47,000.00'), findsOneWidget);
      expect(find.text('Segment: all approved'), findsOneWidget);
      expect(find.text('05 Aug, 10:00 am'), findsOneWidget);
    });

    testWidgets('paused_reason renders when set, and is absent when null',
        (tester) async {
      await _pump(tester, _payload());
      expect(find.text('Paused manually'), findsNothing);

      await _pump(
        tester,
        _payload(campaigns: [
          _campaign(
            status: 'paused',
            statusLabel: 'Paused',
            statusTone: 'yellow',
            pausedReason: 'Paused manually',
            canPause: false,
            canResume: true,
            canSchedule: true,
          )
        ]),
        key: 'b',
      );
      expect(find.text('Paused manually'), findsOneWidget);
    });
  });

  group('actions are gated by their flags, never by status', () {
    testWidgets('a running campaign shows Pause and not Schedule',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Schedule'), findsNothing);
      expect(find.text('Resume'), findsNothing);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Resend failed'), findsNothing);
      // Always available, regardless of flags.
      expect(find.text('View recipients'), findsOneWidget);
    });

    testWidgets('a draft campaign shows Schedule and Edit, not Pause',
        (tester) async {
      await _pump(
        tester,
        _payload(campaigns: [
          _campaign(
            status: 'draft',
            statusLabel: 'Draft',
            statusTone: 'grey',
            canEdit: true,
            canSchedule: true,
            canPause: false,
          )
        ]),
      );

      expect(find.text('Schedule'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Pause'), findsNothing);
    });

    testWidgets('pending_approval shows Approve', (tester) async {
      await _pump(
        tester,
        _payload(campaigns: [
          _campaign(
            status: 'pending_approval',
            statusLabel: 'Needs approval',
            statusTone: 'yellow',
            canApprove: true,
            canPause: false,
          )
        ]),
      );

      expect(find.text('Needs approval'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
    });

    testWidgets('Resend failed appears only on can_resend_failed',
        (tester) async {
      await _pump(
        tester,
        _payload(campaigns: [_campaign(canResendFailed: true)]),
      );
      expect(find.text('Resend failed'), findsOneWidget);
    });

    testWidgets('a flag the backend omitted is treated as false, not as a guess',
        (tester) async {
      final stripped = _campaign()
        ..remove('can_pause')
        ..remove('can_schedule');
      await _pump(tester, _payload(campaigns: [stripped]));

      expect(find.text('Pause'), findsNothing);
      expect(find.text('Schedule'), findsNothing);
      // The card itself still renders — a missing flag is not a crash.
      expect(find.text('August refill push'), findsOneWidget);
    });
  });

  group('policy strip', () {
    testWidgets('prints the payload sentences, not hardcoded values',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.text('Sends 7:00–22:00 IST'), findsOneWidget);
      expect(find.text('One marketing message per customer every 5 days'),
          findsOneWidget);
      expect(find.text('Auto-pauses above 15% failures after 40 attempts'),
          findsOneWidget);
      expect(find.text('Needs approval above 250 recipients'), findsOneWidget);
      expect(find.text('37 customers opted out'), findsOneWidget);

      // The live values must NOT appear: if they do, this strip is printing
      // constants compiled into Dart rather than the payload it was handed.
      expect(find.text('Sends 9:00–20:00 IST'), findsNothing);
    });

    testWidgets('a policy the backend sent no sentences for degrades quietly',
        (tester) async {
      final p = _payload();
      (p['policy'] as Map)
        ..remove('send_window_label')
        ..remove('frequency_cap_label')
        ..remove('auto_pause_label')
        ..remove('approval_label');

      await _pump(tester, p);
      // No invented sentence, and no crash — the campaign still renders.
      expect(find.text('August refill push'), findsOneWidget);
      expect(find.textContaining('Sends '), findsNothing);
    });
  });

  group('unknown values', () {
    testWidgets('an unknown tone renders grey with its label, without throwing',
        (tester) async {
      await _pump(
        tester,
        _payload(campaigns: [
          _campaign(
            status: 'quarantined',
            statusLabel: 'Quarantined by Meta',
            statusTone: 'chartreuse', // a tone this app has never heard of
          )
        ]),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Quarantined by Meta'), findsOneWidget);

      final chip = tester.widget<WaToneChip>(
        find.widgetWithText(WaToneChip, 'Quarantined by Meta'),
      );
      expect(waToneColors(chip.tone), waToneColors('grey'));
      // and specifically NOT one of the known palettes
      expect(waToneColors(chip.tone) == waToneColors('green'), isFalse);
    });

    testWidgets('a null tone also falls back to grey', (tester) async {
      final c = _campaign()..['status_tone'] = null;
      await _pump(tester, _payload(campaigns: [c]));

      expect(tester.takeException(), isNull);
      expect(waToneColors(null), waToneColors('grey'));
    });
  });

  group('empty and error states', () {
    testWidgets('empty{} renders its own title and note', (tester) async {
      await _pump(tester, _payload(campaigns: []));

      expect(find.text('No campaigns yet'), findsOneWidget);
      expect(
        find.text('Pick an approved template, choose an audience, schedule it'),
        findsOneWidget,
      );
    });

    testWidgets('not_authorized shows the backend message with a retry',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WaCampaignsScreen(
            screenRpc: () async => {'error': 'not_authorized'},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('not_authorized'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('recipient log', () {
    testWidgets('renders rows, badges and verbatim skip/error text',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WaCampaignsScreen(
            screenRpc: () async => _payload(),
            detailRpc: (id, limit) async => {
              'ok': true,
              'recipients': [
                {
                  'phone': '919876500001',
                  'status': 'read',
                  'status_label': 'Read',
                  'status_tone': 'green',
                  'skip_reason': null,
                  'error': null,
                  'clicked': true,
                  'ordered': true,
                  'revenue_label': '₹5,220.00',
                  'sent_label': '05 Aug, 10:02 am',
                },
                {
                  'phone': '919876500002',
                  'status': 'failed',
                  'status_label': 'Failed',
                  'status_tone': 'red',
                  'skip_reason': null,
                  'error': '131047: Re-engagement message',
                  'clicked': false,
                  'ordered': false,
                  'revenue_label': null,
                  'sent_label': null,
                },
                {
                  'phone': '919876500003',
                  'status': 'skipped',
                  'status_label': 'Skipped',
                  'status_tone': 'grey',
                  'skip_reason': 'frequency_cap',
                  'error': null,
                  'clicked': false,
                  'ordered': false,
                  'revenue_label': null,
                  'sent_label': null,
                },
              ],
              'campaign': {'id': 'c1'},
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('View recipients'));
      await tester.pumpAndSettle();

      expect(find.text('919876500001'), findsOneWidget);
      expect(find.text('₹5,220.00'), findsOneWidget);
      expect(find.text('05 Aug, 10:02 am'), findsOneWidget);
      // The failure reason is the audit record — printed exactly as stored.
      expect(find.text('131047: Re-engagement message'), findsOneWidget);
      expect(find.text('frequency_cap'), findsOneWidget);

      // Filter chips take their words from the rows' own status_label, so this
      // screen holds no list of statuses.
      expect(find.text('All'), findsWidgets);
      expect(find.widgetWithText(ChoiceChip, 'Failed'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Skipped'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Failed'));
      await tester.pumpAndSettle();

      expect(find.text('919876500002'), findsOneWidget);
      expect(find.text('919876500001'), findsNothing);
      expect(find.text('919876500003'), findsNothing);
    });
  });
}
