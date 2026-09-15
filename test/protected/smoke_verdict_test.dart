// CHANGE #1823 — the critical-path smoke verdict on the Deploy lane card.
//
// Every batch used to end with "critical-path smoke could not run (exit 2) —
// not treated as a failure", buried in merge_worker.journal, while the run had
// in fact found two real reds and crashed on a reporting bug. The verdict now
// lives on the batch (merge_batch_smoke) and the card prints it. The card is
// a PRINTER:
//   1. label, detail and the verdict word are merge_batch_smoke_status()'s,
//      printed verbatim — the fixture's label deliberately says FAILED while
//      its verdict says passed, so a card that re-derived either from the
//      other fails.
//   2. tone is one lookup of the backend's tone name (error → the error tint),
//      never "verdict == failed".
//   3. has:false draws nothing at all — no dash, no "no smoke yet" invented
//      in Dart; the rest of the card is unaffected.
//   4. An absent detail is omitted rather than dashed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/deploy_lane_section.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';

Widget _host(Map<String, dynamic> data) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DeployLaneSection(data: data)),
      ),
    );

Map<String, dynamic> _payload({Map<String, dynamic>? smoke}) => {
      'ok': true,
      'title': 'Deploy lane',
      'subtitle': 'Merge queue — runners push a branch and leave.',
      'mode_label': 'MERGE QUEUE',
      'mode_tone': 'success',
      'lane': {
        'busy': false,
        'label': 'Lane free',
        'detail': 'Nothing merging right now.',
        'held_label': '—',
        'tone': 'success',
      },
      'queue': {
        'count': 0,
        'label': 'Queue empty',
        'empty_hint': 'Runners push a branch here and go straight back to building.',
        'window_label': 'Batch window 300s · nothing waiting.',
        'rows': <Map<String, dynamic>>[],
      },
      'metrics': {
        'heading': 'Wait vs hold, last 7 days',
        'avg_hold_label': 'avg lane hold 41s',
        'avg_wait_label': 'avg queue wait 12s',
        'target_label': 'target hold under 60s',
        'tone': 'success',
      },
      'recent_heading': 'Recent deploys',
      'recent': <Map<String, dynamic>>[],
      'stale_heading': 'Stale claims',
      'stale_empty': 'No claim is holding a queue slot past its TTL.',
      'stale': <Map<String, dynamic>>[],
      if (smoke != null) 'smoke': smoke,
    };

void main() {
  testWidgets('the smoke sentence, detail and verdict word print verbatim',
      (tester) async {
    await tester.pumpWidget(_host(_payload(smoke: {
      'has': true,
      // Deliberately inconsistent: a card that computed the label from the
      // verdict, or the verdict from the label, cannot print both of these.
      'verdict': 'passed',
      'label': 'Critical-path smoke FAILED — 2 red: devtool.order_pipeline '
          '(admin/happy_path) · batch 603 not deployed',
      'detail': 'batch 603 · https://smoke-gate.medibo.pages.dev · 06 Sep 14:18 IST',
      'tone': 'error',
      'batch_id': 603,
    })));
    await tester.pump();

    expect(
      find.text('Critical-path smoke FAILED — 2 red: devtool.order_pipeline '
          '(admin/happy_path) · batch 603 not deployed'),
      findsOneWidget,
    );
    expect(
      find.text('batch 603 · https://smoke-gate.medibo.pages.dev · 06 Sep 14:18 IST'),
      findsOneWidget,
    );
    // The chip carries the verdict WORD the backend sent, not one derived
    // from the sentence.
    expect(find.text('passed'), findsOneWidget);
    expect(find.text('failed'), findsNothing);
  });

  testWidgets('tone is one lookup of the backend name, never verdict == failed',
      (tester) async {
    await tester.pumpWidget(_host(_payload(smoke: {
      'has': true,
      'verdict': 'failed',
      'label': 'Critical-path smoke could not run — 9 journeys blocked',
      'detail': 'batch 604',
      'tone': 'warning',
    })));
    await tester.pump();

    final chip = tester.widget<ToneChip>(
      find.widgetWithText(ToneChip, 'failed'),
    );
    expect(chip.tone.fg, toneByName('warning').fg);
    expect(chip.tone.fg, isNot(toneByName('error').fg));
  });

  testWidgets('has:false draws nothing and the card is otherwise untouched',
      (tester) async {
    await tester.pumpWidget(_host(_payload(smoke: {'has': false})));
    await tester.pump();

    expect(find.textContaining('Critical-path smoke'), findsNothing);
    expect(find.textContaining('smoke'), findsNothing);
    expect(find.text('Lane free'), findsOneWidget);
    expect(find.text('Queue empty'), findsOneWidget);
  });

  testWidgets('no smoke block at all is the same as has:false',
      (tester) async {
    await tester.pumpWidget(_host(_payload()));
    await tester.pump();
    expect(find.textContaining('smoke'), findsNothing);
    expect(find.text('Lane free'), findsOneWidget);
  });

  testWidgets('an absent detail is omitted, never dashed', (tester) async {
    await tester.pumpWidget(_host(_payload(smoke: {
      'has': true,
      'verdict': 'passed',
      'label': 'Critical-path smoke passed — 14 journeys green',
      'tone': 'success',
    })));
    await tester.pump();
    expect(find.text('Critical-path smoke passed — 14 journeys green'),
        findsOneWidget);
    expect(find.text('—'), findsOneWidget); // only the lane's own held_label
    expect(find.text('passed'), findsOneWidget);
  });
}
