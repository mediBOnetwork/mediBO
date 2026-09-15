// PROTECTED — CHANGE #1361.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes cron-budget behaviour, never to make an unrelated change
// go green.
//
// What this holds down — the budget panel is a PRINTER, and the number it
// prints is the one that predicts starvation:
//
//   1. The RATIO is the backend's, never recomputed. The fixture's `value`
//      ("44.6% of its interval") deliberately disagrees with its own `sub`
//      ("53s every 2m" — which is 44.5%), so a panel that divided the two
//      itself would disagree with the server and fail here. On 5 Sep the app
//      took minutes per tab because a task took 22-66 s of a 60 s interval;
//      a duration alone never showed that, and the ratio is the whole point.
//
//   2. Rows render in PAYLOAD order. The backend sorts by share of interval,
//      which is NOT the same order as raw duration — the fixture is sorted by
//      neither name nor duration, so any client-side sort fails.
//
//   3. Tone is carried, not inferred. One lookup; an unknown tone stays
//      neutral rather than being guessed from the percentage.
//
//   4. An empty parked list prints the BACKEND's sentence, never a blank space
//      and never one worded in Dart.
//
//   5. has:false draws nothing at all — not a blank card, not a spinner.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/cron_budget_section.dart';

Map<String, dynamic> _payload({List? parked, List? top, bool has = true}) => {
      'has': has,
      'title': 'Budget',
      'night_label': 'Night only (02:00-05:00 IST)',
      'enforced': true,
      'rule_label':
          'Over 20% of its own interval (20s for tasks under 1m) is parked',
      'parked_head': 'Parked tasks',
      'parked_empty': 'No task is over its budget.',
      'parked': parked ?? const [],
      'top': top ??
          const [
            // Deliberately not sorted by name or by duration, and the first
            // row's value deliberately disagrees with dividing its own sub-line.
            {
              'name': 'rg_after_deploy',
              'value': '44.6% of its interval',
              'sub': '53s every 2m',
              'tone': 'danger',
              'night': false,
            },
            {
              'name': 'catalogue_cache_refresh',
              'value': '9.7% of its interval',
              'sub': '29s every 5m',
              'tone': 'warning',
              'night': true,
            },
            {
              'name': 'mcc_refresh',
              'value': '0.2% of its interval',
              'sub': '30s every 4h',
              'tone': 'success',
              'night': false,
            },
          ],
      'zone': null,
      'date': '2026-09-05',
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  // The panel is driven from its payload here; the widget under test is the
  // pure renderer beneath it.
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: CronBudgetView(data: payload)),
    ),
  ));
}

void main() {
  testWidgets('the ratio is the backend string, never recomputed',
      (tester) async {
    await _pump(tester, _payload());
    expect(find.text('44.6% of its interval'), findsOneWidget);
    expect(find.text('53s every 2m'), findsOneWidget);
    // 53/120 is 44.2%, not 44.6% — a panel that did the division would print
    // its own number and this would fail.
    expect(find.textContaining('44.2'), findsNothing);
  });

  testWidgets('rows render in payload order, not sorted by name or duration',
      (tester) async {
    await _pump(tester, _payload());
    final names = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) =>
            s == 'rg_after_deploy' ||
            s == 'catalogue_cache_refresh' ||
            s == 'mcc_refresh')
        .toList();
    expect(names, ['rg_after_deploy', 'catalogue_cache_refresh', 'mcc_refresh']);
  });

  testWidgets('an empty parked list prints the backend sentence',
      (tester) async {
    await _pump(tester, _payload());
    expect(find.text('No task is over its budget.'), findsOneWidget);
  });

  testWidgets('a parked task prints its own reason verbatim', (tester) async {
    await _pump(
      tester,
      _payload(parked: const [
        {
          'name': 'catalogue_cache_refresh',
          'label': 'Parked — over budget',
          'detail':
              'catalogue_cache_refresh took 1m 35s of its 5m interval (31.7%). It is parked until an admin re-enables it.',
          'at_label': '05 Sep 16:28',
          'tone': 'warning',
        }
      ]),
    );
    expect(find.text('catalogue_cache_refresh · Parked — over budget'),
        findsOneWidget);
    expect(
        find.textContaining('took 1m 35s of its 5m interval (31.7%)'),
        findsOneWidget);
    // The empty-state sentence must be gone once something is parked.
    expect(find.text('No task is over its budget.'), findsNothing);
  });

  testWidgets('an unknown tone stays neutral instead of being guessed',
      (tester) async {
    await _pump(
        tester,
        _payload(top: const [
          {
            'name': 'future_task',
            'value': '90% of its interval',
            'sub': '9s every 10s',
            'tone': 'chartreuse',
          }
        ]));
    // It renders — an unheard-of tone must never blank the row.
    expect(find.text('90% of its interval'), findsOneWidget);
    expect(find.text('future_task'), findsOneWidget);
  });

  testWidgets('has:false draws nothing at all', (tester) async {
    await _pump(tester, _payload(has: false));
    expect(find.text('Budget'), findsNothing);
    expect(find.text('No task is over its budget.'), findsNothing);
  });
}
