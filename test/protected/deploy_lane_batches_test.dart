// PROTECTED — CHANGE #1836.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes deploy-lane reporting, never to make an unrelated change
// go green.
//
// What this holds down — the Deploy lane's batch history is a PRINTER, and it is
// the only place Om can see that nothing is reaching production:
//
//   1. On 6 Sep, batches 615-621 all read 'failed' and nothing shipped for an
//      hour. Five of the seven were not failures at all — a worker SIGKILLed by
//      systemd's 90 s stop-timeout, two swept behind it, a boot-gate flake, and
//      a smoke that never started because another test session was open. The
//      card could only ever show the batch that was OPEN, so the hour was
//      legible in merge_worker.journal and nowhere else. This block exists so
//      that can never be true again.
//
//   2. EXPIRED IS NOT FAILED, AND DART DOES NOT DECIDE WHICH. The value word
//      ("worker died — retried") and the tone come from the payload. The fixture
//      deliberately pairs status 'expired' with tone 'warning' and status
//      'failed' with tone 'error' while ALSO giving one deployed batch a note
//      that contains the word "exit 1" — a card that coloured a row by grepping
//      its own note, or by mapping `status` in Dart, fails here.
//
//   3. The note is the REAL ERROR LINE. It used to be "deploy.sh exit 1" for
//      both a missing cache-purge token (site live) and a refused boot gate
//      (nothing uploaded). The card prints `sub_label` verbatim and never
//      abbreviates, re-words or pluralises it.
//
//   4. The streak sentence and its tone are the backend's. The fixture's
//      streak_label says "3 batches failed in a row" while only TWO rows in the
//      list carry status 'failed' — because the streak is computed over closed
//      batches in SQL (_deploy_batch_fail_streak), not over whatever rows this
//      page happens to be showing.
//
//   5. Absence draws nothing. has:false renders no heading, no empty state and
//      no zero; an absent sub_label or when_label omits its line rather than
//      printing a dash.
//
//   6. Rows render in PAYLOAD ORDER. The fixture is deliberately not sorted by
//      batch id, status or time, so any client-side sort fails here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/deploy_lane_section.dart';

Map<String, dynamic> _batches({bool has = true, List? rows}) => {
  'has': has,
  'heading': 'Recent batches',
  'empty_label': 'No batch has run yet.',
  'streak': 3,
  // Deliberately disagrees with the rows below: the streak is SQL's, over
  // closed batches, not a count of what is on screen.
  'streak_label': '3 batches failed in a row — nothing is reaching production.',
  'streak_tone': 'danger',
  'footnote':
      'An expired batch is a worker that died, not a branch that '
      'failed — its branches keep their attempt count and go back in the queue.',
  'rows':
      rows ??
      const [
        {
          'batch_id': 619,
          'label': 'Batch 619 · CHANGE #1204 · 1 branch(es)',
          'status': 'failed',
          'value_label': 'failed',
          'tone': 'error',
          'sub_label':
              'deploy: BOOT GATE FAILED twice — bundle would hang '
              'on load, NOT deploying',
          'when_label': '06 Sep 16:57 IST',
        },
        {
          // out of id order on purpose
          'batch_id': 617,
          'label': 'Batch 617 · CHANGE #1205 · 3 branch(es)',
          'status': 'expired',
          'value_label': 'worker died — retried',
          'tone': 'warning',
          'sub_label':
              'worker died mid-batch — no heartbeat for 20m; '
              'entries requeued for retry, not failed',
          'when_label': '06 Sep 17:01 IST',
        },
        {
          // A DEPLOYED batch whose note contains "exit 1". A card that read
          // the note to pick a colour would paint this one red.
          'batch_id': 614,
          'label': 'Batch 614 · CHANGE #1202 · 1 branch(es)',
          'status': 'deployed',
          'value_label': 'deployed',
          'tone': 'success',
          'sub_label':
              'batched 1 branch(es); live with warnings — '
              'CACHE PURGE SKIPPED (deploy.sh exit 1 before #1836)',
          'when_label': '06 Sep 16:11 IST',
        },
        {
          'batch_id': 620,
          'label': 'Batch 620 · CHANGE #1205 · 3 branch(es)',
          'status': 'failed',
          'value_label': 'failed',
          'tone': 'error',
          // absent sub_label / when_label — must omit, never dash
          'sub_label': null,
          'when_label': '',
        },
      ],
};

Map<String, dynamic> _payload({Map<String, dynamic>? batches}) => {
  'ok': true,
  'title': 'Deploy lane',
  'subtitle': 'Merge queue — one worker batches, tests once, deploys once.',
  'mode_label': 'MERGE QUEUE',
  'mode_tone': 'success',
  'lane': const {
    'busy': false,
    'label': 'Lane free',
    'detail': 'Nothing merging right now.',
    'held_label': '—',
    'tone': 'success',
    'renewal_label': '',
    'renewal_chip': '',
    'renewal_tone': 'neutral',
  },
  'queue': const {
    'count': 0,
    'label': 'Queue empty',
    'empty_hint':
        'Runners push a branch here and go straight back to building.',
    'window_label': 'Batch window off — every branch deploys alone.',
    'rows': [],
  },
  'metrics': const {
    'heading': 'Wait vs hold, last 7 days',
    'avg_hold_label': 'avg lane hold 565s',
    'avg_wait_label': 'avg queue wait 41s',
    'target_label': 'target hold under 60s',
    'tone': 'warning',
  },
  'recent_heading': 'Recent deploys',
  'recent': const [],
  'stale_heading': 'Stale claims',
  'stale_empty': 'No claim is holding a queue slot past its TTL.',
  'stale': const [],
  'smoke': const {'has': false},
  'batches': batches ?? _batches(),
};

Future<void> _pump(WidgetTester t, Map<String, dynamic> data) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DeployLaneSection(data: data)),
      ),
    ),
  );
  await t.pump();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  testWidgets('an expired batch says a worker died, in the backend\'s words', (
    t,
  ) async {
    await _pump(t, _payload());
    expect(find.text('Recent batches'), findsOneWidget);
    expect(find.text('worker died — retried'), findsOneWidget);
    expect(
      find.text(
        'worker died mid-batch — no heartbeat for 20m; '
        'entries requeued for retry, not failed',
      ),
      findsOneWidget,
    );
    // and it is NOT rendered as a failure
    expect(find.text('expired'), findsNothing);
  });

  testWidgets('the note is the real error line, printed verbatim', (t) async {
    await _pump(t, _payload());
    expect(
      find.text(
        'deploy: BOOT GATE FAILED twice — bundle would hang '
        'on load, NOT deploying',
      ),
      findsOneWidget,
    );
    // the chronic exit 1 reads as a LIVE deploy, because the payload says so
    expect(
      find.text(
        'batched 1 branch(es); live with warnings — '
        'CACHE PURGE SKIPPED (deploy.sh exit 1 before #1836)',
      ),
      findsOneWidget,
    );
  });

  testWidgets('tone is carried, never derived from status or from the note', (
    t,
  ) async {
    await _pump(t, _payload());
    final chips = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .toList();
    // the deployed batch whose note contains "exit 1" is still the success row
    expect(chips.contains('deployed'), isTrue);
    // an unknown tone name must not throw and must not be guessed
    final odd = _batches(
      rows: const [
        {
          'batch_id': 900,
          'label': 'Batch 900 · 1 branch(es)',
          'status': 'quarantined',
          'value_label': 'held for review',
          'tone': 'ultraviolet',
          'sub_label': 'a status this build has never heard of',
          'when_label': '06 Sep 18:00 IST',
        },
      ],
    );
    await _pump(t, _payload(batches: odd));
    expect(find.text('held for review'), findsOneWidget);
    expect(find.text('a status this build has never heard of'), findsOneWidget);
  });

  testWidgets(
    'the streak sentence is the backend\'s, not a count of the rows',
    (t) async {
      await _pump(t, _payload());
      expect(
        find.text(
          '3 batches failed in a row — nothing is reaching production.',
        ),
        findsOneWidget,
      );
      // two rows carry status failed; the card must not "correct" the sentence
      expect(find.textContaining('2 batches failed'), findsNothing);
    },
  );

  testWidgets('rows render in payload order', (t) async {
    await _pump(t, _payload());
    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => s.startsWith('Batch ') && s.contains('branch(es)'))
        .toList();
    expect(labels, [
      'Batch 619 · CHANGE #1204 · 1 branch(es)',
      'Batch 617 · CHANGE #1205 · 3 branch(es)',
      'Batch 614 · CHANGE #1202 · 1 branch(es)',
      'Batch 620 · CHANGE #1205 · 3 branch(es)',
    ]);
  });

  testWidgets('an absent sub-line or time is omitted, never dashed', (t) async {
    await _pump(t, _payload());
    expect(find.text('—'), findsOneWidget); // the lane's own held_label, only
    expect(find.text('null'), findsNothing);
  });

  testWidgets('has:false draws nothing at all', (t) async {
    await _pump(t, _payload(batches: _batches(has: false)));
    expect(find.text('Recent batches'), findsNothing);
    expect(find.text('No batch has run yet.'), findsNothing);
    expect(find.text('worker died — retried'), findsNothing);
    // the rest of the card still renders
    expect(find.text('Deploy lane'), findsOneWidget);
  });

  testWidgets('an empty batch list shows the backend\'s empty state', (
    t,
  ) async {
    await _pump(t, _payload(batches: _batches(rows: const [])));
    expect(find.text('Recent batches'), findsOneWidget);
    expect(find.text('No batch has run yet.'), findsOneWidget);
  });
}
