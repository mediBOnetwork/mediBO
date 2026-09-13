// PROTECTED — CMD #1961 (replaces deploy_lane_batches_test.dart, CHANGE #1836).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes deploy-lane reporting, never to make an unrelated change
// go green.
//
// WHY THE BATCH BLOCK IS GONE. #1836's block printed deploy_batch, and it did
// print it honestly. Then #1859 turned the merge lane off: every command now
// deploys its own branch through deploy_direct, deploy_batch stopped growing on
// 7 Sep, and the card went on reporting a six-day-old "Last batch failed" as
// the live state of a lane that had shipped all week. A truthful printer of a
// dead table is still a lie on screen.
//
// What this holds down in its place — the Deploy lane card is a PRINTER:
//
//   1. RECENTLY COMPLETED IS THE PAYLOAD'S. #id · title, the CHANGE #n ·
//      duration · tokens line, the timestamp and the chip word are all
//      deploy_recent_completed()'s. The fixture gives one row a duration that
//      disagrees with its timestamps and another the chip 'no web deploy'
//      against a 3.8M-token build: a card that recomputed either fails here.
//   2. ROWS RENDER IN PAYLOAD ORDER. The fixture is deliberately not sorted by
//      id, by time or by change number.
//   3. TAP CARRIES THE BACKEND'S ID, never one parsed back out of the label —
//      the label says "#1959" while command_id is 1959 for one row and
//      deliberately differs on the last.
//   4. ABSENCE DRAWS NOTHING. has:false draws no heading and no empty state; an
//      absent sub-line or timestamp omits its line rather than printing a dash.
//   5. THE LOCK CHIP IS ONE BACKEND STRING. "#1962 · runner-2 · 9m 25s · frees
//      in ~15m 35s" when held, "Lock free" when not: no elapsed time and no
//      countdown is ever computed in Dart.
//   6. THE OLD BLOCK CANNOT COME BACK. A payload still carrying `batches`
//      renders none of it.
//   7. CMD #1973 — DIRECT DEPLOYS PRINT WHERE THE TIME WENT. Prep runs with the
//      deploy lock FREE and only migrate/upload/verify hold it, so the card
//      keeps the two apart: the hold chip, its tone, the prep chip and the
//      'base moved' chip are all deploy_direct_recent()'s words. The fixture
//      gives one row a hold of '3m 51s' toned success and another '19m 4s'
//      toned danger; a card that re-derived either from started_at, or that
//      coloured them by a Dart threshold, fails here. An older backend still
//      sending the #1859 shape (a bare array on `direct`) draws nothing rather
//      than throwing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/deploy_lane_section.dart';

Map<String, dynamic> _completed({bool has = true, List? rows}) => {
  'has': has,
  'heading': 'Recently completed',
  'empty_label': 'No command has completed yet.',
  'footnote':
      'Each command deploys its own branch under the deploy lock — '
      'tap a row to open it.',
  'rows':
      rows ??
      const [
        {
          'command_id': 1959,
          'label': '#1959 · fix RG red after #1320 (1 critical signal)',
          // no web deploy, and the chip says so in the backend's words
          'sub_label': '14m 23s · 254.5K tokens',
          'value_label': 'no web deploy',
          'tone': 'neutral',
          'when_label': '13 Sep 14:25 IST',
        },
        {
          // out of id order on purpose
          'command_id': 1950,
          'label': '#1950 · mobile-first build rule — build_rules',
          'sub_label': 'CHANGE #1323 · 45m 20s · 657.2K tokens',
          'value_label': 'CHANGE #1323',
          'tone': 'success',
          'when_label': '13 Sep 14:10 IST',
        },
        {
          'command_id': 1948,
          'label': '#1948 · Harness: claim never blocks on /compact',
          // a very large build that still has no web deploy — the chip word is
          // the backend's and is never derived from the token figure
          'sub_label': '1h 5m · 3.8M tokens',
          'value_label': 'no web deploy',
          'tone': 'neutral',
          'when_label': '13 Sep 00:45 IST',
        },
        {
          // deliberately missing sub-line and time: omit, never dash
          'command_id': 1941,
          'label': '#1949 · a label whose number is NOT the id',
          'sub_label': null,
          'value_label': 'CHANGE #1319',
          'tone': 'success',
          'when_label': '',
        },
      ],
};

Map<String, dynamic> _direct({bool has = true, List? rows}) => {
  'has': has,
  'heading': 'Direct deploys',
  'subtitle':
      '2 deploy(s) in 7 days · lock held 4m 12s on average · '
      '11m 30s of prep ran with the lane free.',
  'target_label': 'target: lock under 5 min',
  'empty': 'No direct deploy has run yet.',
  'footnote':
      'CMD #1973 — prep off the lock. Before it, one ship held the lane '
      '21 min: 6 min of tests and 9 min of build were inside it.',
  'rows':
      rows ??
      const [
        {
          'id': 160,
          'command_id': 1973,
          'label': 'CHANGE #1333 · #1973',
          'status': 'deployed',
          'tone': 'success',
          'line':
              'CHANGE #1333 is live (commit 9ab31c0e, 14m 2s) — complete with '
              'p_deploy_no 1333. Lock held 3m 51s of that; 9m 12s of prep ran '
              'with the lane free.',
          'prep_label': 'prep 9m 12s · lock free',
          'hold_label': 'lock 3m 51s',
          'hold_tone': 'success',
          'rebuilt_label': '',
          'duration_label': '14m 2s',
        },
        {
          // out of id order on purpose, and the slow one is toned by the
          // backend, not by a Dart threshold
          'id': 158,
          'command_id': 1852,
          'label': 'CHANGE #1332 · #1852',
          'status': 'deployed',
          'tone': 'success',
          'line':
              'CHANGE #1332 is live (commit 0fd410ff, 24m 8s) — complete with '
              'p_deploy_no 1332.',
          'prep_label': '',
          'hold_label': 'lock 19m 4s',
          'hold_tone': 'danger',
          'rebuilt_label': 'the live base moved — retested under the lock',
          'duration_label': '24m 8s',
        },
      ],
};

Map<String, dynamic> _payload({
  Map<String, dynamic>? completed,
  Map<String, dynamic>? lane,
  Object? direct,
  bool withDeadBatches = false,
}) => {
  'ok': true,
  'title': 'Deploy lane',
  'subtitle':
      'Direct deploys — each command holds the deploy lock, tests, '
      'builds and deploys its own branch.',
  'mode_label': 'DIRECT (deploy_lock)',
  'mode_tone': 'info',
  'lane':
      lane ??
      const {
        'busy': true,
        'label': 'Lane held by runner-2',
        'detail': 'CMD #1962 · held 565s',
        'held_label': '565s',
        'tone': 'error',
        'lock_label': 'deploy lock — #1962',
        'lock_tone': 'warning',
        'holder_chip': '#1962 · runner-2 · 9m 25s · frees in ~15m 35s',
        'holder_chip_tone': 'warning',
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
  'completed': completed ?? _completed(),
  'direct': direct ?? _direct(),
  // A payload from an older backend still carrying the dead block.
  if (withDeadBatches)
    'batches': const {
      'has': true,
      'heading': 'Recent batches',
      'empty_label': 'No batch has run yet.',
      'streak_label': 'Last batch failed — one in a row.',
      'streak_tone': 'warning',
      'rows': [
        {
          'batch_id': 621,
          'label': 'Batch 621 · 1 branch(es)',
          'status': 'failed',
          'value_label': 'failed',
          'tone': 'error',
          'sub_label': 'deploy.sh exit 1',
          'when_label': '07 Sep 11:40 IST',
        },
      ],
    },
};

Future<void> _pump(
  WidgetTester t,
  Map<String, dynamic> data, {
  void Function(int)? onOpen,
}) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DeployLaneSection(data: data, onOpenCommand: onOpen),
        ),
      ),
    ),
  );
  await t.pump();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  testWidgets('the card prints Recently completed, verbatim', (t) async {
    await _pump(t, _payload());
    expect(find.text('Recently completed'), findsOneWidget);
    expect(
      find.text('#1950 · mobile-first build rule — build_rules'),
      findsOneWidget,
    );
    expect(
      find.text('CHANGE #1323 · 45m 20s · 657.2K tokens'),
      findsOneWidget,
    );
    expect(find.text('13 Sep 14:10 IST'), findsOneWidget);
    // the chip word is the backend's, on a 3.8M-token build with no deploy
    expect(find.text('no web deploy'), findsNWidgets(2));
    expect(
      find.text(
        'Each command deploys its own branch under the deploy lock — '
        'tap a row to open it.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('rows render in payload order', (t) async {
    await _pump(t, _payload());
    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        // the lock chip also starts with '#19' — it is not a row label
        .where((s) =>
            s.startsWith('#19') && s.contains(' · ') && !s.contains('frees in'))
        .toList();
    expect(labels, [
      '#1959 · fix RG red after #1320 (1 critical signal)',
      '#1950 · mobile-first build rule — build_rules',
      '#1948 · Harness: claim never blocks on /compact',
      '#1949 · a label whose number is NOT the id',
    ]);
  });

  testWidgets('a tap carries the backend id, never the one in the label', (
    t,
  ) async {
    final opened = <int>[];
    await _pump(t, _payload(), onOpen: opened.add);
    // CMD #1973 added the Direct deploys block above this one, so the row can
    // start below the 600px test viewport. Scroll it into view first — the
    // assertion (the id comes from the payload, never from the label) is
    // unchanged.
    final row = find.text('#1949 · a label whose number is NOT the id');
    await t.ensureVisible(row);
    await t.pumpAndSettle();
    await t.tap(row);
    await t.pump();
    expect(opened, [1941]);
  });

  testWidgets('the lock chip is one backend string, held and free', (t) async {
    await _pump(t, _payload());
    expect(
      find.text('#1962 · runner-2 · 9m 25s · frees in ~15m 35s'),
      findsOneWidget,
    );
    expect(find.text('deploy lock — #1962'), findsOneWidget);

    await _pump(
      t,
      _payload(
        lane: const {
          'busy': false,
          'label': 'Lane free',
          'detail': 'Nothing deploying right now.',
          'held_label': '—',
          'tone': 'success',
          'lock_label': 'deploy lock — free',
          'lock_tone': 'success',
          'holder_chip': 'Lock free',
          'holder_chip_tone': 'success',
          'renewal_label': '',
          'renewal_chip': '',
          'renewal_tone': 'neutral',
        },
      ),
    );
    expect(find.text('Lock free'), findsOneWidget);
    // nothing about elapsed time is invented once the lock is free
    expect(find.textContaining('frees in'), findsNothing);
  });

  testWidgets('an absent sub-line or time is omitted, never dashed', (t) async {
    await _pump(t, _payload());
    expect(find.text('null'), findsNothing);
    // the only dash on the card is the lane's own held_label
    expect(find.text('—'), findsNothing);
  });

  testWidgets('has:false draws nothing at all', (t) async {
    await _pump(t, _payload(completed: _completed(has: false)));
    expect(find.text('Recently completed'), findsNothing);
    expect(find.text('No command has completed yet.'), findsNothing);
    expect(find.text('#1950 · mobile-first build rule — build_rules'),
        findsNothing);
    // the rest of the card still renders
    expect(find.text('Deploy lane'), findsOneWidget);
  });

  testWidgets('an empty list shows the backend\'s empty state', (t) async {
    await _pump(t, _payload(completed: _completed(rows: const [])));
    expect(find.text('Recently completed'), findsOneWidget);
    expect(find.text('No command has completed yet.'), findsOneWidget);
  });

  testWidgets('direct deploys print prep and hold as the backend worded them', (
    t,
  ) async {
    await _pump(t, _payload());
    expect(find.text('Direct deploys'), findsOneWidget);
    expect(find.text('target: lock under 5 min'), findsOneWidget);
    expect(
      find.text(
        '2 deploy(s) in 7 days · lock held 4m 12s on average · '
        '11m 30s of prep ran with the lane free.',
      ),
      findsOneWidget,
    );
    expect(find.text('CHANGE #1333 · #1973'), findsOneWidget);
    expect(
      find.text(
        'CHANGE #1333 is live (commit 9ab31c0e, 14m 2s) — complete with '
        'p_deploy_no 1333. Lock held 3m 51s of that; 9m 12s of prep ran '
        'with the lane free.',
      ),
      findsOneWidget,
    );
    // the two numbers, kept apart, verbatim
    expect(find.text('lock 3m 51s'), findsOneWidget);
    expect(find.text('prep 9m 12s · lock free'), findsOneWidget);
    expect(find.text('lock 19m 4s'), findsOneWidget);
    expect(
      find.text('the live base moved — retested under the lock'),
      findsOneWidget,
    );
    expect(
      find.text(
        'CMD #1973 — prep off the lock. Before it, one ship held the lane '
        '21 min: 6 min of tests and 9 min of build were inside it.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an absent prep or rebuilt chip is omitted, never dashed', (
    t,
  ) async {
    await _pump(t, _payload());
    // the second row has no prep_label: nothing stands in for it
    expect(find.text('—'), findsNothing);
    expect(find.text('prep'), findsNothing);
  });

  testWidgets('a direct row taps through on the backend id', (t) async {
    final opened = <int>[];
    await _pump(t, _payload(), onOpen: opened.add);
    await t.tap(find.text('CHANGE #1333 · #1973'));
    await t.pump();
    expect(opened, [1973]);
  });

  testWidgets('direct has:false draws no heading and no empty state', (
    t,
  ) async {
    await _pump(t, _payload(direct: _direct(has: false)));
    expect(find.text('Direct deploys'), findsNothing);
    expect(find.text('No direct deploy has run yet.'), findsNothing);
  });

  testWidgets('an empty direct list shows the backend\'s empty state', (
    t,
  ) async {
    await _pump(t, _payload(direct: _direct(rows: const [])));
    expect(find.text('No direct deploy has run yet.'), findsOneWidget);
    expect(find.text('lock 3m 51s'), findsNothing);
  });

  testWidgets('the #1859 array shape on direct draws nothing, never throws', (
    t,
  ) async {
    await _pump(
      t,
      _payload(
        direct: const [
          {'id': 1, 'label': 'CHANGE #1', 'line': 'legacy row'},
        ],
      ),
    );
    expect(find.text('Direct deploys'), findsNothing);
    expect(find.text('legacy row'), findsNothing);
    // and the rest of the card still drew, i.e. nothing threw on the way past
    expect(find.text('Recently completed'), findsOneWidget);
  });

  testWidgets('a payload still carrying batches renders none of it', (t) async {
    await _pump(t, _payload(withDeadBatches: true));
    expect(find.text('Recent batches'), findsNothing);
    expect(find.text('Batch 621 · 1 branch(es)'), findsNothing);
    expect(find.text('Last batch failed — one in a row.'), findsNothing);
    expect(find.text('Recently completed'), findsOneWidget);
  });
}
