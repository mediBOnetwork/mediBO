// PROTECTED — CHANGE #1570.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the runner strip's behaviour, never to make an
// unrelated change go green.
//
// What this holds down — the runner strip is a PRINTER, and it is ONE CARD:
//
//   1. The build-branch line is the backend's account of itself. The fixture's
//      `builds` (7) deliberately disagrees with its own `builds_label`
//      ("1 build on the branch"), so a card that pluralised, counted or
//      re-derived the sentence fails here. That sentence is the only thing on
//      the screen that can tell "a branch is up" apart from "a branch is up
//      and is actually being used" — the exact gap that let #1470 report a
//      healthy 26-minute-old branch while every build ran on production.
//
//   2. Gauges and workers render in PAYLOAD ORDER, with the payload's own
//      label, value, sub-line and tone. The gauge fixture is deliberately not
//      sorted by label or by value; an absent sub-line is omitted rather than
//      dashed; an unknown tone stays neutral instead of being guessed at.
//
//   3. A worker's buttons are `actions[]` and nothing else. A build that has
//      never heard of an action still renders its label and still sends its
//      key; a worker with no actions gets no buttons at all; and a tap calls
//      the parent exactly once, with the agent and the action key, and talks
//      to no network.
//
//   4. The three toggle chips are payload strings. 'running' / 'not running'
//      were Dart literals on the one card whose entire purpose is to print the
//      backend's account of itself; a toggle that sends neither word shows no
//      chip rather than inventing one.
//
//   5. ONE CARD. #1367 stacked v3 above v2 and Dev Queue showed two runner
//      cards; v2 is v3's footer now. So `has:false` — the strip having nothing
//      to say — must NOT take the footer down with it, and the footer is drawn
//      exactly once when the strip does have something to say.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/strip_v3/strip_v3_view.dart';

Map<String, dynamic> _payload({
  bool has = true,
  Map<String, dynamic>? branch,
  List? gauges,
  List? workers,
  List? toggles,
}) =>
    {
      'has': has,
      'title': 'Runners',
      'headline': 'Blocked: 1 build(s) running on production while the branch is on',
      'tone': 'warning',
      'blocked': const ['1 build(s) running on production while the branch is on'],
      'building_label': 'Building #1368, #1570',
      'branch_label': 'Build branch on · 50m',
      'workers_title': 'Workers',
      'drain_label': '',
      'branch': branch ??
          const {
            'has': true,
            'ref': 'pavaxgskqxnoyutwumvh',
            // 7 builds, and a sentence that says 1. The card prints the
            // sentence.
            'builds': 7,
            'builds_label': '1 build on the branch',
            'builds_tone': 'success',
            'label': 'Build branch on · 50m',
            'refusal_label': '2 build(s) refused on production',
            'tone': 'success',
          },
      'gauges': gauges ??
          const [
            // Deliberately unsorted, and the last one carries no sub-line.
            {'key': 'disk', 'label': 'Disk', 'value': '45%', 'sub': '25.6 GB / 57.1 GB (45%)', 'tone': 'success'},
            {'key': 'ram', 'label': 'Memory', 'value': '10%', 'sub': 'CPU 20% · load 1.64', 'tone': 'success'},
            {'key': 'quota', 'label': 'Claude quota', 'value': '15%', 'sub': 'just now', 'tone': 'warning'},
            {'key': 'boot', 'label': 'Last boot', 'value': 'Green', 'sub': '56m ago', 'tone': 'moonbeam'},
            {'key': 'forecast', 'label': 'Queue', 'value': '21 waiting', 'sub': '', 'tone': 'neutral'},
          ],
      'workers': workers ??
          const [
            {
              'agent': 'runner-3',
              'label': 'runner-3',
              'status': 'building',
              'title': 'Runner ops policies',
              'sub': 'claude-opus-5 · high · #1368',
              'tone': 'info',
              'busy': false,
              'actions': [
                {'key': 'restart', 'label': 'Restart', 'tone': 'neutral', 'confirm': 'Restart this worker?'},
                {'key': 'kill', 'label': 'Stop', 'tone': 'danger', 'confirm': 'Stop this worker?'},
              ],
            },
            {
              'agent': 'runner-1',
              'label': 'runner-1',
              'status': 'building',
              'title': 'Verify builds run on the branch',
              'sub': 'claude-opus-5 · high · #1570',
              'tone': 'info',
              'busy': false,
              'actions': [
                // A key this build has never heard of. It still prints, and it
                // still sends its own key.
                {'key': 'quarantine', 'label': 'Quarantine', 'tone': 'warning', 'confirm': ''},
              ],
            },
          ],
      'toggles': toggles ??
          const [
            {
              'key': 'vm',
              'label': 'VM',
              'desired': true,
              'actual': false,
              'actual_label': 'running',
              'not_actual_label': 'not running',
              'sub': '',
            },
            {
              // desired == actual: no chip either way.
              'key': 'claude',
              'label': 'Start building',
              'desired': true,
              'actual': true,
              'actual_label': 'running',
              'not_actual_label': 'not running',
              'sub': 'One runner, one command at a time.',
            },
            {
              // A mismatch with NO words for it. Silence, not an invention.
              'key': 'workflow',
              'label': 'Parallel building',
              'desired': true,
              'actual': false,
              'sub': '',
            },
          ],
    };

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  Widget? footer,
  void Function(String agent, String action)? onWorkerAction,
}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StripV3View(
            data: payload,
            footer: footer,
            onWorkerAction: onWorkerAction,
          ),
        ),
      ),
    ));

void main() {
  // The card calls RenderLog.write; its 800 ms debounce is a real Timer that
  // would outlive the test and try to reach Supabase.
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('the build-branch sentence is printed, never recomputed',
      (tester) async {
    await _pump(tester, _payload());
    // The payload says 7 builds and says "1 build on the branch". The card
    // prints what it was told; the number 7 never reaches the screen.
    expect(find.text('1 build on the branch'), findsOneWidget);
    // The number the payload actually carries never reaches the screen.
    expect(find.text('7 builds on the branch'), findsNothing);
    expect(find.text('7'), findsNothing);
    expect(find.text('Build branch on · 50m'), findsOneWidget);
    expect(find.text('2 build(s) refused on production'), findsOneWidget);
  });

  testWidgets('a branch with no label draws no branch line', (tester) async {
    await _pump(tester,
        _payload(branch: const {'has': false, 'label': '', 'builds_label': ''}));
    expect(find.textContaining('build on the branch'), findsNothing);
    expect(find.textContaining('refused on production'), findsNothing);
    // The strip itself is still there.
    expect(find.text('Runners'), findsOneWidget);
  });

  testWidgets('gauges render in payload order, verbatim', (tester) async {
    await _pump(tester, _payload());
    for (final label in ['Disk', 'Memory', 'Claude quota', 'Last boot', 'Queue']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('25.6 GB / 57.1 GB (45%)'), findsOneWidget);
    expect(find.text('Green'), findsOneWidget);

    // Payload order, in READING order — the row wraps, so a later gauge is
    // either further right on the same line or on a line below. No client-side
    // sort by label, value or tone survives this.
    final at = <Offset>[];
    for (final label in ['Disk', 'Memory', 'Claude quota', 'Last boot', 'Queue']) {
      at.add(tester.getTopLeft(find.text(label)));
    }
    for (var i = 1; i < at.length; i++) {
      final after = at[i].dy > at[i - 1].dy ||
          (at[i].dy == at[i - 1].dy && at[i].dx > at[i - 1].dx);
      expect(after, isTrue, reason: 'gauge $i moved');
    }
  });

  testWidgets('an absent gauge sub-line is omitted, not dashed', (tester) async {
    await _pump(tester, _payload());
    expect(find.text('21 waiting'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(find.text('-'), findsNothing);
  });

  testWidgets('an unknown gauge tone stays neutral instead of throwing',
      (tester) async {
    // 'moonbeam' is not a tone this build knows. It must render.
    await _pump(tester, _payload());
    expect(find.text('Last boot'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('workers render in payload order with the backend status chip',
      (tester) async {
    await _pump(tester, _payload());
    expect(find.text('Workers'), findsOneWidget);
    expect(find.text('runner-3'), findsOneWidget);
    expect(find.text('runner-1'), findsOneWidget);
    // runner-3 is FIRST in the payload even though runner-1 sorts before it.
    expect(tester.getTopLeft(find.text('runner-3')).dy <
            tester.getTopLeft(find.text('runner-1')).dy,
        isTrue);
    expect(find.text('building'), findsNWidgets(2));
  });

  testWidgets('a worker button this build has never heard of still works',
      (tester) async {
    final taps = <String>[];
    await _pump(tester, _payload(),
        onWorkerAction: (a, k) => taps.add('$a/$k'));
    expect(find.text('Quarantine'), findsOneWidget);
    await tester.ensureVisible(find.text('Quarantine'));
    await tester.pump();
    await tester.tap(find.text('Quarantine'));
    await tester.pump();
    expect(taps, ['runner-1/quarantine']);
  });

  testWidgets('Stop and Restart send their own keys, once each', (tester) async {
    final taps = <String>[];
    await _pump(tester, _payload(),
        onWorkerAction: (a, k) => taps.add('$a/$k'));
    await tester.ensureVisible(find.text('Restart'));
    await tester.pump();
    await tester.tap(find.text('Restart'));
    await tester.pump();
    await tester.ensureVisible(find.text('Stop'));
    await tester.pump();
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(taps, ['runner-3/restart', 'runner-3/kill']);
  });

  testWidgets('a worker with no actions gets no buttons', (tester) async {
    await _pump(
      tester,
      _payload(workers: const [
        {
          'agent': 'runner-9',
          'label': 'runner-9',
          'status': 'idle',
          'title': '',
          'sub': '',
          'tone': 'neutral',
          'busy': false,
          'actions': [],
        }
      ]),
    );
    expect(find.text('runner-9'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('the toggle chip is the payload\'s word, or no chip at all',
      (tester) async {
    await _pump(tester, _payload());
    // vm: desired true, actual false, and it sent the words.
    expect(find.text('not running'), findsOneWidget);
    // claude: no mismatch, so no chip even though it sent the words.
    // workflow: a mismatch with no words. Silence.
    expect(find.text('running'), findsNothing);
  });

  testWidgets('has:false draws nothing — but never eats the footer',
      (tester) async {
    await _pump(tester, _payload(has: false));
    expect(find.text('Runners'), findsNothing);

    await _pump(tester, _payload(has: false),
        footer: const Text('the-controls'));
    expect(find.text('the-controls'), findsOneWidget);
  });

  testWidgets('the footer is drawn exactly once inside the one card',
      (tester) async {
    await _pump(tester, _payload(), footer: const Text('the-controls'));
    expect(find.text('Runners'), findsOneWidget);
    expect(find.text('the-controls'), findsOneWidget);
  });
}
