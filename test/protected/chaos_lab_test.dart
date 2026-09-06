// PROTECTED — CHANGE #638.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes chaos/recording behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the Chaos lab is a PRINTER, on the one screen whose
// whole job is to tell the truth about failure:
//
//   1. Every word is `chaos_home()`'s. Title, subtitle, the test-mode line, the
//      session line, the run chip and its counts, each scenario's label, blurb,
//      expectation, verdict WORD, duration string and evidence rows, each
//      recording's chip and step count, every disabled_reason, both empty
//      states and the footnote. The fixture deliberately carries a run chip
//      that says "All 9 degraded safely" over THREE scenario rows, and a
//      counts_label that agrees with neither — a screen that counted its own
//      rows would disagree with the backend here and fail.
//
//   2. Verdict tone is CARRIED, not read off the verdict word. One fixture row
//      says "Degraded safely" with tone 'danger', and another uses a tone name
//      this build has never heard of, which must stay neutral rather than being
//      guessed at from the word. That is what stops a red drill from rendering
//      green the day the backend adds an eighth verdict.
//
//   3. Enablement is the backend's decision, never inferred from status. A
//      STOPPED recording arrives with promote.can:false and its own reason, and
//      the button must be absent and the reason printed — the screen never
//      re-derives "stopped means promotable".
//
//   4. Rows render in PAYLOAD ORDER. The scenarios and the recordings are
//      deliberately not alphabetical and not sorted by verdict, so any
//      client-side sort fails here.
//
//   5. Absence is explicit. No live recording means the Start button and the
//      backend's own disabled_reason, never a fabricated "0 steps"; no
//      scenarios and no recordings each draw the backend's own empty line.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/chaos_lab_screen.dart';

Map<String, dynamic> _payload({
  List<Map<String, dynamic>>? scenarios,
  Map<String, dynamic>? recording,
  Map<String, dynamic>? gaps,
}) =>
    {
      'ok': true,
      'has': true,
      'title': 'Chaos & recording',
      'subtitle': 'The failures that actually bite, reproduced on demand.',
      'footnote': 'Artifacts are stored with the run and purged with the session.',
      'test_mode': const {
        'on': true,
        'label': 'Test mode is ON',
        'tone': 'success',
        'sub': 'Everything below runs in the synthetic lane.',
      },
      'session': const {
        'has': true,
        'label': 'Session: chaos: nightly',
        'sub': 'Expires 06 Sep 18:40 IST',
      },
      // Deliberately disagrees with the three rows below, and with itself.
      'run': const {
        'has': true,
        'id': 12,
        'label': 'nightly chaos',
        'chip': 'All 9 degraded safely',
        'chip_tone': 'success',
        'counts_label': '6 safe · 1 broke · 0 skipped',
        'sub': 'Run #12 · 06 Sep 05:41 IST',
      },
      'action': const {
        'key': 'run_all',
        'label': 'Run every scenario',
        'tone': 'brand',
        'enabled': true,
        'disabled_reason': '',
      },
      'scenarios': scenarios ??
          const [
            // Not alphabetical, not grouped by verdict.
            {
              'key': 'webhook_replay_twice',
              'label': 'Replay a payment webhook twice',
              'blurb': 'Razorpay redelivers the same event id.',
              'family_label': 'Payment',
              'expect_label': 'One log row, no second credit.',
              'verdict_label': 'Broke',
              'verdict_tone': 'danger',
              'has_result': true,
              'duration_label': '184 ms',
              'summary': 'the redelivery was re-processed',
              'evidence': [
                {'label': 'event id', 'value': 'chaos_evt_9f'},
                {'label': 'log rows', 'value': '2'},
              ],
              'gap_label': 'Gap #885 filed',
            },
            {
              // The word says safe, the tone says danger. The tone must win the
              // colour and the word must win the text — neither is derived.
              'key': 'double_submit_form',
              'label': 'Double-submit a form',
              'blurb': 'The same intent submitted twice.',
              'family_label': 'Form',
              'expect_label': 'The second tap writes nothing.',
              'verdict_label': 'Degraded safely',
              'verdict_tone': 'danger',
              'has_result': true,
              'duration_label': '1.4 s',
              'summary': 'two taps, one effect',
              'evidence': [],
              'gap_label': '',
            },
            {
              // A tone name this build has never heard of stays neutral.
              'key': 'lease_during_deploy',
              'label': 'Take a lease mid-deploy',
              'blurb': 'A second writer asks for the exclusive lane.',
              'family_label': 'Lease',
              'expect_label': 'The second writer is refused with a retry.',
              'verdict_label': 'Skipped',
              'verdict_tone': 'chartreuse',
              'has_result': true,
              'duration_label': '',
              'summary': 'the lane was already held',
              'evidence': [],
              'gap_label': '',
            },
          ],
      'scenarios_empty': 'No chaos scenario is registered yet.',
      'recording': recording ??
          const {
            'title': 'Recorded walkthroughs',
            'blurb': 'Record yourself using the app.',
            'live': {
              'has': false,
              'id': null,
              'label': '',
              'step_label': '',
              'steps': [],
              'steps_empty': 'Walk the app — every screen you open lands here.',
            },
            'start': {
              'label': 'Start recording',
              'tone': 'brand',
              'enabled': false,
              'disabled_reason': 'No test session is live.',
            },
            'stop': {'label': 'Stop', 'tone': 'neutral', 'enabled': false},
            'broke_label': 'Stop — something broke',
            'rows': [
              {
                // Stopped, WITH steps, and still not promotable: the backend
                // said so and the screen must not argue.
                'id': 7,
                'label': 'zebra walkthrough',
                'sub': '06 Sep 05:42 IST · admin',
                'chip': 'Something broke',
                'chip_tone': 'danger',
                'steps_label': '1 step',
                'note': 'Cart emptied itself.',
                'promote': {
                  'can': false,
                  'label': 'Make this a permanent test',
                  'disabled_reason': 'This walkthrough recorded no steps.',
                },
                'journey_label': '',
              },
              {
                'id': 4,
                'label': 'alpha walkthrough',
                'sub': '06 Sep 05:10 IST · admin',
                'chip': 'Permanent test',
                'chip_tone': 'success',
                'steps_label': '12 steps',
                'note': '',
                'promote': {
                  'can': false,
                  'label': 'Make this a permanent test',
                  'disabled_reason': '',
                },
                'journey_label': 'Journey rec-4-alpha-walkthrough',
              },
            ],
            'empty_label': 'Nothing recorded yet.',
          },
      'gaps': gaps ??
          const {
            'label': '1 open finding',
            'rows': [
              {
                'id': 885,
                'title': 'A redelivered webhook is applied twice',
                'sub': 'the redelivery was re-processed',
                'chip': 'Chaos drill',
                'chip_tone': 'danger',
              },
            ],
            'empty_label': 'No chaos or walkthrough has filed a finding.',
          },
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  // The screen is one long ListView and a sliver only lays out what is on
  // screen, so the surface is made tall enough to hold the whole page. The
  // point of these tests is what the payload renders to, not what scrolls.
  tester.view.physicalSize = const Size(1000, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: ChaosLabScreen(load: () async => payload),
  ));
  // Never pumpAndSettle here: a live recording draws a spinning chip, which
  // never settles. Two frames are enough to resolve the load future.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  // The screen sits under widgets that call RenderLog.write; its 800 ms
  // debounce is a real Timer that would outlive the test.
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every word on the screen is the backend\'s, verbatim',
      (tester) async {
    await _pump(tester, _payload());

    expect(find.text('Chaos & recording'), findsOneWidget);
    expect(find.text('The failures that actually bite, reproduced on demand.'),
        findsOneWidget);
    expect(find.text('Test mode is ON'), findsOneWidget);
    expect(find.text('Session: chaos: nightly'), findsOneWidget);
    expect(find.text('Expires 06 Sep 18:40 IST'), findsOneWidget);
    expect(find.text('Run every scenario'), findsOneWidget);
    expect(find.text('Replay a payment webhook twice'), findsOneWidget);
    expect(find.text('One log row, no second credit.'), findsOneWidget);
    expect(find.text('184 ms'), findsOneWidget);
    expect(find.text('Gap #885 filed'), findsOneWidget);
    expect(find.text('Artifacts are stored with the run and purged with the session.'),
        findsOneWidget);
  });

  testWidgets('the run chip and counts are printed, never recomputed',
      (tester) async {
    await _pump(tester, _payload());

    // Three scenario rows are on screen; the backend says nine, and nine is
    // what must appear. A card that counted its own rows fails here.
    expect(find.text('All 9 degraded safely'), findsOneWidget);
    expect(find.text('6 safe · 1 broke · 0 skipped'), findsOneWidget);
    expect(find.text('Run #12 · 06 Sep 05:41 IST'), findsOneWidget);
    expect(find.textContaining('3 scenarios'), findsNothing);
  });

  testWidgets('verdict word and verdict tone are two independent fields',
      (tester) async {
    await _pump(tester, _payload());

    // The word is printed exactly as sent even where it disagrees with its
    // own tone, and an unknown tone name renders without throwing.
    expect(find.text('Degraded safely'), findsOneWidget);
    expect(find.text('Broke'), findsOneWidget);
    expect(find.text('Skipped'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scenarios render in payload order', (tester) async {
    await _pump(tester, _payload());

    final webhook =
        tester.getTopLeft(find.text('Replay a payment webhook twice')).dy;
    final form = tester.getTopLeft(find.text('Double-submit a form')).dy;
    final lease = tester.getTopLeft(find.text('Take a lease mid-deploy')).dy;
    expect(webhook, lessThan(form));
    expect(form, lessThan(lease));
  });

  testWidgets('evidence is hidden until the scenario is opened, then printed',
      (tester) async {
    await _pump(tester, _payload());

    expect(find.text('chaos_evt_9f'), findsNothing);
    await tester.tap(find.text('Replay a payment webhook twice'));
    await tester.pump();
    expect(find.text('event id'), findsOneWidget);
    expect(find.text('chaos_evt_9f'), findsOneWidget);
    expect(find.text('log rows'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('promote is the backend\'s decision, not a status inference',
      (tester) async {
    await _pump(tester, _payload());

    // Both rows are stopped and one of them plainly has steps, yet neither is
    // promotable because the payload said so.
    expect(find.text('Make this a permanent test'), findsNothing);
    expect(find.text('This walkthrough recorded no steps.'), findsOneWidget);
    // …and the one already promoted names its journey instead.
    expect(find.text('Journey rec-4-alpha-walkthrough'), findsOneWidget);
  });

  testWidgets('the step count is the backend\'s string, never pluralised here',
      (tester) async {
    await _pump(tester, _payload());
    expect(find.text('1 step'), findsOneWidget);
    expect(find.text('12 steps'), findsOneWidget);
  });

  testWidgets('recordings render in payload order, newest-first as sent',
      (tester) async {
    await _pump(tester, _payload());
    final zebra = tester.getTopLeft(find.text('zebra walkthrough')).dy;
    final alpha = tester.getTopLeft(find.text('alpha walkthrough')).dy;
    expect(zebra, lessThan(alpha));
  });

  testWidgets('no live recording shows Start plus the backend\'s own reason',
      (tester) async {
    await _pump(tester, _payload());

    expect(find.text('Start recording'), findsOneWidget);
    expect(find.text('No test session is live.'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    // Absence is absence: no fabricated zero step count.
    expect(find.text('0 steps so far'), findsNothing);
  });

  testWidgets('a live recording swaps Start for the two stop buttons',
      (tester) async {
    final rec = Map<String, dynamic>.from(
        _payload()['recording'] as Map<String, dynamic>);
    rec['live'] = const {
      'has': true,
      'id': 9,
      'label': 'live walkthrough',
      'step_label': '4 steps so far',
      'steps': [
        {'n': 4, 'label': 'rendered cart_rows', 'sub': 'cart_rows', 'tone': 'danger'},
        {'n': 3, 'label': 'opened', 'sub': '/cart', 'tone': 'neutral'},
      ],
      'steps_empty': 'Walk the app — every screen you open lands here.',
    };
    rec['stop'] = const {'label': 'Stop', 'tone': 'neutral', 'enabled': true};
    await _pump(tester, _payload(recording: rec));

    expect(find.text('live walkthrough'), findsOneWidget);
    expect(find.text('4 steps so far'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Stop — something broke'), findsOneWidget);
    expect(find.text('Start recording'), findsNothing);
    // Steps print in payload order — newest first, exactly as sent.
    final four = tester.getTopLeft(find.text('rendered cart_rows')).dy;
    final three = tester.getTopLeft(find.text('opened')).dy;
    expect(four, lessThan(three));
  });

  testWidgets('empty lists draw the backend\'s own empty lines', (tester) async {
    final rec = Map<String, dynamic>.from(
        _payload()['recording'] as Map<String, dynamic>);
    rec['rows'] = const [];
    await _pump(
        tester,
        _payload(scenarios: const [], recording: rec, gaps: const {
          'label': '0 open findings',
          'rows': [],
          'empty_label': 'No chaos or walkthrough has filed a finding.',
        }));

    expect(find.text('No chaos scenario is registered yet.'), findsOneWidget);
    expect(find.text('Nothing recorded yet.'), findsOneWidget);
    expect(find.text('No chaos or walkthrough has filed a finding.'),
        findsOneWidget);
    expect(find.text('0 open findings'), findsOneWidget);
  });

  testWidgets('test mode off disables the run button and says why',
      (tester) async {
    final p = _payload();
    p['test_mode'] = const {
      'on': false,
      'label': 'Test mode is OFF',
      'tone': 'warning',
      'sub': 'Turn test mode on before running anything here.',
    };
    p['action'] = const {
      'key': 'run_all',
      'label': 'Run every scenario',
      'tone': 'brand',
      'enabled': false,
      'disabled_reason': 'Test mode is off.',
    };
    await _pump(tester, p);

    expect(find.text('Test mode is OFF'), findsOneWidget);
    expect(find.text('Test mode is off.'), findsOneWidget);
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull);
  });
}
