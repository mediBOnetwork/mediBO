// PROTECTED — CHANGE #755, the self-healing runner breaker's card.
//
// The whole point of #755 is that the DECISION lives in the database:
// runner_health_card() picks the score, the tone, the wording of "what happens
// next" and the trip history, and the card prints them. If any of that ever
// migrates back into Dart, the breaker's behaviour and the breaker's display
// start drifting apart — which is exactly the failure #641 shipped, where the
// only thing Om could see was a red badge that could not tell him whether the
// database had recovered.
//
// So this holds down: nothing is computed, nothing is worded, and an absent
// probe is an explicit `has:false` rather than a zero.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_health.dart';

Map<String, dynamic> _payload({
  bool has = true,
  String tone = 'success',
  String score = '94',
  String next = 'Holding at 3 — database healthy',
  List<Map<String, dynamic>> history = const [],
  bool probeActive = true,
}) =>
    {
      'ok': true,
      'has': has,
      'title': 'Runner health',
      'score': 94,
      'score_display': score,
      'score_label': 'Health score',
      'tone': tone,
      'semaphore': 3,
      'semaphore_display': '3',
      'semaphore_label': 'Parallel builds',
      'streak': 1,
      'streak_label': 'Green streak',
      'streak_display': '1 of 3 green',
      'next_action': next,
      'probe': {
        'active': probeActive,
        'display': probeActive ? 'Probing every 60s' : 'Parked — queue idle, checking every 600s',
        'tone': probeActive ? 'success' : 'neutral',
        'last_display': 'Last probe 12:26',
        'runs': 0,
        'skips': 4,
        'interval_s': probeActive ? 60 : 600,
      },
      'metrics': const [
        {'label': 'Latency p95', 'value': '2.6 ms', 'tone': 'success'},
        {'label': 'DB timeouts · 5 min', 'value': '0', 'tone': 'success'},
      ],
      'history_title': 'Trips & resumes',
      'history_empty': 'No trips recorded',
      'history': history,
    };

Future<void> _pump(WidgetTester t, Map<String, dynamic> p) => t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: RunnerHealthCard(health: p)),
        ),
      ),
    );

void main() {
  testWidgets('score, concurrency, streak and next action are printed verbatim',
      (t) async {
    await _pump(t, _payload());

    // Not "94%", not "Score: 94" — exactly the string the backend sent.
    expect(find.text('94'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('1 of 3 green'), findsOneWidget);
    expect(find.text('Holding at 3 — database healthy'), findsOneWidget);
    expect(find.text('Health score'), findsOneWidget);
    expect(find.text('Parallel builds'), findsOneWidget);
  });

  testWidgets('the next action is never derived — a paused fleet says so in the '
      'backend\'s own words', (t) async {
    await _pump(t, _payload(
        tone: 'danger',
        score: '31',
        next: 'Paused — resuming after 6 green probes (2 so far)'));

    expect(find.text('Paused — resuming after 6 green probes (2 so far)'),
        findsOneWidget);
    expect(find.text('31'), findsOneWidget);
    // The card must not invent a second sentence about the pause.
    expect(find.textContaining('Workflow'), findsNothing);
  });

  testWidgets('a manual OFF renders the backend line, not a local guess',
      (t) async {
    await _pump(t, _payload(
        tone: 'warning',
        next: 'Workflow is off by hand — auto-resume stands down'));
    expect(find.text('Workflow is off by hand — auto-resume stands down'),
        findsOneWidget);
  });

  testWidgets('metrics render in payload order and print their own values',
      (t) async {
    await _pump(t, _payload());
    expect(find.text('Latency p95'), findsOneWidget);
    expect(find.text('2.6 ms'), findsOneWidget);
    expect(find.text('DB timeouts · 5 min'), findsOneWidget);
  });

  testWidgets('an empty history is the backend empty state, never a blank gap',
      (t) async {
    await _pump(t, _payload());
    expect(find.text('No trips recorded'), findsOneWidget);
  });

  testWidgets('trip and resume rows print their own label, time and reason',
      (t) async {
    await _pump(
        t,
        _payload(history: const [
          {
            'at_display': '03 Sep 11:32',
            'kind': 'resume',
            'kind_label': 'Auto-resumed',
            'tone': 'success',
            'score_display': '94',
            'semaphore': 3,
            'reason': 'score 94 for 3 consecutive probe(s) — Workflow back on at 3 parallel',
          },
          {
            'at_display': '03 Sep 04:37',
            'kind': 'trip',
            'kind_label': 'Tripped',
            'tone': 'danger',
            'score_display': '31',
            'semaphore': 0,
            'reason': '10 DB timeouts in 5 min',
          },
        ]));

    expect(find.text('Auto-resumed'), findsOneWidget);
    expect(find.text('03 Sep 11:32'), findsOneWidget);
    expect(find.text('Tripped'), findsOneWidget);
    expect(find.text('10 DB timeouts in 5 min'), findsOneWidget);
    expect(find.text('No trips recorded'), findsNothing);
  });

  testWidgets('the probe cadence is reported, so a parked probe is visible',
      (t) async {
    await _pump(t, _payload(probeActive: false));
    expect(
        find.textContaining('Parked — queue idle, checking every 600s'),
        findsOneWidget);
  });

  testWidgets('no probe yet is has:false — the metrics strip is absent, not zeroed',
      (t) async {
    await _pump(t, _payload(has: false, score: '—'));
    expect(find.text('Latency p95'), findsNothing);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('the collapsed chip shows the score only when there is one',
      (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: RunnerHealthChip(health: _payload()))));
    expect(find.text('94'), findsOneWidget);

    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: RunnerHealthChip(health: _payload(has: false)))));
    expect(find.text('94'), findsNothing);
  });

  testWidgets('an empty payload renders nothing at all', (t) async {
    await _pump(t, const {});
    expect(find.byType(Text), findsNothing);
  });
}
