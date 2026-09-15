// PROTECTED — CHANGE #1367.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes runner-strip behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the strip reports REALITY, not the toggle:
//
//   1. A toggle carries `desired` AND `actual`, and when they disagree the card
//      says so. Three capabilities died quietly behind a green switch (usage
//      sync, Remote Control, the build branch — the last reporting enabled:true
//      and want:true while it had been off since the day it shipped). A strip
//      that renders only `desired` cannot ever show that, so the fixture has a
//      toggle with desired:true / actual:false and the mismatch must be visible.
//
//   2. Every word is the backend's. The headline, each blocked line, the
//      building sentence and the branch line come from strip_v3_card(). The
//      fixture's headline deliberately names a DIFFERENT reason than the first
//      entry of `blocked`, so a card that re-derived the headline from the list
//      fails here.
//
//   3. Blocked lines render in PAYLOAD order — the backend ranks them.
//
//   4. An UNOBSERVABLE capability is never drawn as broken. This is the rule
//      #1369 got wrong in production, where "cannot tell" was read as "broken"
//      and the claim gate stopped the whole fleet: an empty `blocked` list
//      draws no warnings at all, whatever `actual` happens to contain.
//
//   5. has:false draws nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/strip_v3/strip_v3_view.dart';

Map<String, dynamic> _payload({
  bool has = true,
  List? blocked,
  List? toggles,
  String headline = 'Blocked: Branch wanted for 3 command(s), not created yet',
}) =>
    {
      'has': has,
      'title': 'Runners',
      'headline': headline,
      'tone': 'warning',
      'building_label': 'Building #1361, #1367',
      'building_ids': '#1361, #1367',
      'branch_label': 'Build branch off',
      'drain_label': '',
      'blocked': blocked ??
          const [
            'Branch wanted for 3 command(s), not created yet',
            'Usage sync failing: token refresh returned 401',
          ],
      'toggles': toggles ??
          const [
            {
              'key': 'vm',
              'label': 'VM',
              'desired': true,
              'actual': true,
              'sub': ''
            },
            {
              'key': 'claude',
              'label': 'Start building',
              'desired': true,
              'actual': true,
              'sub': 'One runner, one command at a time.'
            },
            // The case the whole change exists for: asked for, not happening.
            // CHANGE #1570 — and the words for it are the backend's.
            {
              'key': 'workflow',
              'label': 'Parallel building',
              'desired': true,
              'actual': false,
              'actual_label': 'running',
              'not_actual_label': 'not running',
              'sub': 'Up to 3 runners at once (Pool settings).'
            },
          ],
      'zone': null,
      'date': '2026-09-05',
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> p,
        {void Function(String, bool)? onToggle, bool busy = false}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StripV3View(data: p, onToggle: onToggle, busy: busy),
        ),
      ),
    ));

// CHANGE #1570 — the mismatch chip's two words ('running' / 'not running')
// were Dart literals; they are payload strings now, so the fixture carries
// them. What this file holds down is unchanged: a desired/actual mismatch is
// VISIBLE, and two that agree carry no chip.
void main() {
  // The card calls RenderLog.write; its 800 ms debounce is a real Timer that
  // would outlive the test and try to reach Supabase.
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('a toggle that is on but not running says so', (tester) async {
    await _pump(tester, _payload());
    // desired:true actual:false must be visible as a mismatch, not hidden
    // behind a green switch.
    expect(find.text('not running'), findsOneWidget);
    // The two that agree carry no mismatch chip.
    expect(find.text('running'), findsNothing);
  });

  testWidgets('the headline is the backend string, not derived from the list',
      (tester) async {
    await _pump(
        tester,
        _payload(
            headline: 'Blocked: something only the server knows',
            blocked: const ['a different first reason']));
    expect(find.text('Blocked: something only the server knows'), findsOneWidget);
  });

  testWidgets('blocked lines render in payload order', (tester) async {
    await _pump(tester, _payload());
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.startsWith('Branch wanted') || s.startsWith('Usage sync'))
        .toList();
    expect(texts, [
      'Branch wanted for 3 command(s), not created yet',
      'Usage sync failing: token refresh returned 401',
    ]);
  });

  testWidgets('an empty blocked list draws no warnings at all', (tester) async {
    await _pump(
        tester,
        _payload(blocked: const [], headline: 'Running as asked.', toggles: const [
          {'key': 'vm', 'label': 'VM', 'desired': true, 'actual': true, 'sub': ''}
        ]));
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.text('Running as asked.'), findsOneWidget);
  });

  testWidgets('the building sentence and branch line print verbatim',
      (tester) async {
    await _pump(tester, _payload());
    expect(find.text('Building #1361, #1367'), findsOneWidget);
    expect(find.text('Build branch off'), findsOneWidget);
  });

  testWidgets('a tap reports the backend key and the requested state',
      (tester) async {
    final seen = <String>[];
    await _pump(tester, _payload(),
        onToggle: (k, v) => seen.add('$k=$v'));
    await tester.tap(find.byType(Switch).last);
    await tester.pump();
    // The LAST toggle is workflow, currently desired:true → tapping asks false.
    expect(seen, ['workflow=false']);
  });

  testWidgets('busy closes every switch', (tester) async {
    final seen = <String>[];
    await _pump(tester, _payload(), busy: true,
        onToggle: (k, v) => seen.add('$k=$v'));
    await tester.tap(find.byType(Switch).last, warnIfMissed: false);
    await tester.pump();
    expect(seen, isEmpty);
  });

  testWidgets('has:false draws nothing', (tester) async {
    await _pump(tester, _payload(has: false));
    expect(find.text('Runners'), findsNothing);
    expect(StripV3View.shows(_payload(has: false)), isFalse);
  });
}
