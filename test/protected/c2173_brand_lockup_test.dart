// PROTECTED — CMD #2173, the header lock-up is the backend's, not an asset.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change pass.
//
// What this holds down:
//   1. The lock-up owns no strings and no asset. The letter, both words and
//      all four colours arrive on `design.header.logo` and are rendered
//      verbatim — change the payload, change the header, no deploy.
//   2. tile_url set => the tile is that image; empty => the letter on tile_bg.
//      Either way the tile is exactly headerTile square with headerTileRadius
//      corners, in BOTH header states (markOnly and full) — #2164 unchanged.
//   3. wordmark_url set => the wordmark is that image at the header's own word
//      size; empty => word_1 + word_2 in their own colours, never auto-shrunk
//      (no FittedBox, no text scaling).
//   4. An image that fails to load falls back to the letter/word version —
//      never a broken image, never a blank header.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/brand_lockup.dart';

/// The payload exactly as `ui_boot().design.header.logo` sends it.
Map<String, dynamic> _logo({String tile = '', String wordmark = ''}) => {
      'tile_url': tile,
      'wordmark_url': wordmark,
      'letter': 'm',
      'tile_bg': '#1B8A3E',
      'tile_fg': '#FFFFFF',
      'word_1': 'medi',
      'word_1_fg': '#1B7A43',
      'word_2': 'BO',
      'word_2_fg': '#2FA24F',
    };

void _apply(Map<String, dynamic> logo) =>
    Ds.apply(<String, dynamic>{
      'header': <String, dynamic>{'logo': logo}
    });

Widget _app(Widget child, {double width = 360}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: Scaffold(body: Center(child: child)),
      ),
    );

/// The tile Container the lock-up draws — the one with a BoxDecoration.
Container _tileOf(WidgetTester tester) => tester.widgetList<Container>(
      find.descendant(
        of: find.byType(BrandLockup),
        matching: find.byType(Container),
      ),
    ).firstWhere((c) => c.decoration is BoxDecoration);

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  setUp(() => _apply(_logo()));

  testWidgets('no payload logo => the fallback letter and words, not an asset',
      (tester) async {
    await tester.pumpWidget(_app(const BrandLockup()));

    // No app asset anywhere in the lock-up. #2173's whole point.
    expect(find.descendant(
        of: find.byType(BrandLockup), matching: find.byType(Image)),
        findsNothing);
    expect(find.text('m'), findsOneWidget);
    expect(find.byType(Text), findsNWidgets(2)); // the letter + the wordmark
  });

  testWidgets('the letter, the words and the colours are the payload verbatim',
      (tester) async {
    _apply({
      ..._logo(),
      'letter': 'Z',
      'word_1': 'well',
      'word_2': 'RX',
      'word_1_fg': '#112233',
      'word_2_fg': '#445566',
      'tile_bg': '#0A0B0C',
      'tile_fg': '#FEDCBA',
    });
    await tester.pumpWidget(_app(const BrandLockup()));

    // The letter is the backend's, in the backend's colour, on its colour.
    final letter = tester.widget<Text>(find.text('Z'));
    expect(letter.style!.color, const Color(0xFFFEDCBA));
    expect((_tileOf(tester).decoration as BoxDecoration).color,
        const Color(0xFF0A0B0C));

    // Both halves of the wordmark, each in its own colour — no Dart literal.
    final word = tester.widget<Text>(find.byWidgetPredicate(
        (w) => w is Text && w.textSpan != null));
    final spans = (word.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.map((s) => s.text).toList(), ['well', 'RX']);
    expect(spans[0].style!.color, const Color(0xFF112233));
    expect(spans[1].style!.color, const Color(0xFF445566));
    expect(find.text('medi'), findsNothing);
  });

  testWidgets('tile_url set => the tile draws that image, never the letter',
      (tester) async {
    _apply(_logo(tile: 'https://example.test/logo.png'));
    await tester.pumpWidget(_app(const BrandLockup()));

    final img = tester.widget<Image>(find.descendant(
        of: find.byType(BrandLockup), matching: find.byType(Image)));
    expect((img.image as NetworkImage).url, 'https://example.test/logo.png');
    expect(img.width, Ds.touch.headerTile);
    expect(img.height, Ds.touch.headerTile);
  });

  testWidgets('the tile is ONE size and shape in both header states',
      (tester) async {
    for (final markOnly in [false, true]) {
      _apply(_logo());
      await tester.pumpWidget(_app(BrandLockup(markOnly: markOnly)));
      final tile = _tileOf(tester);
      expect(tile.constraints!.maxWidth, Ds.touch.headerTile);
      expect(tile.constraints!.maxHeight, Ds.touch.headerTile);
      expect((tile.decoration as BoxDecoration).borderRadius,
          BorderRadius.all(Radius.circular(Ds.touch.headerTileRadius)));
      // markOnly is the tile alone — the sticky bar's left edge.
      expect(find.byType(Row), markOnly ? findsNothing : findsWidgets);
    }
  });

  testWidgets('wordmark_url set => the wordmark is that image at word height',
      (tester) async {
    _apply(_logo(wordmark: 'https://example.test/word.png'));
    await tester.pumpWidget(_app(const BrandLockup()));

    final img = tester.widget<Image>(find.descendant(
        of: find.byType(BrandLockup), matching: find.byType(Image)));
    expect((img.image as NetworkImage).url, 'https://example.test/word.png');
    expect(img.height, Ds.header.wordFor(360));
    // The letter still holds the tile — only the words were replaced.
    expect(find.text('m'), findsOneWidget);
  });

  testWidgets('the wordmark is never auto-shrunk to fit', (tester) async {
    await tester.pumpWidget(_app(const BrandLockup(), width: 320));
    expect(find.descendant(
        of: find.byType(BrandLockup), matching: find.byType(FittedBox)),
        findsNothing);
    final word = tester.widget<Text>(find.byWidgetPredicate(
        (w) => w is Text && w.textSpan != null));
    expect(word.textScaler, TextScaler.noScaling);
    expect(word.maxLines, 1);
  });

  testWidgets('a broken image falls back to the letter and the words',
      (tester) async {
    _apply(_logo(
        tile: 'https://example.test/gone.png',
        wordmark: 'https://example.test/gone2.png'));
    await tester.pumpWidget(_app(const BrandLockup()));

    // Flutter's test HTTP client answers 400, so both images error out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('m'), findsOneWidget);
    final word = tester.widget<Text>(find.byWidgetPredicate(
        (w) => w is Text && w.textSpan != null));
    final spans = (word.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.map((s) => s.text).toList(), ['medi', 'BO']);
  });

  testWidgets('the wordmark width the header reserves is the real one',
      (tester) async {
    late double measured;
    await tester.pumpWidget(_app(Builder(builder: (ctx) {
      measured = BrandLockup.wordWidth(ctx);
      return const BrandLockup();
    })));
    expect(measured, greaterThan(0));
    final box = tester.getSize(find.byWidgetPredicate(
        (w) => w is Text && w.textSpan != null));
    expect(box.width, closeTo(measured, 0.5));
  });
}
