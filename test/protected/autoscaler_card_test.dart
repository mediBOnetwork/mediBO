// PROTECTED — CHANGE #1593.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes autoscaler-card behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the runner health card is a PRINTER, and the line that
// matters most is the BRAKE:
//
//   1. `next_action` is printed verbatim. For 48 consecutive probes on 5 Sep
//      this card said "Holding at 4 — database healthy", which was true and
//      useless: the real answer was a fixed band ceiling nobody could see. The
//      backend now writes the brake sentence and the card prints it, so the
//      fixture's next_action deliberately DISAGREES with its own score and
//      semaphore — a card that re-derived either would fail here.
//
//   2. The ladder line (current / learned ceiling / Pool cap) is one backend
//      string. The fixture's ladder_label says numbers its own `current`,
//      `ceiling` and `cap` fields do not, for the same reason.
//
//   3. Absence draws nothing. `autoscale.has:false`, a missing autoscale block
//      and an empty ladder_label each draw no ladder row at all — not a dash,
//      not an empty chip. An older payload (no autoscale key) renders exactly
//      as it did before this change.
//
//   4. The "why" affordance is the parent's. No callback means no icon and no
//      tap target; a tap calls the parent exactly once and talks to no network.
//
//   5. Metrics render in PAYLOAD ORDER with their own tones, including the two
//      this change added — which database was judged, and how much headroom is
//      gone. An unknown tone stays neutral instead of throwing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_health.dart';

/// `autoscale: null` means the key is ABSENT (an older payload); omitting the
/// argument gives the default block.
Map<String, dynamic> _payload({
  bool withAutoscale = true,
  Map<String, dynamic>? autoscale,
  String nextAction =
      'Holding at 4 — the highest concurrency proven clean so far',
  List? metrics,
}) =>
    {
      'ok': true,
      'has': true,
      'title': 'Runner health',
      'tone': 'success',
      'score': 100,
      'score_display': '100',
      'score_label': 'Health score',
      // Deliberately at odds with next_action: the score is perfect and the
      // semaphore is below the cap, and it is still holding. Only the backend
      // knows why.
      'semaphore': 4,
      'semaphore_label': 'Parallel builds',
      'semaphore_display': '4',
      'streak_label': 'Green streak',
      'streak_display': '9 green in a row',
      'next_action': nextAction,
      'probe': {'display': 'Probing every 60s', 'last_display': 'Last probe 20:04'},
      'metrics': metrics ??
          const [
            {'label': 'Latency p95', 'value': '1.1 ms', 'tone': 'success'},
            {'label': 'Judged', 'value': 'build branch', 'tone': 'info'},
            {'label': 'Headroom used', 'value': '54.4%', 'tone': 'moonbeam'},
          ],
      'history_title': 'Trips & resumes',
      'history_empty': 'No trips recorded',
      'history': const [],
      if (withAutoscale)
        'autoscale': autoscale ??
            const {
              'has': true,
              'brake': 'learned_ceiling',
              'label': 'Holding at 4 — the highest concurrency proven clean so far',
              'judged': 'branch',
              'current': 4,
              'ceiling': 5,
              'cap': 6,
              // Says numbers its own fields do not. The card prints the string.
              'ladder_label': '4 of 6 · ceiling 5',
            },
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> p,
        {VoidCallback? onWhy}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RunnerHealthCard(health: p, onWhy: onWhy),
        ),
      ),
    ));

void main() {
  testWidgets('the brake sentence is printed, never re-derived', (tester) async {
    await _pump(tester, _payload());
    expect(
        find.text('Holding at 4 — the highest concurrency proven clean so far'),
        findsOneWidget);
    // Score 100 and semaphore 4 under a cap of 6 would make any client-side
    // guess say "climbing". It must not appear.
    expect(find.textContaining('Climbing'), findsNothing);
  });

  testWidgets('a different brake prints its own words', (tester) async {
    await _pump(
        tester,
        _payload(
            nextAction: 'Holding at 4 — pacing the Claude quota to its reset'));
    expect(find.text('Holding at 4 — pacing the Claude quota to its reset'),
        findsOneWidget);
  });

  testWidgets('the ladder is one backend string', (tester) async {
    await _pump(tester, _payload());
    expect(find.text('4 of 6 · ceiling 5'), findsOneWidget);
  });

  testWidgets('no autoscale block at all draws no ladder', (tester) async {
    await _pump(tester, _payload(withAutoscale: false));
    expect(find.text('4 of 6 · ceiling 5'), findsNothing);
    // The rest of the card is untouched — an older payload still renders.
    expect(find.text('Runner health'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
  });

  testWidgets('has:false draws no ladder', (tester) async {
    await _pump(
        tester,
        _payload(autoscale: const {
          'has': false,
          'ladder_label': '4 of 6 · ceiling 5',
        }));
    expect(find.text('4 of 6 · ceiling 5'), findsNothing);
  });

  testWidgets('an empty ladder_label draws no ladder, not an empty row',
      (tester) async {
    await _pump(tester,
        _payload(autoscale: const {'has': true, 'ladder_label': ''}));
    expect(find.byIcon(Icons.stairs_outlined), findsNothing);
  });

  testWidgets('no callback means no affordance', (tester) async {
    await _pump(tester, _payload());
    expect(find.byIcon(Icons.stairs_outlined), findsOneWidget);
    expect(find.byIcon(Icons.help_outline), findsNothing);
  });

  testWidgets('the why tap calls the parent exactly once', (tester) async {
    var taps = 0;
    await _pump(tester, _payload(), onWhy: () => taps++);
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
    await tester.ensureVisible(find.text('4 of 6 · ceiling 5'));
    await tester.pump();
    await tester.tap(find.text('4 of 6 · ceiling 5'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('metrics render in payload order, verbatim', (tester) async {
    await _pump(tester, _payload());
    expect(find.text('build branch'), findsOneWidget);
    expect(find.text('54.4%'), findsOneWidget);
    final lat = tester.getTopLeft(find.text('Latency p95'));
    final judged = tester.getTopLeft(find.text('Judged'));
    final head = tester.getTopLeft(find.text('Headroom used'));
    for (final pair in [[lat, judged], [judged, head]]) {
      final a = pair[0], b = pair[1];
      expect(b.dy > a.dy || (b.dy == a.dy && b.dx > a.dx), isTrue);
    }
  });

  testWidgets('an unknown metric tone stays neutral instead of throwing',
      (tester) async {
    await _pump(tester, _payload());
    expect(tester.takeException(), isNull);
  });

  testWidgets('production is said in the backend\'s words too', (tester) async {
    await _pump(
        tester,
        _payload(metrics: const [
          {'label': 'Judged', 'value': 'production', 'tone': 'neutral'},
        ]));
    expect(find.text('production'), findsOneWidget);
    expect(find.text('build branch'), findsNothing);
  });
}
