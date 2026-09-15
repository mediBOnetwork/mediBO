// PROTECTED — CHANGE #1674.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes build-speed reporting, never to make an unrelated
// change go green.
//
// What this holds down — the Deploy lane card is a PRINTER, and the one thing
// it must never do is invent reassurance about where a build's time went:
//
//   1. The batch WINDOW sentence is deploy_lane_status()'s. A lane deliberately
//      waiting for a second branch reads as a stall unless the card says so —
//      and the fixture's window sentence deliberately disagrees with its own
//      waiting count, so a card that recomposed it from `rows.length` fails.
//
//   2. PER-PHASE timings render in payload order with the backend's own label
//      and tone. "held 891s" never said which half; each phase names its
//      seconds and whether the lane was held. A payload that sent no phases
//      draws none — never a zero row, never a placeholder.
//
//   3. The slowest phase is the backend's pick, not an argmax done in Dart.
//      The fixture's slowest_label names a phase that is NOT the largest
//      `seconds` in the list, because the choice belongs to the backend.
//
//   4. '—' means absent: the batch line prints no detail rather than a dash.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/deploy_lane_section.dart';

Map<String, dynamic> _lane({
  String windowLabel = 'Batch window open — 1 of 3 branch(es), up to 90s.',
  Map<String, dynamic>? batch,
  List? waiting,
}) =>
    {
      'ok': true,
      'title': 'Deploy lane',
      'subtitle': 'Merge queue — runners push a branch and leave.',
      'mode_label': 'MERGE QUEUE',
      'mode_tone': 'success',
      'lane': const {
        'busy': false,
        'label': 'Lane free',
        'detail': 'Nothing merging right now.',
        'held_label': '—',
        'tone': 'success',
      },
      'queue': {
        'count': waiting == null ? 1 : waiting.length,
        'label': '1 branch waiting',
        'empty_hint': 'Runners push a branch here and go straight back.',
        'window_label': windowLabel,
        'rows': waiting ??
            const [
              {
                'entry_id': 737,
                'command_id': 1401,
                'label': '#1401 · claude auth card',
                'detail': 'runner-4 · cmd-1401',
                'value_label': 'waiting 8s',
                'tone': 'info',
              },
            ],
      },
      'batch': batch,
      'metrics': const {
        'heading': 'Wait vs hold, last 7 days',
        'target_label': 'target 180s',
        'tone': 'warning',
        'avg_hold_label': 'avg lane hold 512s',
        'avg_wait_label': 'avg queue wait 249s',
      },
      'recent': const [],
      'stale': const [],
      'config': const {'target_hold_s': 180},
    };

Map<String, dynamic> _batch({List? phases}) => {
      'id': 537,
      'status': 'deploying',
      'label': 'Batch 537 · 3 branch(es)',
      'value_label': 'deploying',
      'tone': 'info',
      'change_no': 1134,
      'evicted': 0,
      // Deliberately NOT the largest `seconds` below: the pick is the
      // backend's, and a card that ran its own argmax would print 'build'.
      'slowest_label': 'replay+upload+verify · 96s',
      'locked_s': 96,
      'phases': phases ??
          const [
            {
              'phase': 'build',
              'seconds': 341,
              'locked': false,
              'label': 'build · 341s',
              'tone': 'info',
            },
            {
              'phase': 'replay+upload+verify',
              'seconds': 96,
              'locked': true,
              'label': 'replay+upload+verify · 96s (lane held)',
              'tone': 'warning',
            },
          ],
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> data) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DeployLaneSection(data: data)),
      ),
    ));

void main() {
  testWidgets('the batch window sentence is the backend\'s, verbatim',
      (tester) async {
    await _pump(tester, _lane());
    expect(
        find.text('Batch window open — 1 of 3 branch(es), up to 90s.'),
        findsOneWidget);
  });

  testWidgets('a payload with no window sentence prints none', (tester) async {
    await _pump(tester, _lane(windowLabel: ''));
    expect(find.textContaining('Batch window'), findsNothing);
    // and never a locally worded stand-in
    expect(find.textContaining('waiting for'), findsNothing);
  });

  testWidgets('per-phase timings render in payload order, verbatim',
      (tester) async {
    await _pump(tester, _lane(batch: _batch()));

    expect(find.text('build · 341s'), findsOneWidget);
    expect(find.text('replay+upload+verify · 96s (lane held)'), findsOneWidget);

    // payload order, not sorted by seconds
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.contains(' · ') && s.endsWith('s') ||
            s.endsWith('(lane held)'))
        .toList();
    final iBuild = labels.indexOf('build · 341s');
    final iLock = labels.indexOf('replay+upload+verify · 96s (lane held)');
    expect(iBuild, isNonNegative);
    expect(iLock, isNonNegative);
    expect(iBuild, lessThan(iLock));
  });

  testWidgets('the slowest phase is the backend\'s pick, not an argmax',
      (tester) async {
    await _pump(tester, _lane(batch: _batch()));
    // 341s > 96s, yet the backend named the locked phase — print what it said.
    expect(find.text('replay+upload+verify · 96s'), findsOneWidget);
  });

  testWidgets('a batch that sent no phases draws none', (tester) async {
    await _pump(tester, _lane(batch: _batch(phases: const [])));
    expect(find.text('Batch 537 · 3 branch(es)'), findsOneWidget);
    expect(find.textContaining('lane held'), findsNothing);
    expect(find.text('0s'), findsNothing);
  });

  testWidgets('a slowest_label of — is absence, not a dash on the card',
      (tester) async {
    final b = _batch(phases: const []);
    b['slowest_label'] = '—';
    await _pump(tester, _lane(batch: b));
    // The lane's own held_label is legitimately '—' (the lane is free). The
    // batch line must not add a SECOND one: absence is an omitted detail.
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('no batch in flight draws no batch line at all', (tester) async {
    await _pump(tester, _lane());
    expect(find.textContaining('Batch 537'), findsNothing);
  });
}
