// PROTECTED — CMD #1824.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the Build intelligence contract, never to make an
// unrelated change go green.
//
// The defect this exists to retire: a dashboard that invents confidence. The
// whole point of Build intelligence is that its numbers are the registry's
// numbers — the estimate error, the rework share, a cause's before/after
// count, the tokens a waste class is blamed for. The moment Dart divides,
// rounds, compares a count to a threshold or decides a tone, the screen and
// the SQL can disagree and nobody can tell which is lying.
//
// So the fixture is deliberately INCONSISTENT WITH ITSELF: the accuracy tile
// says "1.31×" while its own sub-line names a different agent baseline, the
// rework tile prints 36.1% over "140 of 388" (which is not 36.1%), a cause row
// claims "20×" beside "before: 3 · after: 9", and a waste class says "2.7% of
// the window" against tokens that are not 2.7% of anything. Every one of those
// is printed verbatim. A screen that recomputed even one of them fails here.
//
// What this holds down:
//
//   1. IT IS A PRINTER. Title, window chips, tile labels/values/subs, section
//      titles, every row label/value/sub/chip and the footnote are payload
//      strings.
//   2. PAYLOAD ORDER. Tiles, sections and rows render as they arrive; the
//      fixture is not sorted by size, severity or alphabet.
//   3. ABSENCE IS ABSENCE. A row without `sub` gets no sub-line and no dash; a
//      tile with has:false draws nothing; has:false on the payload draws
//      nothing at all.
//   4. TONE IS ONE LOOKUP. An unknown tone name stays neutral rather than
//      throwing or defaulting to red.
//   5. FORWARD COMPAT. A section kind this build has never seen is skipped in
//      silence — not drawn as an empty card with a heading over it.
//   6. THE TAP CARRIES THE ID. Apply sends the proposal's own id and the PIN
//      the sheet collected; the backend's `message` is what the toast prints.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/build_intelligence_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _payload({List? tiles, List? sections, bool has = true}) => {
      'ok': true,
      'has': has,
      'title': 'Build intelligence',
      'subtitle': 'What the registry has learned, and what it is now enforcing.',
      'window_label': 'last 30 days',
      'since_label': 'since 07 Aug 14:46 IST',
      'window_hint':
          'Window: the last 30 days. A metric with fewer than 5 samples says so instead of printing a number.',
      'pin_hint': 'Safety PIN',
      'retry_label': 'Retry',
      'tiles': tiles ??
          [
            // Deliberately at odds with its own sub-line: the value names a
            // 1.31× error while the sub quotes a baseline that is not what
            // 1.31 is measured against. Printed verbatim, both of them.
            {
              'key': 'accuracy',
              'has': true,
              'label': 'Estimate error — calibrated',
              'value': '1.31× estimate/actual',
              'sub':
                  'mean absolute error 9m 12s · typical command 1.4× off · 7 calibrated finish(es) · agents guessed 2.36× · baseline 2.5×',
              'tone': 'success',
            },
            // 140 of 388 is 36.1% — but the value says 41.9%. Verbatim.
            {
              'key': 'rework',
              'has': true,
              'label': 'Rework',
              'value': '41.9%',
              'sub':
                  '140 of 388 commands needed a retry, a resume or a second QA round · trending down from 44.0%',
              'tone': 'danger',
            },
            // has:false — must draw NOTHING, not an empty tile.
            {
              'key': 'hidden',
              'has': false,
              'label': 'HIDDEN TILE LABEL',
              'value': 'HIDDEN TILE VALUE',
              'tone': 'success',
            },
          ],
      'sections': sections ??
          [
            {
              'key': 'causes',
              'kind': 'rows',
              'title': 'Repeat causes',
              'sub': 'A cause seen 3× in one area becomes a constraint.',
              'empty_label': 'No cause has repeated in one area yet.',
              'rows': [
                // "20×" beside before 3 / after 9 — not arithmetic, a print.
                {
                  'id': 53,
                  'label': 'Heartbeat went stale · storefront',
                  'value': '20×',
                  'before_label': 'before: 3',
                  'after_label': 'after: 9',
                  'enforcing': true,
                  'enforcing_label': 'enforcing · still recurring — rewrite it',
                  'tone': 'danger',
                  'sub': 'constraint #53 · reached 4 build(s) since 06 Sep',
                  'text': 'Heartbeat every 60 s with a log tail.',
                },
                // No sub, no text, unknown tone: neutral, no dash.
                {
                  'label': 'ETA frozen while tokens climbed · delivery',
                  'value': '14×',
                  'before_label': 'before: 14',
                  'after_label': 'after: 0',
                  'enforcing': true,
                  'enforcing_label': 'enforcing · proven — 0 since',
                  'tone': 'plaid',
                },
                {
                  'label': 'Waited on a file lease · devops',
                  'value': '2×',
                  'enforcing': false,
                  'enforcing_label': 'not enforced (2 of 3)',
                  'tone': 'neutral',
                  'sub': 'last seen 05 Sep',
                },
              ],
            },
            {
              'key': 'waste',
              'kind': 'rows',
              'title': 'Waste classes',
              'sub': 'Tokens attributable to each class over the window.',
              'empty_label': 'No spend could be classified yet.',
              'rows': [
                // 12.2M is not 2.7% of anything in this fixture. Verbatim.
                {
                  'key': 'restart_after_loss',
                  'label': 'Restart after loss',
                  'value': '12.2M tokens · 17 command(s) · 2.7% of the window',
                  'knob_label': 'knob: worker_pool.liveness.disconnect_grace_min',
                  'tone': 'info',
                  'sub': 'under the 5% proposal threshold — measured, not proposed',
                },
                {
                  'key': 'waiting',
                  'label': 'Waiting',
                  'value': 'nothing in this class',
                  'knob_label': 'knob: worker_pool.wait_gate.poll_s',
                  'tone': 'success',
                },
              ],
            },
            // A kind this build has never heard of: skipped whole, in silence.
            {
              'key': 'mystery',
              'kind': 'hologram',
              'title': 'MYSTERY SECTION TITLE',
              'empty_label': 'MYSTERY EMPTY LABEL',
              'rows': [
                {'label': 'MYSTERY ROW', 'value': 'MYSTERY VALUE'},
              ],
            },
            {
              'key': 'proposals',
              'kind': 'proposals',
              'title': 'Open proposals',
              'sub': 'Nothing here changes on its own.',
              'empty_label': 'No proposal is open.',
              'rows': [
                {
                  'id': 7,
                  'label': 'Re-planning → worker_pool.steps_watchdog.stale_min',
                  'value': '12 → 8',
                  'sub': '116.2M tokens over 57 command(s) · A checklist that goes stale is re-planned from scratch.',
                  'tone': 'warning',
                  'can_apply': true,
                  'apply_label': 'Apply (PIN)',
                  'dismiss_label': 'Dismiss',
                  'opened_label': 'opened 06 Sep 14:46',
                },
              ],
            },
            {
              'key': 'lessons',
              'kind': 'rows',
              'title': 'Lessons health',
              'sub': '277 lessons · 0 dead weight · 0 not working.',
              'empty_label':
                  'No lesson qualifies yet. Reads have been tracked since 06 Sep.',
              'rows': [],
            },
          ],
      'footnote':
          'Estimate error is greatest(estimate, actual) ÷ least(estimate, actual) per command, averaged; 1.0× is perfect.',
    };

Future<void> _pump(WidgetTester t, Map<String, dynamic> payload,
    {Future<Map<String, dynamic>> Function(int id, String pin)? applier}) async {
  // A tall surface so the whole list is built: this is a payload-order and
  // payload-string test, and a section below an 800px fold would look like a
  // section the screen refused to draw.
  t.view.physicalSize = const Size(1200, 5000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: BuildIntelligenceScreen(
        loader: () async => payload,
        applier: applier ?? (id, pin) async => {'ok': true, 'message': 'x'},
        dismisser: (id) async => {'ok': true, 'message': 'x'}),
  ));
  await t.pumpAndSettle();
}

double _top(WidgetTester t, String text) =>
    t.getTopLeft(find.text(text).first).dy;

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('it is a printer: every string is the payload, even when it disagrees with itself',
      (t) async {
    await _pump(t, _payload());
    // header + window
    expect(find.text('Build intelligence'), findsOneWidget);
    expect(find.text('last 30 days'), findsOneWidget);
    expect(find.text('since 07 Aug 14:46 IST'), findsOneWidget);
    expect(find.textContaining('fewer than 5 samples'), findsOneWidget);
    // tiles — the value AND the sub that contradicts it
    expect(find.text('1.31× estimate/actual'), findsOneWidget);
    expect(find.textContaining('agents guessed 2.36×'), findsOneWidget);
    expect(find.text('41.9%'), findsOneWidget);
    expect(find.textContaining('140 of 388'), findsOneWidget);
    expect(find.text('36.1%'), findsNothing);
    // cause row: value, before/after chips, enforcing chip, sub, text
    expect(find.text('20×'), findsOneWidget);
    expect(find.text('before: 3'), findsOneWidget);
    expect(find.text('after: 9'), findsOneWidget);
    expect(find.text('enforcing · still recurring — rewrite it'), findsOneWidget);
    expect(find.textContaining('reached 4 build(s)'), findsOneWidget);
    expect(find.text('Heartbeat every 60 s with a log tail.'), findsOneWidget);
    // waste row: the percentage is printed, never derived
    expect(find.text('12.2M tokens · 17 command(s) · 2.7% of the window'),
        findsOneWidget);
    expect(find.text('knob: worker_pool.wait_gate.poll_s'), findsOneWidget);
    // proposal row
    expect(find.text('12 → 8'), findsOneWidget);
    expect(find.text('Apply (PIN)'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
    expect(find.text('opened 06 Sep 14:46'), findsOneWidget);
    // empty state is the backend's sentence
    expect(find.textContaining('Reads have been tracked since 06 Sep'),
        findsOneWidget);
    // footnote
    expect(find.textContaining('1.0× is perfect'), findsOneWidget);
  });

  testWidgets('tiles, sections and rows render in payload order', (t) async {
    await _pump(t, _payload());
    expect(_top(t, 'Estimate error — calibrated'), lessThan(_top(t, 'Rework')));
    expect(_top(t, 'Rework'), lessThan(_top(t, 'Repeat causes')));
    expect(_top(t, 'Repeat causes'), lessThan(_top(t, 'Waste classes')));
    expect(_top(t, 'Waste classes'), lessThan(_top(t, 'Open proposals')));
    expect(_top(t, 'Open proposals'), lessThan(_top(t, 'Lessons health')));
    // rows: the 2× row is LAST even though 2 < 14 < 20 would sort it first
    expect(_top(t, 'Heartbeat went stale · storefront'),
        lessThan(_top(t, 'ETA frozen while tokens climbed · delivery')));
    expect(_top(t, 'ETA frozen while tokens climbed · delivery'),
        lessThan(_top(t, 'Waited on a file lease · devops')));
    // waste: "Restart after loss" arrives before "Waiting" and stays there
    expect(_top(t, 'Restart after loss'), lessThan(_top(t, 'Waiting')));
  });

  testWidgets('absence is absence: no dash for a missing sub, has:false draws nothing',
      (t) async {
    await _pump(t, _payload());
    expect(find.text('—'), findsNothing);
    expect(find.text('HIDDEN TILE LABEL'), findsNothing);
    expect(find.text('HIDDEN TILE VALUE'), findsNothing);
    // the unknown section kind is skipped whole — not even its title
    expect(find.text('MYSTERY SECTION TITLE'), findsNothing);
    expect(find.text('MYSTERY ROW'), findsNothing);
    expect(find.text('MYSTERY EMPTY LABEL'), findsNothing);
  });

  testWidgets('has:false on the payload draws nothing at all', (t) async {
    await _pump(t, _payload(has: false));
    expect(find.text('Estimate error — calibrated'), findsNothing);
    expect(find.text('Repeat causes'), findsNothing);
    expect(find.text('last 30 days'), findsNothing);
  });

  testWidgets('an unknown tone stays neutral instead of throwing', (t) async {
    await _pump(t, _payload());
    // the 'plaid' row rendered, with its value and its enforcing chip
    expect(find.text('14×'), findsOneWidget);
    expect(find.text('enforcing · proven — 0 since'), findsOneWidget);
    final v = t.widget<Text>(find.text('14×'));
    final d = t.widget<Text>(find.text('2×'));
    // same colour as the explicitly neutral row — one lookup, no invention
    expect(v.style?.color, d.style?.color);
  });

  testWidgets('an empty section prints the backend empty label', (t) async {
    await _pump(t, _payload(sections: [
      {
        'key': 'causes',
        'kind': 'rows',
        'title': 'Repeat causes',
        'empty_label': 'No cause has repeated in one area yet — nothing is enforced.',
        'rows': [],
      },
    ]));
    expect(find.text('No cause has repeated in one area yet — nothing is enforced.'),
        findsOneWidget);
  });

  testWidgets('Apply carries the proposal id and the PIN; the toast is the backend message',
      (t) async {
    int? gotId;
    String? gotPin;
    await _pump(t, _payload(), applier: (id, pin) async {
      gotId = id;
      gotPin = pin;
      return {'ok': false, 'message': 'pool: PIN required (set your safety PIN first)'};
    });
    await t.tap(find.text('Apply (PIN)'));
    await t.pumpAndSettle();
    // the PIN sheet is up, titled with the backend's own apply label
    expect(find.byType(TextField), findsOneWidget);
    await t.enterText(find.byType(TextField), '4321');
    await t.tap(find.widgetWithText(FilledButton, 'Apply (PIN)').last);
    await t.pumpAndSettle();
    expect(gotId, 7);
    expect(gotPin, '4321');
    expect(find.text('pool: PIN required (set your safety PIN first)'),
        findsOneWidget);
  });
}
