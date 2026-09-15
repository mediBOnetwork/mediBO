// PROTECTED — CHANGE #1819.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes waiting-economy behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the Waiting economy panel is a PRINTER, and it is the
// only screen that says what a wait cost:
//
//   1. Every string is the backend's. Title, chip, chip tone, the since-line,
//      each row's label, value and sub-line, and the footnote all come from
//      `dev_wait_report()` (delivered as `dev_ctl_get().waiting`). The fixture
//      deliberately carries a chip that DISAGREES with the rows it sits above
//      — 0 tokens on the chip over rows that add up to 7,400 — because the sum
//      is the backend's job. A card that added the rows up would print 7,400
//      here and fail, which is the point: two places computing the same number
//      is how a panel about waste starts lying about waste.
//
//   2. Absence is a flag, never an empty string. `has:false` draws nothing at
//      all — the panel exists to make a burn visible, and a card that renders
//      an empty frame trains the eye to skip it.
//
//   3. Tone is carried, not inferred. Colour comes from the row's own `tone`
//      through one lookup; an unknown tone stays neutral rather than being
//      guessed from the value. A "0 tokens" row is not automatically green:
//      the backend decides, because zero tokens on a wait that never happened
//      and zero on a wait that was parked correctly mean different things.
//
//   4. Rows render in PAYLOAD ORDER. The six wait types have a deliberate
//      order (the lanes first, the proof rows last) and the fixture is sorted
//      by none of label, value or tone, so any client-side sort fails here.
//
//   5. An absent sub-line is OMITTED, never dashed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_waiting.dart';

Map<String, dynamic> _payload({bool has = true, List? rows}) => {
      'has': has,
      'title': 'Waiting economy',
      // Deliberately inconsistent with the rows below: the chip is the
      // backend's total and the card must print it, not check it.
      'chip': '0 tokens across 12 wait(s)',
      'chip_tone': 'success',
      'since_line':
          'Last 24h · park over 60s, sleep under it · both locks unchanged',
      'footnote':
          'A wait must cost under 5,000 tokens. Over that, the session was thinking when it should have exited.',
      'rows': rows ??
          const [
            {
              'key': 'merge',
              'label': 'Merge lane waits',
              'value': '3,200 tokens',
              'sub':
                  '4 wait(s) · 4 park(s) · worst 1,900 tokens · before: 1.60M over 8 events',
              'tone': 'warning'
            },
            {
              'key': 'lease',
              'label': 'File lease waits',
              'value': '4,200 tokens',
              'sub': '7 wait(s) · 7 park(s) · worst 900 tokens · before: 427,414 over 58 events',
              'tone': 'success'
            },
            {
              'key': 'kills',
              'label': 'Killed while waiting',
              'value': '0',
              'sub': 'grace 150000 tokens · target 0 in 24h',
              'tone': 'success'
            },
            {
              'key': 'speed',
              'label': 'Median claim → complete',
              'value': '41m',
              'sub': 'previous 20: 48m',
              'tone': 'success'
            },
          ],
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WaitingEconomyCard(payload: payload),
        ),
      ),
    ));

void main() {
  // The card calls RenderLog.write; its 800 ms debounce is a real Timer that
  // would outlive the test and try to reach Supabase.
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every string on the panel is the backend\'s, verbatim',
      (tester) async {
    await _pump(tester, _payload());

    expect(find.text('Waiting economy'), findsOneWidget);
    expect(find.text('0 tokens across 12 wait(s)'), findsOneWidget);
    expect(
        find.text(
            'Last 24h · park over 60s, sleep under it · both locks unchanged'),
        findsOneWidget);
    expect(find.text('Merge lane waits'), findsOneWidget);
    expect(find.text('3,200 tokens'), findsOneWidget);
    expect(find.text('Median claim → complete'), findsOneWidget);
    expect(find.text('41m'), findsOneWidget);
    expect(find.text('previous 20: 48m'), findsOneWidget);
    expect(
        find.textContaining('A wait must cost under 5,000 tokens'),
        findsOneWidget);
  });

  testWidgets('the chip is printed, never recomputed from the rows',
      (tester) async {
    // The rows carry 3,200 + 4,200 = 7,400 tokens; the chip says 0. The chip
    // the backend sent is the one that must appear.
    await _pump(tester, _payload());
    expect(find.text('0 tokens across 12 wait(s)'), findsOneWidget);
    expect(find.textContaining('7,400'), findsNothing);
  });

  testWidgets('has:false draws nothing at all', (tester) async {
    await _pump(tester, _payload(has: false));
    expect(find.text('Waiting economy'), findsNothing);
    expect(find.text('Merge lane waits'), findsNothing);
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('rows render in payload order', (tester) async {
    await _pump(tester, _payload());
    final merge = tester.getTopLeft(find.text('Merge lane waits')).dy;
    final lease = tester.getTopLeft(find.text('File lease waits')).dy;
    final kills = tester.getTopLeft(find.text('Killed while waiting')).dy;
    final speed = tester.getTopLeft(find.text('Median claim → complete')).dy;
    expect(merge < lease, isTrue);
    expect(lease < kills, isTrue);
    expect(kills < speed, isTrue);
  });

  testWidgets('an absent sub-line is omitted, never printed as a dash',
      (tester) async {
    await _pump(
        tester,
        _payload(rows: const [
          {'key': 'other', 'label': 'Other waits', 'value': '0 tokens', 'tone': 'info'},
        ]));
    expect(find.text('Other waits'), findsOneWidget);
    expect(find.text('0 tokens'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(find.text('-'), findsNothing);
  });

  test('tone is a lookup, and an unknown tone stays neutral', () {
    expect(WaitingEconomyCard.toneKey('success'), 'completed');
    expect(WaitingEconomyCard.toneKey('warning'), 'pending');
    expect(WaitingEconomyCard.toneKey('danger'), 'failed');
    // Not "guess from the number", not "throw": neutral.
    expect(WaitingEconomyCard.toneKey('turquoise'), 'building');
    expect(WaitingEconomyCard.toneKey(''), 'building');
  });
}
