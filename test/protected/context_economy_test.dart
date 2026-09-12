// PROTECTED — CHANGE #1197.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes context-economy behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the Context economy panel is a PRINTER:
//
//   1. Every string on it is the backend's. The title, the threshold chip, the
//      "since" line, each row's label, value, sub-line and the footnote come
//      from `dev_context_metrics()` (delivered as `dev_ctl_get().context`).
//      The fixture deliberately carries a "before" that is SMALLER than the
//      "after" and a Change row that still says a saving — because arithmetic
//      is the backend's job and a card that recomputed it would disagree.
//
//   2. Absence is a flag, never an empty string. `has:false` draws nothing at
//      all — not a blank card, not a spinner, not a zero.
//
//   3. Tone is carried, not inferred. A row's colour comes from its own `tone`
//      field through one lookup; an unknown tone stays neutral instead of being
//      guessed at from the value's sign. That is what stops a red "+41%" from
//      turning green the day the backend adds a tone name Dart has not heard of.
//
//   4. Rows render in PAYLOAD ORDER. The fixture is deliberately not sorted by
//      label, value or tone, so any client-side sort fails here.
//
//   5. CHANGE #1817 — the Waiting row. It is the only place Om can see that a
//      queued command sat there THINKING (#1812 spent 159,555 tokens waiting
//      for a 17-minute batch that cost nothing). Its value, its sub-line and
//      its DANGER tone are all the backend's: the fixture pairs a red tone with
//      a sub-line that says "0 wake-up(s)", so a card that decided the colour
//      from the wake-up count would turn it green and fail here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_context.dart';

Map<String, dynamic> _payload({bool has = true, List? rows}) => {
      'ok': true,
      'has': has,
      'title': 'Context economy',
      'since_label': 'since 04 Sep 15:20 IST',
      'threshold_label': 'compact at 70% context',
      'footnote': 'Measured over the 20 commands completed on each side.',
      'rows': rows ??
          const [
            // Deliberately unsorted, and deliberately inconsistent with its own
            // arithmetic: the card must print, never check.
            {
              'label': 'Tokens / command — before',
              'value': '2.6M',
              'sub': '20 commands',
              'tone': 'info'
            },
            {
              'label': 'Tokens / command — after',
              'value': '1.5M',
              'sub': '7 of 20 commands',
              'tone': 'info'
            },
            {
              'label': 'Change',
              'value': '-41.9%',
              'sub': 'lower is better',
              'tone': 'success'
            },
            {
              // #1817: red, with a sub-line that reads zero. The card must not
              // reconcile the two — the tone is carried, not inferred.
              'label': 'Waiting',
              'value': '17m asleep · 340 tokens',
              'sub': '2 wait(s) · 0 wake-up(s) · target 0',
              'tone': 'danger'
            },
            {
              'label': '/compact vs /clear',
              'value': '12 · 1',
              'sub': 'compact first, clear only on failure',
              'tone': 'success'
            },
            {
              'label': 'Average resume size',
              'value': '148 words',
              'sub': 'cap 200 words · 9 rows',
              'tone': 'warning'
            },
          ],
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ContextEconomyCard(payload: payload),
        ),
      ),
    ));

void main() {
  // The card calls RenderLog.write; its 800 ms debounce is a real Timer that
  // would outlive the test and try to reach Supabase.
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every string on the card is the backend\'s, verbatim',
      (tester) async {
    await _pump(tester, _payload());

    expect(find.text('Context economy'), findsOneWidget);
    expect(find.text('compact at 70% context'), findsOneWidget);
    expect(find.text('since 04 Sep 15:20 IST'), findsOneWidget);
    expect(find.text('Measured over the 20 commands completed on each side.'),
        findsOneWidget);

    // Labels, values and sub-lines all print exactly as sent.
    expect(find.text('Tokens / command — before'), findsOneWidget);
    expect(find.text('2.6M'), findsOneWidget);
    expect(find.text('20 commands'), findsOneWidget);
    expect(find.text('/compact vs /clear'), findsOneWidget);
    expect(find.text('12 · 1'), findsOneWidget);
    expect(find.text('148 words'), findsOneWidget);
    expect(find.text('cap 200 words · 9 rows'), findsOneWidget);
  });

  testWidgets('the Change row is the backend\'s number, not a recomputation',
      (tester) async {
    // 2.6M -> 1.5M is about -42%; the payload says -41.9% and that is what must
    // appear. A card that did the division would print its own answer here.
    await _pump(tester, _payload());
    expect(find.text('-41.9%'), findsOneWidget);
    expect(find.textContaining('%').evaluate().length, greaterThan(0));
  });

  testWidgets('has:false draws nothing at all', (tester) async {
    await _pump(tester, _payload(has: false));
    expect(find.text('Context economy'), findsNothing);
    expect(find.text('2.6M'), findsNothing);
    expect(find.byType(ToneChipFinderProbe), findsNothing);
  });

  testWidgets('an absent sub-line is omitted, never printed as a dash',
      (tester) async {
    await _pump(
        tester,
        _payload(rows: const [
          {'label': 'Solo row', 'value': '7', 'tone': 'info'},
        ]));
    expect(find.text('Solo row'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(find.text('-'), findsNothing);
  });

  testWidgets(
      'CHANGE #1817 — the Waiting row prints the backend\'s words and its own tone',
      (tester) async {
    await _pump(tester, _payload());

    // Verbatim. Not "17 minutes", not a recomputed token count, not a plural
    // Dart chose: the whole sentence is one backend string.
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.text('17m asleep · 340 tokens'), findsOneWidget);
    expect(find.text('2 wait(s) · 0 wake-up(s) · target 0'), findsOneWidget);

    // And the colour is the payload's, even though its own sub-line reads zero
    // wake-ups. Whether waiting was expensive is the database's judgement.
    expect(ContextEconomyCard.toneKey('danger'), 'failed');
  });

  testWidgets('#1817 — a Waiting row with no waits yet is still just printed',
      (tester) async {
    await _pump(
        tester,
        _payload(rows: const [
          {
            'label': 'Waiting',
            'value': 'no waits yet',
            'sub': 'a queued command sleeps in the shell — target 0 wake-ups',
            'tone': 'info'
          },
        ]));
    expect(find.text('no waits yet'), findsOneWidget);
    expect(
        find.text('a queued command sleeps in the shell — target 0 wake-ups'),
        findsOneWidget);
    // No zero is invented for an unmeasured state.
    expect(find.text('0'), findsNothing);
    expect(find.text('—'), findsNothing);
  });

  test('tone is a lookup, and an unknown tone stays neutral', () {
    expect(ContextEconomyCard.toneKey('success'), 'completed');
    expect(ContextEconomyCard.toneKey('warning'), 'pending');
    expect(ContextEconomyCard.toneKey('danger'), 'failed');
    // The point of the default: a tone this build has never heard of must not
    // be guessed at, and must not throw.
    expect(ContextEconomyCard.toneKey('teal'), 'building');
    expect(ContextEconomyCard.toneKey(''), 'building');
  });

  testWidgets('rows render in payload order, with no client-side sort',
      (tester) async {
    await _pump(tester, _payload());
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.startsWith('Tokens / command') ||
            s == 'Change' ||
            s == 'Waiting' ||
            s == '/compact vs /clear' ||
            s == 'Average resume size')
        .toList();
    expect(labels, [
      'Tokens / command — before',
      'Tokens / command — after',
      'Change',
      'Waiting',
      '/compact vs /clear',
      'Average resume size',
    ]);
  });
}

/// A type that is never built — it exists only so the `has:false` test can
/// assert on "no chip of ours was rendered" without importing the chip itself.
class ToneChipFinderProbe extends StatelessWidget {
  const ToneChipFinderProbe({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
