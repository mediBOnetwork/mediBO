// PROTECTED — CMD #2075.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the feature-journey card, never to make an unrelated
// change go green.
//
// What this holds down: the feature-journey block on a command's detail screen
// is ONE payload printed verbatim. `dev_cmd_qa_detail().feature_journey` is
// built by `_dev_feature_journey_card()` on the control plane — the SAME
// function the finish gate reads — so the words Om sees are the words that
// block or free the row. The card therefore:
//
//   1. prints title, status_label, detail, rows (label/value), plan lines,
//      evidence links and the hint exactly as sent — a 'FAILED' sentence is not
//      re-worded, a stale pass is not promoted to green in Dart;
//   2. keeps payload order for the lane rows (the fixture is deliberately
//      medibo.in BEFORE Branch preview — a client sort would flip it);
//   3. draws nothing for a field the backend left empty (no hint → no hint
//      line), and draws the whole block only when the payload exists;
//   4. carries Semantics(identifier: 'devq_feature_journey') so the Playwright
//      runner can address it, and fits a 360px phone without overflow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/feature_journey_card.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _fj({String hint = 'Red → fix on the branch, then: devcmd.sh feature_journey 2075 run live'}) => {
      'needed': true,
      'has': true,
      'valid': true,
      'green': false,
      'name': 'feat-2075',
      'title': 'Feature journey',
      'status_label': 'Red on live',
      'status_tone': 'error',
      'detail':
          'live run FAILED at 18 Sep 19:40 — w360 step 2 (tap): no semantics node "dq_section_journeys" (attempt 1 of 3)',
      'rows': [
        {'label': 'medibo.in', 'value': 'FAILED · 18 Sep, 19:40 · CHANGE #1426 · 412px', 'tone': 'error'},
        {'label': 'Branch preview', 'value': 'PASSED · 18 Sep, 19:31 · CHANGE #1426 · 360px+412px', 'tone': 'success'},
        {'label': 'Runs as', 'value': 'super_admin', 'tone': 'neutral'},
      ],
      'lines': [
        '1. open /admin/dev-queue?cmd={cmd}',
        '2. tap dq_section_journeys',
        '3. expect navigation to /admin/dev-queue',
        '4. expect rpc dev_cmd_qa_detail in the network log',
        '5. assert sql (dev): feat-{cmd} is declared with its five steps on the control plane',
      ],
      'links': [
        {'label': 'Video · live', 'path': '2075/journey/live/c1426/w360.webm'},
        {'label': 'SQL proof · live', 'path': '2075/journey/live/c1426/sql_proof.json'},
      ],
      'steps_title': 'Steps',
      'hint': hint,
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> fj) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: FeatureJourneyCard(fj: fj)),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  testWidgets('prints every backend string verbatim and computes nothing', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(tester, _fj());
    expect(tester.takeException(), isNull, reason: 'the block must fit a 360px phone');
    expect(find.text('Feature journey'), findsOneWidget);
    expect(find.text('Red on live'), findsOneWidget);
    expect(
        find.text(
            'live run FAILED at 18 Sep 19:40 — w360 step 2 (tap): no semantics node "dq_section_journeys" (attempt 1 of 3)'),
        findsOneWidget,
        reason: 'the gate sentence is printed as sent, never re-worded');
    expect(find.text('FAILED · 18 Sep, 19:40 · CHANGE #1426 · 412px'), findsOneWidget);
    expect(find.text('PASSED · 18 Sep, 19:31 · CHANGE #1426 · 360px+412px'), findsOneWidget);
    expect(find.text('super_admin'), findsOneWidget);
    expect(find.text('2. tap dq_section_journeys'), findsOneWidget);
    expect(find.text('Steps'), findsOneWidget);
    expect(find.text('Video · live: 2075/journey/live/c1426/w360.webm'), findsOneWidget);
    expect(find.text('Red → fix on the branch, then: devcmd.sh feature_journey 2075 run live'),
        findsOneWidget);
    // nothing invented: no 'Green', no 'Passed' chip, no rerun word of Dart's own
    expect(find.text('Green on live'), findsNothing);
    expect(find.textContaining('Rerun'), findsNothing);
  });

  testWidgets('keeps the lane rows in payload order (medibo.in first)', (tester) async {
    await _pump(tester, _fj());
    final live = tester.getTopLeft(find.text('medibo.in'));
    final preview = tester.getTopLeft(find.text('Branch preview'));
    final role = tester.getTopLeft(find.text('Runs as'));
    expect(live.dy, lessThan(preview.dy), reason: 'payload order, not alphabetical');
    expect(preview.dy, lessThan(role.dy));
  });

  testWidgets('an empty hint draws no hint line; the semantics target is present', (tester) async {
    await _pump(tester, _fj(hint: ''));
    expect(find.textContaining('devcmd.sh feature_journey'), findsNothing);
    expect(
        find.byWidgetPredicate((w) =>
            w is Semantics && w.properties.identifier == 'devq_feature_journey'),
        findsOneWidget);
  });
}
