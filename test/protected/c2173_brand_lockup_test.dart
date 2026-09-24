// PROTECTED — CMD #2173, the header lock-up is the backend's, not an asset.
// Rewritten by CMD #2193, which deliberately changed two of the behaviours
// below (see CLAUDE.md: a protected test may only be edited by the CHANGE that
// changes that behaviour — never to make an unrelated change pass).
//
// Om, on the 1.3.35 APK: "the splash shows an old logo for about a second,
// then swaps to the real one", and "the header logo changed shape between
// loading and loaded". Both were the lock-up drawing a mark of its OWN — a
// green square with a letter in it — while the real one was still in flight,
// at a size the header owned rather than the size the artwork owned.
//
// What this holds down now:
//   1. The lock-up owns no strings, no asset and no drawn mark. Both words and
//      their colours arrive on `design.header.logo` and are rendered verbatim —
//      change the payload, change the header, no deploy.
//   2. The tile is ONE box: `brand.logo.size` square with `brand.logo.radius`
//      corners, in BOTH header states (markOnly and full) and on BOTH sides of
//      loading. The numbers are the payload's, never a Dart constant.
//   3. No bytes to draw — no tile_url, still decoding, or a URL that failed —
//      leaves that box EMPTY. Never a letter, never a colour, never an asset:
//      a second mark is exactly the bug Om saw.
//   4. wordmark_url set => the wordmark is that image at the header's own word
//      size; empty => word_1 + word_2 in their own colours, never auto-shrunk
//      (no FittedBox, no text scaling). A broken wordmark image still falls
//      back to those words — they ARE the wordmark, not a stand-in for it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/brand_lockup.dart';

/// The payload exactly as `ui_boot().design.header.logo` sends it — which is
/// the whole `brand.logo` row, geometry included (CMD #2193).
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
      'size': 49,
      'radius': 11,
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

  testWidgets('no tile_url => the box is EMPTY, not a letter and not an asset',
      (tester) async {
    await tester.pumpWidget(_app(const BrandLockup()));

    // No app asset anywhere in the lock-up. #2173's whole point.
    expect(find.descendant(
        of: find.byType(BrandLockup), matching: find.byType(Image)),
        findsNothing);
    // And no mark of our own drawn in its place. #2193's whole point.
    expect(find.text('m'), findsNothing);
    expect(find.byType(Text), findsOneWidget); // the wordmark alone
    // The box is still there, holding the mark's room.
    final tile = _tileOf(tester);
    expect(tile.constraints!.maxWidth, Ds.header.logo.size);
    expect((tile.decoration as BoxDecoration).color, Colors.transparent);
  });

  testWidgets('the words, the colours and the BOX are the payload verbatim',
      (tester) async {
    _apply({
      ..._logo(),
      'word_1': 'well',
      'word_2': 'RX',
      'word_1_fg': '#112233',
      'word_2_fg': '#445566',
      'size': 60,
      'radius': 7,
    });
    await tester.pumpWidget(_app(const BrandLockup()));

    // The box is the backend's pair of numbers — no Dart constant survives.
    final tile = _tileOf(tester);
    expect(tile.constraints!.maxWidth, 60);
    expect(tile.constraints!.maxHeight, 60);
    expect((tile.decoration as BoxDecoration).borderRadius,
        const BorderRadius.all(Radius.circular(7)));

    // Both halves of the wordmark, each in its own colour — no Dart literal.
    final word = tester.widget<Text>(find.byWidgetPredicate(
        (w) => w is Text && w.textSpan != null));
    final spans = (word.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.map((s) => s.text).toList(), ['well', 'RX']);
    expect(spans[0].style!.color, const Color(0xFF112233));
    expect(spans[1].style!.color, const Color(0xFF445566));
    expect(find.text('medi'), findsNothing);
  });

  testWidgets('tile_url set => the tile draws that image, at the payload box',
      (tester) async {
    _apply(_logo(tile: 'https://example.test/logo.png'));
    await tester.pumpWidget(_app(const BrandLockup()));

    final img = tester.widget<Image>(find.descendant(
        of: find.byType(BrandLockup), matching: find.byType(Image)));
    expect((img.image as NetworkImage).url, 'https://example.test/logo.png');
    expect(img.width, Ds.header.logo.size);
    expect(img.height, Ds.header.logo.size);
  });

  testWidgets('the tile is ONE size and shape — both states, both sides of '
      'loading', (tester) async {
    for (final markOnly in [false, true]) {
      for (final tile in ['', 'https://example.test/logo.png']) {
        _apply(_logo(tile: tile));
        await tester.pumpWidget(_app(BrandLockup(markOnly: markOnly)));
        final box = _tileOf(tester);
        expect(box.constraints!.maxWidth, Ds.header.logo.size);
        expect(box.constraints!.maxHeight, Ds.header.logo.size);
        expect((box.decoration as BoxDecoration).borderRadius,
            BorderRadius.all(Radius.circular(Ds.header.logo.radius)));
        // markOnly is the tile alone — the sticky bar's left edge.
        expect(find.byType(Row), markOnly ? findsNothing : findsWidgets);
      }
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
    // The tile stays empty — only the words were replaced.
    expect(find.text('m'), findsNothing);
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

  testWidgets('a broken tile image leaves the box empty — the words stay',
      (tester) async {
    _apply(_logo(
        tile: 'https://example.test/gone.png',
        wordmark: 'https://example.test/gone2.png'));
    await tester.pumpWidget(_app(const BrandLockup()));

    // Flutter's test HTTP client answers 400, so both images error out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // No second mark in the tile's place, and the box has not moved.
    expect(find.text('m'), findsNothing);
    final tile = _tileOf(tester);
    expect(tile.constraints!.maxWidth, Ds.header.logo.size);
    expect((tile.decoration as BoxDecoration).color, Colors.transparent);

    // The wordmark falls back to the backend's two words, as it always has.
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
