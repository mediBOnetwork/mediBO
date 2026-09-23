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

/// The migration that owns the narrow wording (retired, kept as data).
const String _migration =
    'supabase/migrations/20261011120000_cmd2191_pill_dynamic_width.sql';

/// The migration that seeds `pill.copy` — the wording the pill prints.
const String _seedMigration =
    'supabase/migrations/20261011090000_cmd2187_header_pill_three_lines.sql';

/// The migration that switched the width breakpoint OFF (CMD #2191, Om).
const String _tierOffMigration =
    'supabase/migrations/20261011160000_cmd2191_pill_one_wording.sql';

/// The migration that shortened the three lines that did not fit a phone.
const String _rewordMigration =
    'supabase/migrations/20261011170000_cmd2191_one_wording_fits_phone.sql';

/// The live `pill.copy.style` geometry the pill is drawn with.
const double _padX = 12, _dotSize = 8, _dotGap = 6, _maxW = 270, _minW = 120;

/// The header row's own furniture, from shell_style(): the shell inset on each
/// side, the 49 dp mark, the 10 dp gap after it and the 40 dp bell box.
const double _furniture = 14 * 2 + 49 + 10 + 40;

/// What a pill needs to show [textWidth] without ellipsising.
double _pillFor(double textWidth) => textWidth + _padX * 2 + _dotSize + _dotGap;

Map<String, dynamic> _pill({
  List<String> lines = const [
    'Ordering is open',
    '45 minutes left to order',
    'Order now'
  ],
  Map<String, dynamic>? style,
}) =>
    <String, dynamic>{
      'show': true,
      'state': 'open',
      'scope': 'zone',
      'tier': 'full',
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
            'dot_gap': _dotGap,
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
        'dot_gap': _dotGap,
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

  group('4 — ONE wording, and it fits the phone', () {
    // CMD #2191 (Om, mid-build): "pill should show exact what backend gives"
    // — one set of words at every width. The narrow tier existed only because
    // the pill had a FIXED width; now that it hugs its line, the FULL wording
    // is the only wording, so the full wording is what has to fit a phone.
    //
    // Both halves are read from the migrations that own them, so a reworded
    // line or a re-enabled tier is measured here rather than found on a phone.
    late List<String> live; // every sentence the pill can still print
    late List<String> narrow; // the retired tier's copy, kept as data
    late int breakpoint;

    /// A sentence some later migration reworded away is no longer live copy.
    /// `replace(v::text, 'OLD', 'NEW')` — OLD is what stopped being printed.
    Set<String> _retired(Iterable<String> sources) {
      final out = <String>{};
      for (final src in sources) {
        for (final m in RegExp(r"replace\(\s*[^,()]*(?:\([^)]*\))?[^,]*,\s*'((?:[^']|'')+)'\s*,")
            .allMatches(src)) {
          out.add(m.group(1)!.replaceAll("''", "'"));
        }
      }
      return out;
    }

    List<String> _sentences(String block) => RegExp(r"'((?:[^']|'')+)'")
        // `--` lines are the migration's prose, never the pill's copy.
        .allMatches(block.split('\n').where((l) => !l.trimLeft().startsWith('--')).join('\n'))
        .map((m) => m.group(1)!.replaceAll("''", "'"))
        .where((s) => s.contains(' ') || s.length > 8)
        .where((s) => !s.contains('_') && !s.startsWith('jsonb'))
        .map((s) => s.replaceAll('{n}', '45'))
        .toSet()
        .toList();

    setUpAll(() async {
      final loader = FontLoader('DMSans');
      for (final w in const ['400', '500', '600', '700']) {
        loader.addFont(Future.value(
            ByteData.sublistView(File('assets/fonts/DMSans-$w.ttf').readAsBytesSync())));
      }
      await loader.load();

      final seed = _src(_seedMigration);
      final dyn = _src(_migration);
      final off = _src(_tierOffMigration);
      final reword = _src(_rewordMigration);

      // The seed's ONE statement: `insert … ('pill.copy', jsonb_build_object(`
      // up to the `on conflict` that closes it. Anything after that belongs to
      // another key or to a function body, and is not the pill's copy.
      final copyFrom = seed.indexOf("'pill.copy', jsonb_build_object");
      final copyBlock =
          seed.substring(copyFrom, seed.indexOf('on conflict', copyFrom));

      final gone = _retired([reword]);
      live = _sentences(copyBlock)
          .where((s) => !gone.contains(s.replaceAll('45', '{n}')) && !gone.contains(s))
          .toList()
        // …plus the wording those three were replaced BY, which is what the
        // pill prints today.
        ..addAll(RegExp(r"'(?:(?:[^']|'')+)'\s*,\s*'((?:[^']|'')+)'\s*\)")
            .allMatches(reword)
            .map((m) => m.group(1)!.replaceAll("''", "'").replaceAll('{n}', '45'))
            .where((s) => s.contains(' ')));

      narrow = _sentences(dyn.substring(dyn.indexOf("'narrow', jsonb_build_object"),
          dyn.indexOf('-- ── 2.')));

      breakpoint =
          int.parse(RegExp(r"'\{narrow,max_screen_w\}',\s*'(\d+)'").firstMatch(off)!.group(1)!);
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

    test('the narrow tier is retired — ONE wording at every width', () {
      // v_narrow is `p_w < max_screen_w`, and no viewport is below 0.
      expect(breakpoint, 0,
          reason: 'a width breakpoint is back: the pill reworded itself again');
    });

    test('the retired tier keeps its copy, so re-enabling it is an UPDATE', () {
      expect(narrow.length, greaterThan(20),
          reason: 'the narrow copy was deleted instead of switched off');
    });

    test('the live wording is real wording, not stubs', () {
      expect(live.length, greaterThan(20),
          reason: 'the pill lost its copy');
      for (final s in live) {
        expect(s.trim(), isNotEmpty);
      }
    });

    test('every line the pill can print fits a 360 dp phone, whole', () {
      for (final s in live) {
        expect(_pillFor(_w(s)), lessThanOrEqualTo(360 - _furniture),
            reason: '"$s" ellipsises at 360 dp');
      }
    });

    test('every line the pill can print fits 412 and 480, whole', () {
      for (final width in const [412.0, 480.0]) {
        for (final s in live) {
          expect(_pillFor(_w(s)), lessThanOrEqualTo(width - _furniture),
              reason: '"$s" ellipsises at $width dp');
        }
      }
    });

    test('and no line is wider than the backend ceiling, max_w', () {
      for (final s in live) {
        expect(_pillFor(_w(s)), lessThanOrEqualTo(_maxW),
            reason: '"$s" is clipped by max_w before the row clips it');
      }
    });
  });
}
