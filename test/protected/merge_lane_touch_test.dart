// PROTECTED — CHANGE #1822.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the Deploy lane reports its renewals, never to make
// an unrelated change go green.
//
// What this holds down — the Deploy lane card is a PRINTER of
// deploy_lane_status(), and the one thing it must never do is re-derive a hold
// time or a renewal count in Dart. The lane is held by LIVENESS now: a ticker
// renews a 2-minute TTL every touch_every_s while the merge worker deploys, and
// the card is the only place a quietly expiring lane can be READ instead of
// inferred from a wall of failed batches. So:
//
//   1. The renewal sentence prints VERBATIM. The fixture's `held_label` (512s)
//      and its numeric `renewals` (3) deliberately disagree with the sentence
//      ("renewed 14 times, held 470s"), so a card that recomposed the line from
//      the fields it also receives prints the wrong numbers and fails.
//
//   2. The chip is `renewal_chip`, and its colour is `renewal_tone` through the
//      ONE tone lookup — never "expires_in_s < something" decided in Dart. An
//      unknown tone name stays neutral.
//
//   3. Absence is an omitted line: no renewal_label draws no sentence, no chip,
//      and no locally worded stand-in.
//
//   4. The batch's own renewal sentence is the backend's too, and an empty
//      string draws nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/deploy_lane_section.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';

Map<String, dynamic> _lane({
  String? renewalLabel = 'lane renewed 14 times, held 470s · expires in 97s',
  String renewalChip = '14×',
  String renewalTone = 'info',
  Map<String, dynamic>? batch,
}) =>
    {
      'ok': true,
      'title': 'Deploy lane',
      'subtitle': 'Merge queue — runners push a branch and leave.',
      'mode_label': 'MERGE QUEUE',
      'mode_tone': 'success',
      'lane': {
        'busy': true,
        'label': 'Lane held by merge-worker',
        'detail': 'deploy batch 604 · held 512s',
        // Deliberately NOT the number in the sentence below.
        'held_label': '512s',
        'tone': 'info',
        // Deliberately NOT the count in the sentence below.
        'renewals': 3,
        'expires_in_s': 97,
        if (renewalLabel != null) 'renewal_label': renewalLabel,
        'renewal_chip': renewalChip,
        'renewal_tone': renewalTone,
      },
      'queue': const {
        'count': 0,
        'label': 'Queue empty',
        'empty_hint': 'Runners push a branch here and go straight back.',
        'window_label': 'Batch window 300s · nothing waiting.',
        'rows': [],
      },
      'batch': batch,
      'metrics': const {
        'heading': 'Wait vs hold, last 7 days',
        'target_label': 'target hold under 180s',
        'tone': 'success',
        'avg_hold_label': 'avg lane hold 150s',
        'avg_wait_label': 'avg queue wait 40s',
      },
      'recent': const [],
      'stale': const [],
      'config': const {'target_hold_s': 180, 'touch_every_s': 30},
    };

Map<String, dynamic> _batch({String renewalLabel = 'batch renewed the lane 9 times'}) => {
      'id': 604,
      'status': 'deploying',
      'label': 'Batch 604 · 2 branch(es) · resumed from 600',
      'value_label': 'deploying',
      'tone': 'info',
      'change_no': 1196,
      'evicted': 0,
      'slowest_label': '—',
      'locked_s': 0,
      'phases': const [],
      // Deliberately NOT the count in the sentence: the sentence is printed.
      'renewals': 2,
      'renewal_label': renewalLabel,
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> data) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DeployLaneSection(data: data)),
      ),
    ));

ToneChip _chip(WidgetTester tester, String label) =>
    tester.widget<ToneChip>(find.widgetWithText(ToneChip, label));

void main() {
  testWidgets('the renewal sentence is deploy_lane_status()\'s, verbatim',
      (tester) async {
    await _pump(tester, _lane());
    expect(find.text('lane renewed 14 times, held 470s · expires in 97s'),
        findsOneWidget);
    // Nothing recomposed from held_label (512s) or renewals (3).
    expect(find.textContaining('held 512s'), findsOneWidget); // the detail row only
    expect(find.textContaining('renewed 3'), findsNothing);
    expect(find.textContaining('3×'), findsNothing);
    expect(find.textContaining('3 times'), findsNothing);
  });

  testWidgets('the chip is renewal_chip with renewal_tone, one lookup',
      (tester) async {
    await _pump(tester, _lane(renewalChip: 'expiring', renewalTone: 'danger'));
    expect(find.text('expiring'), findsOneWidget);
    expect(_chip(tester, 'expiring').tone, same(toneByName('danger')));
    // 14× must NOT also be drawn: the chip is the backend's word, not a count.
    expect(find.text('14×'), findsNothing);
  });

  testWidgets('an unknown tone name stays neutral', (tester) async {
    await _pump(tester, _lane(renewalChip: '14×', renewalTone: 'plaid'));
    expect(_chip(tester, '14×').tone, same(toneByName('neutral')));
  });

  testWidgets('no renewal_label draws no sentence, no chip, no stand-in',
      (tester) async {
    await _pump(tester, _lane(renewalLabel: null, renewalChip: '14×'));
    expect(find.textContaining('renewed'), findsNothing);
    expect(find.textContaining('expires'), findsNothing);
    expect(find.text('14×'), findsNothing);
    expect(find.textContaining('renewal'), findsNothing);
  });

  testWidgets('an empty renewal_chip draws no chip but keeps the sentence',
      (tester) async {
    await _pump(
        tester,
        _lane(
            renewalLabel: 'no lane renewals recorded yet',
            renewalChip: '',
            renewalTone: 'neutral'));
    expect(find.text('no lane renewals recorded yet'), findsOneWidget);
    expect(find.widgetWithText(ToneChip, ''), findsNothing);
  });

  testWidgets('the batch renewal sentence prints verbatim; empty draws nothing',
      (tester) async {
    await _pump(tester, _lane(batch: _batch()));
    expect(find.text('batch renewed the lane 9 times'), findsOneWidget);
    expect(find.text('Batch 604 · 2 branch(es) · resumed from 600'),
        findsOneWidget);
    expect(find.textContaining('renewed the lane 2'), findsNothing);

    await _pump(tester, _lane(batch: _batch(renewalLabel: '')));
    expect(find.textContaining('renewed the lane'), findsNothing);
  });
}
