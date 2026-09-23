// CMD #2187 — the header pill: three lines, one motion at a time.
//
// What this file holds down, and why each line of it cost something:
//
//   1. ALWAYS THREE LINES, and they are the BACKEND's. The pill reads
//      `lines[]` in payload order and prints each one verbatim; a payload
//      carrying only `label` (an old cache) is ONE line and never rolls.
//   2. THE ROLL IS THE BACKEND'S CLOCK. hold_ms and roll_ms come from the
//      response — not a Duration written here — and the pill's width does not
//      change between lines, because every line is measured at all times.
//   3. STYLE IS THE STATE'S. height, radius and text size arrive merged into
//      `style{}`, so the pill can change colour AND size mid-cycle. The shell
//      tokens are only the fallback for what the payload leaves out.
//   4. ONE MOTION. `shell_style().motion.one_at_a_time` +
//      `search.placeholder_rotate_when` decide who moves. Header row fully on
//      screen → the pill rolls and the placeholder is frozen. Header row
//      fully gone → the reverse. MID-SLIDE NEITHER MOVES — that gap is the
//      handover, and it is the thing that read as broken before this change.
//   5. NO ENGLISH, NO CLOCK, NO ZONE IN DART. The pill file names no state,
//      no stage, no time wording and no zone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/shell_motion.dart';
import 'package:pharma_b2b/widgets/order_hours_pill.dart';
import 'package:pharma_b2b/utils/render_log.dart';

import 'dart:io';

String _src(String path) => File(path).readAsStringSync();

/// A #2187 payload: exactly three lines, merged style, the roll's own clock.
Map<String, dynamic> _pill({
  String state = 'closing_soon',
  String scope = 'zone',
  List<String> lines = const ['Open', '40 minutes left', 'Order fast'],
  Map<String, dynamic>? style,
  int holdMs = 3000,
  int rollMs = 400,
}) =>
    <String, dynamic>{
      'show': true,
      'state': state,
      'scope': scope,
      'lines': [
        for (int i = 0; i < lines.length; i++)
          {'kind': ['status', 'time', 'action'][i], 'text': lines[i]},
      ],
      'hold_ms': holdMs,
      'roll_ms': rollMs,
      'label': lines.join(' · '),
      'pulse': false,
      'style': style ??
          const {
            'bg': '#FEF3C7',
            'fg': '#92400E',
            'dot': '#92400E',
            'height': 40,
            'radius': 20,
            'text': 14,
            'pad_x': 12,
            'dot_size': 8,
            'min_w': 120,
            'max_w': 210,
          },
    };

Future<void> _mount(WidgetTester t, Map<String, dynamic> pill,
        {bool? rolls = true}) =>
    t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: OrderHoursPill(pill: pill, sheet: const {}, rolls: rolls),
        ),
      ),
    ));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  tearDown(() {
    shellHeaderShown.value = 1;
    shellPillCanRoll.value = false;
    shellMotionPolicy.value = const {};
  });

  group('1 — three lines, the backend\'s, in the backend\'s order', () {
    test('linesOf reads lines[] verbatim and drops nothing that has text', () {
      expect(
        OrderHoursPill.linesOf(_pill()),
        ['Open', '40 minutes left', 'Order fast'],
      );
    });

    test('a payload with only label is ONE line — an old cache still paints',
        () {
      expect(OrderHoursPill.linesOf({'label': 'Open till 9:30 pm'}),
          ['Open till 9:30 pm']);
      expect(OrderHoursPill.linesOf(const {'label': ''}), isEmpty);
    });

    test('an empty line is dropped, never printed as a blank row', () {
      final p = _pill(lines: const ['Closed', 'Tomorrow', '']);
      expect(OrderHoursPill.linesOf(p), ['Closed', 'Tomorrow']);
    });

    testWidgets('every line is mounted, so the pill never changes width',
        (t) async {
      await _mount(t, _pill());
      await t.pump();
      // All three are in the tree at all times: that is what makes the width
      // the widest line's, on every frame of the cycle.
      for (final s in const ['Open', '40 minutes left', 'Order fast']) {
        expect(find.text(s), findsOneWidget, reason: '$s left the pill');
      }
      final w1 = t.getSize(find.byType(OrderHoursPill)).width;
      await t.pump(const Duration(milliseconds: 3000));
      await t.pump(const Duration(milliseconds: 400));
      expect(t.getSize(find.byType(OrderHoursPill)).width, w1,
          reason: 'the pill shrank mid-roll');
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('2 — the roll runs on the backend\'s clock', () {
    testWidgets('the incoming line is opaque only after hold + roll',
        (t) async {
      await _mount(t, _pill(holdMs: 3000, rollMs: 400));
      await t.pump();
      double op(String s) => t
          .widget<Opacity>(find.ancestor(
              of: find.text(s), matching: find.byType(Opacity)).first)
          .opacity;
      expect(op('Open'), 1, reason: 'line 1 is what the pill opens on');
      expect(op('40 minutes left'), 0);
      await t.pump(const Duration(milliseconds: 3000)); // the hold elapses
      await t.pump(const Duration(milliseconds: 400)); // the roll completes
      expect(op('40 minutes left'), 1, reason: 'line 2 did not arrive');
      expect(op('Open'), 0, reason: 'line 1 did not leave');
      await t.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a single-line pill never rolls at all', (t) async {
      await _mount(t, {'label': 'Closed', 'style': const {}});
      await t.pump(const Duration(seconds: 10));
      expect(find.text('Closed'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });

    test('no Duration of the roll is written in Dart', () {
      final src = _src('lib/widgets/order_hours_pill.dart');
      expect(src.contains("_ms('hold_ms'"), isTrue);
      expect(src.contains("_ms('roll_ms'"), isTrue);
      expect(RegExp(r'Duration\(milliseconds: 3000\)').hasMatch(src), isFalse,
          reason: 'the hold was hardcoded back into the pill');
    });
  });

  group('3 — style is the state\'s, tokens are only the fallback', () {
    testWidgets('height and radius come from style{}', (t) async {
      await _mount(
          t,
          _pill(style: const {
            'bg': '#EFF6FF',
            'fg': '#1E40AF',
            'dot': '#1E40AF',
            'height': 52,
            'radius': 26,
            'text': 16,
          }));
      await t.pump();
      final box = t.widget<AnimatedContainer>(
          find.descendant(
              of: find.byType(OrderHoursPill),
              matching: find.byType(AnimatedContainer)).first);
      expect(box.constraints?.maxHeight, 52,
          reason: 'the state could not change the pill\'s size');
      await t.pumpWidget(const SizedBox.shrink());
    });

    test('the shell tokens are what the payload falls back to', () {
      final src = _src('lib/widgets/order_hours_pill.dart');
      expect(src.contains("_dim('height') ?? Ds.touch.headerPill"), isTrue);
      expect(src.contains('BorderRadius.circular(Ds.header.pillRadius)'), isTrue);
      // Om, on #1523 — and still true: the pill, the logo tile and the search
      // box are one size, at one corner.
      expect(Ds.touch.headerPill, 40);
      expect(Ds.header.pillRadius, 20);
      expect(Ds.touch.headerPill, Ds.touch.headerTile);
      expect(Ds.header.pillRadius, Ds.shell.boxRadius);
    });
  });

  group('4 — one motion at a time', () {
    setUp(() {
      shellMotionPolicy.value = const {
        'one_at_a_time': true,
        'placeholder_rotate_when': 'header_hidden',
      };
    });

    test('header row fully on screen: the pill rolls, the word is frozen', () {
      shellPillCanRoll.value = true;
      shellHeaderShown.value = 1;
      expect(pillMayRoll, isTrue);
      expect(placeholderMayRotate, isFalse);
    });

    test('header row fully gone: the word rotates, the pill does not', () {
      shellPillCanRoll.value = true;
      shellHeaderShown.value = 0;
      expect(pillMayRoll, isFalse);
      expect(placeholderMayRotate, isTrue);
    });

    test('MID-SLIDE NEITHER MOVES — the handover is a gap, not a swap', () {
      shellPillCanRoll.value = true;
      for (final v in const [0.01, 0.25, 0.5, 0.75, 0.99]) {
        shellHeaderShown.value = v;
        expect(pillMayRoll, isFalse, reason: 'the pill rolled during the slide');
        expect(placeholderMayRotate, isFalse,
            reason: 'the placeholder started before the row had gone');
      }
    });

    test('no pill to collide with: the word keeps its own clock', () {
      shellPillCanRoll.value = false;
      shellHeaderShown.value = 1;
      expect(placeholderMayRotate, isTrue);
    });

    test('one_at_a_time=false hands both their clocks back, with no deploy',
        () {
      shellMotionPolicy.value = const {
        'one_at_a_time': false,
        'placeholder_rotate_when': 'header_hidden',
      };
      shellPillCanRoll.value = true;
      shellHeaderShown.value = 0.4;
      expect(pillMayRoll, isTrue);
      expect(placeholderMayRotate, isTrue);
    });

    testWidgets('a rolling pill tells the gate it owns the motion', (t) async {
      expect(shellPillCanRoll.value, isFalse);
      await _mount(t, _pill(), rolls: null);
      await t.pump();
      expect(shellPillCanRoll.value, isTrue);
      await t.pumpWidget(const SizedBox.shrink());
      expect(shellPillCanRoll.value, isFalse,
          reason: 'a pill that left the screen still held the motion');
    });

    test('the pill reads its one AUTHOR, and names no zone doing it', () {
      // CHANGE #1527 shipped with the three lines correct in
      // header_status_pill() and WRONG on screen, because the live
      // order_hours_state() still reported #2147's one-line copy of the pill.
      // The model now asks the author itself, in parallel, and prefers it.
      final model = _src('lib/models/order_hours_model.dart');
      expect(model.contains("rpc('header_status_pill')"), isTrue,
          reason: 'the pill stopped asking its author');
      expect(model.contains("rpc('order_hours_state')"), isTrue,
          reason: 'the hours state lost its own door');
      expect(
          RegExp(r"rpc\('header_status_pill',\s*params").hasMatch(model), isFalse,
          reason: 'Dart started choosing the zone it is shown');
    });

    test('the band publishes the travel the gate reads', () {
      final src = _src('lib/screens/shell/shell_header_band.dart');
      expect(src.contains('shellHeaderShown.value'), isTrue,
          reason: 'the one-motion gate lost its only input');
      final search = _src('lib/widgets/search_surface.dart');
      expect(search.contains('placeholderMayRotate'), isTrue,
          reason: 'the placeholder stopped obeying the gate');
      final load = _src('lib/screens/shell/shell_tab_search.dart');
      expect(load.contains('shellMotionPublish('), isTrue,
          reason: 'the backend policy never reaches the gate');
    });
  });

  group('5 — no English, no clock, no zone in Dart', () {
    test('the pill names no state, no stage and no time wording', () {
      final src = _src('lib/widgets/order_hours_pill.dart');
      for (final banned in const [
        "'Open'",
        "'Closed'",
        "'Order now'",
        "'Order fast'",
        "'Last chance'",
        "'Register to order'",
        "'Tomorrow'",
        'minutes left',
        'Raipur',
        'HH:mm',
        'DateFormat',
      ]) {
        expect(src.contains(banned), isFalse,
            reason: 'the pill started writing its own copy: $banned');
      }
    });

    test('the gate itself decides no words either', () {
      final src = _src('lib/shell_motion.dart');
      expect(src.contains('DateFormat'), isFalse);
      // The one string it may know is the backend's own token name.
      expect(src.contains("'header_hidden'"), isTrue);
    });
  });
}
