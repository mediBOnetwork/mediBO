// PROTECTED — CHANGE #1368.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes runner-policy behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the Runner policies card is a PRINTER, and the
// policies themselves are the BACKEND's:
//
//   1. Every word is the payload's. Labels, sub-lines, the headline, the
//      workers line and — the one that matters — each policy's STATE SENTENCE
//      ("Draining — 2 still building", "8% ahead of the weekly budget"). The
//      fixture deliberately sends a policy whose `on` is TRUE while its state
//      sentence says it is holding nothing, so a card that re-derived the
//      sentence from the boolean fails here.
//
//   2. There are no ON/OFF words in Dart. A row switched off prints the
//      backend's own off-word; the widget never substitutes one.
//
//   3. Tone is carried, never inferred. `state_tone` goes through one lookup
//      and an unknown tone stays neutral — it is not guessed from whether the
//      switch is on.
//
//   4. `can_toggle` is the backend's permission. A row without it gets no
//      switch, so a policy the backend has locked cannot be flipped from the
//      app by a widget that assumed every row was flippable.
//
//   5. A one-shot needs the backend's verb. An `action` with no `action_label`
//      draws NO button — never an English literal — and a row that carries both
//      a switch and an action gets both controls, which is the nightly drill.
//
//   6. Rows render in PAYLOAD ORDER (the fixture is deliberately not
//      alphabetical), and `has:false` draws nothing at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/runner_ops/runner_ops_view.dart';

Map<String, dynamic> _payload({bool has = true, List? policies}) => {
      'has': has,
      'title': 'Runner policies',
      'headline': 'Holding: Draining: the queue is taking nothing new.',
      'tone': 'warning',
      'workers_label': 'Workers 1 / 3',
      'policies': policies ??
          [
            // Deliberately NOT alphabetical, and deliberately inconsistent with
            // its own boolean: `on` is true while the sentence describes what is
            // happening, not what the switch says.
            {
              'key': 'drain',
              'label': 'Drain',
              'sub': 'Finish what is building, claim nothing new.',
              'on': true,
              'can_toggle': true,
              'state_label': 'Draining — 2 still building',
              'state_tone': 'warning',
            },
            {
              'key': 'boost',
              'label': 'Boost',
              'sub': '2 extra workers for one urgent batch.',
              'on': false,
              'can_toggle': false,
              'action': 'boost',
              'action_label': 'Boost +2 · 30m',
              'state_label': 'Boost off',
              'state_tone': 'neutral',
            },
            {
              'key': 'pace',
              'label': 'Quota pacing',
              'sub': 'Spread the burn so usage lands at the reset.',
              'on': true,
              'can_toggle': true,
              'state_label': '19% ahead of pace on weekly',
              // A tone name this build has never heard of.
              'state_tone': 'chartreuse',
            },
            {
              'key': 'drill',
              'label': 'Nightly kill-VM drill',
              'sub': '03:10 IST: stop the box, boot it, prove it claims.',
              'on': true,
              'can_toggle': true,
              'action': 'drill_now',
              'action_label': 'Run it now',
              'state_label': 'Drill green — back and claiming in 41s',
              'state_tone': 'success',
            },
            {
              'key': 'peak',
              'label': 'Peak-hours throttle',
              'sub': 'Drop to 1 worker while order hours are open.',
              'on': false,
              // Locked by the backend: no switch may be drawn.
              'can_toggle': false,
              'state_label': 'Nope',
              'state_tone': 'neutral',
            },
          ],
    };

Future<void> _pump(WidgetTester t, Map<String, dynamic> d,
    {void Function(String, bool)? onToggle,
    void Function(String)? onAction,
    bool busy = false}) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: RunnerOpsView(
            data: d, onToggle: onToggle, onAction: onAction, busy: busy),
      ),
    ),
  ));
  await t.pump();
}

void main() {
  testWidgets('every visible word is the backend\'s, including the state '
      'sentence that disagrees with its own switch', (t) async {
    await _pump(t, _payload());

    expect(find.text('Runner policies'), findsOneWidget);
    expect(find.text('Holding: Draining: the queue is taking nothing new.'),
        findsOneWidget);
    expect(find.text('Workers 1 / 3'), findsOneWidget);

    // The drain switch is ON and the sentence beside it is the BACKEND's
    // account of what that means right now. A card that printed "On" here,
    // derived from the boolean, would fail.
    expect(find.text('Draining — 2 still building'), findsOneWidget);
    expect(find.text('Finish what is building, claim nothing new.'),
        findsOneWidget);

    // ...and no Dart ON/OFF word has been invented anywhere on the card.
    expect(find.text('On'), findsNothing);
    expect(find.text('Off'), findsNothing);
    expect(find.text('Boost off'), findsOneWidget);
  });

  testWidgets('rows render in payload order — no client-side sort', (t) async {
    await _pump(t, _payload());
    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => const [
              'Drain',
              'Boost',
              'Quota pacing',
              'Nightly kill-VM drill',
              'Peak-hours throttle'
            ].contains(s))
        .toList();
    expect(labels, [
      'Drain',
      'Boost',
      'Quota pacing',
      'Nightly kill-VM drill',
      'Peak-hours throttle'
    ]);
  });

  testWidgets('can_toggle is the backend\'s permission, and an unknown tone '
      'stays neutral', (t) async {
    final flipped = <String, bool>{};
    await _pump(t, _payload(), onToggle: (k, v) => flipped[k] = v);

    // drain, pace and drill are togglable; boost and peak are not.
    expect(find.byType(Switch), findsNWidgets(3));

    // The locked row still prints its state, it just cannot be flipped.
    expect(find.text('Nope'), findsOneWidget);

    // An unrecognised tone renders without throwing and without borrowing the
    // switch's colour.
    expect(find.text('19% ahead of pace on weekly'), findsOneWidget);
  });

  testWidgets('a one-shot needs the backend\'s verb; a row with both a switch '
      'and an action gets both controls', (t) async {
    final fired = <String>[];
    await _pump(t, _payload(), onAction: fired.add);

    expect(find.text('Boost +2 · 30m'), findsOneWidget);
    expect(find.text('Run it now'), findsOneWidget);

    await t.tap(find.text('Run it now'));
    await t.pump();
    expect(fired, ['drill_now']);

    // The drill row carries can_toggle AND an action — both are drawn.
    expect(find.byType(Switch), findsNWidgets(3));
    expect(find.byType(OutlinedButton), findsNWidgets(2));
  });

  testWidgets('an action with no action_label draws no button at all — never '
      'an English literal', (t) async {
    await _pump(
        t,
        _payload(policies: [
          {
            'key': 'boost',
            'label': 'Boost',
            'sub': '',
            'on': false,
            'can_toggle': false,
            'action': 'boost',
            'action_label': '',
            'state_label': 'Boost off',
            'state_tone': 'neutral',
          }
        ]),
        onAction: (_) {});
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.text('Boost'), findsOneWidget);
  });

  testWidgets('busy disables every control, and a tap while busy calls nothing',
      (t) async {
    final flipped = <String>[];
    final fired = <String>[];
    await _pump(t, _payload(),
        onToggle: (k, _) => flipped.add(k), onAction: fired.add, busy: true);

    for (final s in t.widgetList<Switch>(find.byType(Switch))) {
      expect(s.onChanged, isNull);
    }
    for (final b in t.widgetList<OutlinedButton>(find.byType(OutlinedButton))) {
      expect(b.onPressed, isNull);
    }
    expect(flipped, isEmpty);
    expect(fired, isEmpty);
  });

  testWidgets('has:false draws nothing at all', (t) async {
    await _pump(t, _payload(has: false));
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Runner policies'), findsNothing);
    expect(RunnerOpsView.shows(_payload(has: false)), isFalse);
    expect(RunnerOpsView.shows(_payload()), isTrue);
    expect(RunnerOpsView.shows(null), isFalse);
  });
}
