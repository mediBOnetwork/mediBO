// PROTECTED — CHANGE #274.
//
// Om reported product images intermittently painting as solid BLACK squares on
// the storefront, cleared by a page refresh. See the class doc on
// [ProductImage]: the cause was CachedNetworkImage's default web render path —
// a fade-in opacity layer composited before the texture was ready, plus a
// DecorationImage nested inside three other save-layers. The refresh "fix" was
// the memory-cache hit skipping the fade, which is what identified it.
//
// A black tile is invisible to every automated check we have: the widget
// rendered, the bundle contains the code, the render-log counts the card. Only
// a human looking at a phone catches it. So the rule is pinned here instead —
// per CLAUDE.md, a reported bug becomes a permanent guard so the CLASS of bug
// is retired rather than one screenshot at a time.
//
// What this holds down:
//
//   1. No fade. Any non-zero fadeIn/fadeOut duration re-introduces the opacity
//      layer that was painting black.
//   2. The decoded bytes are drawn by an explicit Image widget (imageBuilder),
//      not by the package's DecorationImage fallback.
//   3. All three states — placeholder, error and loaded — occupy the SAME
//      reserved box, so the swap can never reflow a grid (the butter rule
//      #636 introduced, which this must not break).
//
// No network: the widget is built and inspected, never loaded.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/product_image.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('a product image never fades in', () {
    testWidgets('both fade durations are zero', (tester) async {
      await tester.pumpWidget(_host(const ProductImage(
        url: 'https://example.invalid/pack.jpg',
        width: 120,
        height: 120,
      )));

      final img = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage));

      expect(img.fadeInDuration, Duration.zero,
          reason: 'a fade forces a saveLayer, which CanvasKit painted black '
              'before the texture was ready — the #274 bug');
      expect(img.fadeOutDuration, Duration.zero);
    });

    testWidgets('the loaded frame is an explicit Image, not a DecorationImage',
        (tester) async {
      await tester.pumpWidget(_host(const ProductImage(
        url: 'https://example.invalid/pack.jpg',
        width: 120,
        height: 120,
      )));

      final img = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage));
      expect(img.imageBuilder, isNotNull,
          reason: 'without one the package paints a DecorationImage inside yet '
              'another Container layer');

      // Build what the builder would return and check it draws the bytes
      // directly, at the reserved size.
      final built = img.imageBuilder!(
          tester.element(find.byType(CachedNetworkImage)),
          const AssetImage('assets/images/medibo_logo.png'));
      expect(built, isA<Image>());
      expect((built as Image).width, 120);
      expect(built.height, 120);
      expect(built.gaplessPlayback, isTrue,
          reason: 'a rebuilt tile keeps its last frame instead of blanking');
    });
  });

  group('every state occupies the same reserved box', () {
    testWidgets('an empty url is an absence, drawn at the reserved size',
        (tester) async {
      // '' is the backend's explicit "no image" — never a failure, and never a
      // zero-sized widget that would collapse the row.
      await tester.pumpWidget(_host(const ProductImage(
        url: '',
        width: 96,
        height: 96,
      )));

      expect(find.byType(CachedNetworkImage), findsNothing);
      final size = tester.getSize(find.byType(ProductImage));
      expect(size.width, 96);
      expect(size.height, 96);
    });

    testWidgets('the pending state reserves the box before any bytes land',
        (tester) async {
      await tester.pumpWidget(_host(const ProductImage(
        url: 'https://example.invalid/pack.jpg',
        width: 140,
        height: 140,
      )));

      final size = tester.getSize(find.byType(ProductImage));
      expect(size.width, 140);
      expect(size.height, 140,
          reason: 'placeholder → image must never reflow the grid');
    });
  });
}
