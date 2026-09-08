// PROTECTED — CHANGE #636.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes safety-net behaviour, never to make an unrelated change
// go green.
//
// What this holds down — the Safety net screen is a PRINTER, and it is the one
// surface that says how much of the system is actually being graded:
//
//   1. Every word is `autotest_safety_net_home()`'s. The fixture's tile values
//      deliberately disagree with each other and with their own sub-lines
//      ("37,280 checks" over "3,401 open" while the fuzz tile claims 0 of 60
//      broke and the run header still says "Findings filed"), so a screen that
//      recounted, re-derived or re-worded anything fails here.
//
//   2. Tone is CARRIED, never inferred. A row is red because the payload said
//      `tone: danger`, not because a number was greater than zero — and an
//      unknown tone name renders instead of throwing. That is what stops a real
//      finding from turning green the day the backend adds a tone.
//
//   3. Rows and sections render in PAYLOAD ORDER. The fixture's sections are
//      deliberately not alphabetical and its rows are not sorted by severity,
//      so any client-side sort fails.
//
//   4. Never-run is a FLAG, not an empty list. `has_run:false` draws the
//      backend's own empty title and sub-line — never a zero, never a spinner
//      left spinning, never "0 checks" implying a clean bill of health.
//
//   5. The evidence is printed whole. A proven reach carries the exact call and
//      the seed that produced it; truncating that in Dart is how a finding
//      stops being reproducible.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/safety_net_screen.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// A service that answers from a fixture and never opens a socket.
class _FakeService implements DevQueueService {
  _FakeService(this.home);
  final Map<String, dynamic> home;
  int runs = 0;

  @override
  Future<Map<String, dynamic>> safetyNetHome() async => home;

  @override
  Future<Map<String, dynamic>> safetyNetRun() async {
    runs++;
    return {'ok': true, 'run_id': 9};
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('the screen calls exactly two RPCs: ${i.memberName}');
}

Map<String, dynamic> _payload({bool hasRun = true}) => {
      'has': true,
      'has_run': hasRun,
      'title': 'Safety net',
      'subtitle': 'Tests the system generates for itself.',
      'run_label': 'Run the safety net',
      'running_label': 'Running…',
      'empty_row': 'Nothing to answer for.',
      'empty_title': 'Never run yet',
      'empty_sub': 'Run it once to generate the matrix.',
      'footnote': 'Every case is a pure function of its seed.',
      'run': {
        'label': 'nightly safety net',
        'when_label': '06 Sep 2026, 03:53 IST',
        'status_label': 'Findings filed',
        'status_tone': 'danger',
        'seed_label': 'seed 20260636',
      },
      // Deliberately inconsistent with each other: the screen prints.
      'tiles': const [
        {
          'key': 'auth',
          'label': 'Auth matrix',
          'value': '37,280 checks',
          'sub': '3,401 open',
          'tone': 'danger'
        },
        {
          'key': 'fuzz',
          'label': 'Property fuzzing',
          'value': '60 cases',
          'sub': '0 broke',
          'tone': 'success'
        },
        {
          'key': 'invariants',
          'label': 'Invariant oracles',
          'value': '13 oracles',
          'sub': '1 broken',
          'tone': 'danger'
        },
        {
          'key': 'gaps',
          'label': 'Findings filed',
          'value': '72 gaps',
          'sub': 'seed 20260636',
          'tone': 'warning'
        },
      ],
      // Not alphabetical, and rows are not severity-sorted.
      'sections': const [
        {
          'key': 'invariants',
          'title': 'Invariant oracles',
          'rows': [
            {
              'title': 'No synthetic row loose in a business table',
              'sub': 'synthetic.no_residue · 8 violation(s) at after_fuzz',
              'badge': 'FAIL',
              'tone': 'danger'
            },
            {
              'title': 'An order total is never negative',
              'sub': 'money.no_negative_order_total · 0 violation(s)',
              'badge': 'PASS',
              'tone': 'success'
            },
          ],
        },
        {
          'key': 'auth',
          'title': 'Auth matrix',
          'rows': [
            {
              'title': 'rg_run_behaviors answers anon',
              'sub':
                  'PROVEN (set_role): select public.rg_run_behaviors() answered as anon [sqlstate 00000]',
              'badge': 'PROVEN',
              'tone': 'danger'
            },
            {
              'title': 'settlement_tick answers anon',
              'sub': 'PROVEN (set_role): select public.settlement_tick()',
              // A tone name this build has never heard of must still render.
              'badge': 'PROVEN',
              'tone': 'ultraviolet'
            },
          ],
        },
        {
          'key': 'fuzz',
          'title': 'Property fuzzing',
          'rows': [],
        },
      ],
    };

Future<void> _pump(WidgetTester t, Map<String, dynamic> p,
    {_FakeService? svc}) async {
  // Tall surface: every section must be judged on what it RENDERS, not on what
  // happens to fit above the fold of a 600 px test window.
  t.view.physicalSize = const Size(1200, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
      home: SafetyNetScreen(service: svc ?? _FakeService(p))));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every tile prints the backend value and its own sub-line',
      (t) async {
    await _pump(t, _payload());
    for (final s in const [
      '37,280 checks',
      '3,401 open',
      '60 cases',
      '0 broke',
      '13 oracles',
      '1 broken',
      '72 gaps',
    ]) {
      expect(find.text(s), findsOneWidget, reason: '$s must print verbatim');
    }
    // Nothing recomputed: no total, no percentage, no re-pluralised word.
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('the run header is the payload, tone included', (t) async {
    await _pump(t, _payload());
    expect(find.text('nightly safety net'), findsOneWidget);
    expect(find.text('Findings filed'), findsWidgets);
    expect(find.text('06 Sep 2026, 03:53 IST · seed 20260636'), findsOneWidget);
  });

  testWidgets('sections and rows render in payload order', (t) async {
    await _pump(t, _payload());
    final texts = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .toList();
    int at(String s) => texts.indexWhere((x) => x == s);
    // The payload puts Invariant oracles FIRST even though 'Auth matrix' sorts
    // earlier; a client-side sort would swap them. Anchored on the row titles,
    // which appear exactly once each.
    expect(at('No synthetic row loose in a business table') > -1, isTrue);
    expect(
        at('No synthetic row loose in a business table') <
            at('rg_run_behaviors answers anon'),
        isTrue);
    // And inside a section the payload's own order survives — the fixture is
    // deliberately not severity-sorted.
    expect(
        at('rg_run_behaviors answers anon') <
            at('settlement_tick answers anon'),
        isTrue);
    expect(
        at('No synthetic row loose in a business table') <
            at('An order total is never negative'),
        isTrue);
  });

  testWidgets('an unknown tone renders instead of throwing', (t) async {
    await _pump(t, _payload());
    // 'ultraviolet' is not a tone this build knows. The row must still print —
    // a finding that disappears because its colour was unfamiliar is worse than
    // an ugly one.
    expect(find.text('settlement_tick answers anon'), findsOneWidget);
    expect(find.text('PROVEN'), findsNWidgets(2));
  });

  testWidgets('the proven evidence is printed whole, not summarised',
      (t) async {
    await _pump(t, _payload());
    expect(
        find.text(
            'PROVEN (set_role): select public.rg_run_behaviors() answered as anon [sqlstate 00000]'),
        findsOneWidget);
  });

  testWidgets('an empty section prints the backend empty line', (t) async {
    await _pump(t, _payload());
    expect(find.text('Nothing to answer for.'), findsOneWidget);
  });

  testWidgets('never-run draws the backend empty state, never a zero',
      (t) async {
    final p = _payload(hasRun: false)
      ..['tiles'] = const []
      ..['sections'] = const [];
    await _pump(t, p);
    expect(find.text('Never run yet'), findsOneWidget);
    expect(find.text('Run it once to generate the matrix.'), findsOneWidget);
    expect(find.textContaining('0 checks'), findsNothing);
  });

  testWidgets('the button calls the backend exactly once per tap', (t) async {
    final svc = _FakeService(_payload());
    await _pump(t, _payload(), svc: svc);
    await t.tap(find.text('Run the safety net'));
    await t.pumpAndSettle();
    expect(svc.runs, 1);
  });
}
