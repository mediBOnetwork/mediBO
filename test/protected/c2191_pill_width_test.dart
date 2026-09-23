// CMD #2191 — the header pill's WIDTH is its words, and the words fit the phone.
//
// Om, on #1531: the pill read "Ordering clo…". Three separate causes, and this
// file holds all three down:
//
//   1. THE ROW SPLIT ITS FREE SPACE. shell_mobile_chrome had a
//      Flexible(loose) pill beside a Spacer(), and a Row divides what is left
//      between its flex children — so the pill was offered HALF the free width
//      (116 of 233 dp on a 360 dp phone) and ellipsised inside it while the
//      space next to it stayed empty. One flex child now: Expanded, with the
//      pill left-aligned inside it.
//   2. THE PILL EXPANDED TO WHATEVER IT WAS OFFERED. Its AnimatedContainer
//      carried `alignment:`, and a Container that is given an alignment fills
//      the width it is offered instead of hugging its child. So the pill was
//      never its text — it was its slot, with the text clipped inside.
//   3. THE SENTENCE WAS LONGER THAN THE PHONE. The widest line the backend can
//      send is 203.9 px in DMSans 600 @14 — 241.9 px of pill with the dot, its
//      gap and pad_x. A 320 dp row leaves 193 px. No layout makes that fit, so
//      the WORDS change: header_status_pill() takes the width the app reports
//      (p_w) and answers with pill.copy.narrow's wording below
//      narrow.max_screen_w. That decision is SQL's; Dart only reports a number.
//
// The last group is the proof Om asked for — every state, at 320 · 360 · 412 ·
// 480, with no ellipsis — measured in the app's real font against the real
// header arithmetic, so it is a gate and not a screenshot.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/order_hours_pill.dart';
import 'package:pharma_b2b/utils/render_log.dart';

String _src(String path) => File(path).readAsStringSync();

/// The one migration that owns the narrow wording and the breakpoint.
const String _migration =
    'supabase/migrations/20261011120000_cmd2191_pill_dynamic_width.sql';

/// The live `pill.copy.style` geometry the pill is drawn with.
const double _padX = 12, _dotSize = 8, _dotGap = 6, _maxW = 270, _minW = 120;

/// The header row's own furniture, from shell_style(): the shell inset on each
/// side, the 49 dp mark, the 10 dp gap after it and the 40 dp bell box.
const double _furniture = 14 * 2 + 49 + 10 + 40;

/// What a pill needs to show [textWidth] without ellipsising.
double _pillFor(double textWidth) => textWidth + _padX * 2 + _dotSize + _dotGap;

Map<String, dynamic> _pill({
  List<String> lines = const ['Open now', 'Opens in 45 min', 'Order now'],
  Map<String, dynamic>? style,
}) =>
    <String, dynamic>{
      'show': true,
      'state': 'open',
      'scope': 'zone',
      'tier': 'narrow',
      'lines': [
        for (int i = 0; i < lines.length; i++)
          {'kind': ['status', 'time', 'action'][i], 'text': lines[i]},
      ],
      'hold_ms': 3000,
      'roll_ms': 400,
      'label': lines.join(' · '),
      'pulse': false,
      'style': style ??
          const {
            'bg': '#D1FAE5',
            'fg': '#065F46',
            'dot': '#065F46',
            'height': 32,
            'radius': 16,
            'text': 14,
            'pad_x': _padX,
            'dot_size': _dotSize,
            'min_w': _minW,
            'max_w': _maxW,
          },
    };

/// The pill inside the room a [width] dp header row actually leaves it —
/// Expanded + left Align, exactly as _CustomerHeaderRow builds it.
Future<void> _inRow(WidgetTester t, Map<String, dynamic> pill,
    {required double width}) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            const SizedBox(width: 49, height: 49),
            const SizedBox(width: 10),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: OrderHoursPill(pill: pill, sheet: const {}, rolls: false),
              ),
            ),
            const SizedBox(width: 40, height: 40),
          ]),
        ),
      ),
    ),
  ));
  await t.pump();
  // The width travels with the roll (AnimatedSize), so let it arrive.
  await t.pump(const Duration(milliseconds: 500));
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('1 — the pill is its words, never a slot', () {
    testWidgets('a short line makes a narrower pill than a long one',
        (t) async {
      await _inRow(t, _pill(lines: const ['Hi']), width: 412);
      final small = t.getSize(find.byType(OrderHoursPill)).width;
      await _inRow(t, _pill(lines: const ['Ordering is open now']), width: 412);
      final big = t.getSize(find.byType(OrderHoursPill)).width;
      expect(big, greaterThan(small),
          reason: 'the pill is the same width whatever it says');
    });

    testWidgets('it does not fill the room it is offered', (t) async {
      await _inRow(t, _pill(lines: const ['Hi']), width: 480);
      final w = t.getSize(find.byType(OrderHoursPill)).width;
      expect(w, lessThan(480 - _furniture),
          reason: 'the pill expanded into its slot instead of hugging');
    });

    testWidgets('min_w is the floor and max_w is the ceiling — of the WHOLE '
        'pill, padding included', (t) async {
      await _inRow(t, _pill(lines: const ['.']), width: 480);
      expect(t.getSize(find.byType(OrderHoursPill)).width, _minW,
          reason: 'a tiny line fell through min_w');
      await _inRow(
          t,
          _pill(lines: const ['A sentence far longer than the pill may ever be']),
          width: 1280);
      expect(t.getSize(find.byType(OrderHoursPill)).width, _maxW,
          reason: 'max_w is not the width a reader can measure');
    });

    testWidgets('the ceiling is the payload\'s, not a number in Dart',
        (t) async {
      final p = _pill(lines: const [
        'A sentence far longer than the pill is'
      ], style: <String, dynamic>{
        'bg': '#D1FAE5',
        'fg': '#065F46',
        'dot': '#065F46',
        'height': 32,
        'radius': 16,
        'text': 14,
        'pad_x': _padX,
        'dot_size': _dotSize,
        'min_w': 40,
        'max_w': 180,
      });
      await _inRow(t, p, width: 1280);
      expect(t.getSize(find.byType(OrderHoursPill)).width, 180,
          reason: 'the pill stopped taking its ceiling from style');
    });

    test('no fixed width is written in the pill or the header row', () {
      final pill = _src('lib/widgets/order_hours_pill.dart');
      expect(RegExp(r'width:\s*\d').hasMatch(pill), isFalse,
          reason: 'a hard-coded width came back into the pill');
      // A Container with an alignment fills its slot — cause 2 above.
      expect(RegExp(r'alignment:\s*Alignment\.centerLeft,\s*\n\s*padding:')
          .hasMatch(pill), isFalse,
          reason: 'the pill box is expanding to its slot again');
      final row = _src('lib/screens/shell/shell_mobile_chrome.dart');
      expect(row.contains('const Expanded(\n                child: Align('), isTrue,
          reason: 'the pill lost the whole of the row\'s free space');
      expect(
          RegExp(r'_HeaderFade\(child: OrderHoursHeaderPill\(\)\),\s*\n\s*\),\s*\n\s*\),\s*\n\s*const Spacer\(\)')
              .hasMatch(row),
          isFalse,
          reason: 'the Spacer is taking half the free space again');
    });
  });

  group('2 — the width follows the roll', () {
    testWidgets('it grows into a longer line and shrinks back', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: OrderHoursPill(
                pill: _pill(lines: const ['Hi', 'A longer line', 'Go']),
                sheet: const {}),
          ),
        ),
      ));
      await t.pump();
      final w1 = t.getSize(find.byType(OrderHoursPill)).width;
      await t.pump(const Duration(milliseconds: 3000));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      final w2 = t.getSize(find.byType(OrderHoursPill)).width;
      expect(w2, greaterThan(w1), reason: 'the pill did not grow');
      await t.pump(const Duration(milliseconds: 3000));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(t.getSize(find.byType(OrderHoursPill)).width, lessThan(w2),
          reason: 'the pill did not shrink back onto the short line');
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  group('3 — the wording tier is the backend\'s', () {
    test('the app reports its width and decides nothing with it', () {
      final model = _src('lib/models/order_hours_model.dart');
      expect(model.contains("'p_w'"), isTrue,
          reason: 'the app stopped telling the backend how wide it is');
      expect(model.contains('p_zone'), isFalse);
      // No breakpoint and no tier LOGIC in Dart: the number belongs to SQL,
      // and so does the choice it makes.
      for (final f in const [
        'lib/models/order_hours_model.dart',
        'lib/widgets/order_hours_pill.dart',
        'lib/screens/shell/shell_mobile_chrome.dart',
      ]) {
        final src = _src(f);
        expect(src.contains('max_screen_w'), isFalse,
            reason: '$f started holding the breakpoint');
        expect(RegExp(r"(==|<|>)=?\s*'?narrow'?").hasMatch(src), isFalse,
            reason: '$f started deciding the wording tier');
      }
      final pill = _src('lib/widgets/order_hours_pill.dart');
      expect(pill.contains("c2191_pill_tier"), isTrue,
          reason: 'the tier stopped being visible in the render log');
    });

    test('the tier the widget prints is the payload\'s, verbatim', () {
      expect(OrderHoursPill.linesOf(_pill(lines: const ['A', 'B', 'C'])),
          const ['A', 'B', 'C']);
    });
  });

  group('4 — every state fits, at 320 · 360 · 412 · 480', () {
    // The wording the backend sends below the breakpoint, read from the
    // migration that owns it — so a future edit to the copy is measured here
    // rather than discovered on a phone.
    late List<String> narrow;
    late int breakpoint;

    setUpAll(() async {
      final loader = FontLoader('DMSans');
      for (final w in const ['400', '500', '600', '700']) {
        loader.addFont(Future.value(
            ByteData.sublistView(File('assets/fonts/DMSans-$w.ttf').readAsBytesSync())));
      }
      await loader.load();
      final sql = _src(_migration);
      final block = sql.substring(sql.indexOf("'narrow', jsonb_build_object"),
          sql.indexOf('-- ── 2.'));
      narrow = RegExp(r"'([^']{3,})'")
          .allMatches(block)
          .map((m) => m.group(1)!)
          // The keys and the SQL words around them are not sentences.
          .where((s) => s.contains(' ') || s.length > 8)
          .where((s) => !s.contains('_') && !s.startsWith('jsonb'))
          .map((s) => s.replaceAll('{n}', '45'))
          .toSet()
          .toList();
      breakpoint = int.parse(
          RegExp(r"'max_screen_w',\s*(\d+)").firstMatch(sql)!.group(1)!);
    });

    double _w(String t) {
      final tp = TextPainter(
        text: TextSpan(
          text: t,
          style: const TextStyle(
              fontFamily: 'DMSans',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp.width;
    }

    test('the narrow wording is real wording, not stubs', () {
      expect(narrow.length, greaterThan(20),
          reason: 'the narrow tier lost its copy');
      for (final s in narrow) {
        expect(s.trim(), isNotEmpty);
      }
    });

    test('every narrow line fits a 320 dp phone, whole', () {
      for (final s in narrow) {
        expect(_pillFor(_w(s)), lessThanOrEqualTo(320 - _furniture),
            reason: '"$s" ellipsises at 320 dp');
      }
    });

    test('every narrow line fits a 360 dp phone, whole', () {
      for (final s in narrow) {
        expect(_pillFor(_w(s)), lessThanOrEqualTo(360 - _furniture),
            reason: '"$s" ellipsises at 360 dp');
      }
    });

    test('the breakpoint is where the FULL wording starts fitting', () {
      // The longest line the full tier can send today, from pill.copy on live.
      const longest = 'We are packing today’s orders';
      expect(_pillFor(_w(longest)), lessThanOrEqualTo(breakpoint - _furniture),
          reason: 'the full wording still ellipsises at the breakpoint');
      expect(_pillFor(_w(longest)), greaterThan(360 - _furniture),
          reason: 'the narrow tier is being used where the full one would fit');
      expect(_pillFor(_w(longest)), lessThanOrEqualTo(_maxW),
          reason: 'max_w clips the longest full line before the row does');
    });

    test('412 and 480 carry the full wording with room to spare', () {
      const longest = 'We are packing today’s orders';
      for (final width in const [412.0, 480.0]) {
        expect(width, greaterThanOrEqualTo(breakpoint.toDouble()),
            reason: '$width would be handed the narrow tier');
        expect(_pillFor(_w(longest)),
            lessThanOrEqualTo(width - _furniture),
            reason: 'the full wording ellipsises at $width dp');
      }
    });
  });
}
