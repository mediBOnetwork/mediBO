import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

/// CMD #2173 — the mediBO lock-up: the tile + the wordmark, drawn from the
/// backend and from nothing else.
///
/// There is no app asset and no Dart string here. `design.header.logo`
/// (app_settings 'brand.logo', carried on `ui_boot()`) says whether the tile
/// is an uploaded image or a letter on a colour, and whether the wordmark is
/// an uploaded image or two coloured words. Uploading a new logo, recolouring
/// the wordmark or renaming the app is an UPDATE to that row: the next reload
/// carries it, with no deploy.
///
/// CMD #2193 (Om, on the 1.3.35 APK) — ONE MARK, AND NOTHING BEFORE IT.
///
/// "The header logo changed shape between loading and loaded." It did: the
/// tile was a green [DsTouch.headerTile] square with a letter in it until the
/// payload landed, and then became the real 49 dp artwork. Two different marks
/// in the same corner, half a second apart.
///
/// The box is now ONE pair of backend numbers — `brand.logo.size` and
/// `brand.logo.radius`, [DsBrandLogo.size] / [DsBrandLogo.radius] — used for
/// the placeholder AND for the image, so the mark cannot change size or corner
/// as it arrives. While there are no bytes to draw (no `tile_url`, still
/// decoding, or a URL that failed) the tile is that box and EMPTY: no letter,
/// no colour, no asset. brand.logo says it in its own words —
///   "ONE logo only: tile_url is the single source. Never add a letter/drawn
///    fallback — it renders a different mark."
///
/// The wordmark is still [DsHeader.wordFor] tall — 26 on every phone, 22 only
/// below the narrow breakpoint — and is still the backend's two words in the
/// backend's two colours when no `wordmark_url` is set. Those words are the
/// wordmark, not a stand-in for it.
class BrandLockup extends StatelessWidget {
  const BrandLockup({
    super.key,
    this.markOnly = false,
    this.wordWrapper,
    this.tileSize,
    this.tileRadius,
  });

  /// An override for the one box, for a surface that genuinely needs its own
  /// (nothing in the shell does since CMD #2193). null — the normal case —
  /// takes [DsBrandLogo.size] / [DsBrandLogo.radius], the backend's own pair,
  /// which is the same pair before and after the bytes arrive.
  final double? tileSize;
  final double? tileRadius;

  /// Draw the tile alone — the sticky bar's left edge once the logo row has
  /// scrolled away.
  final bool markOnly;

  /// Lets the caller wrap the wordmark (the mobile header fades it out as the
  /// logo row collapses). The lock-up itself stays a pure render.
  final Widget Function(Widget child)? wordWrapper;

  /// The wordmark as text, in the backend's words and the backend's colours.
  static TextSpan _word(BuildContext context) {
    final h = Ds.header;
    final l = h.logo;
    return TextSpan(
      style: Ds.t.title.copyWith(
        fontSize: h.wordFor(MediaQuery.sizeOf(context).width),
        height: 1,
        letterSpacing: h.wordSpacing,
        fontWeight: DsHeader.weight(h.wordWeight),
      ),
      children: [
        TextSpan(text: l.word1, style: TextStyle(color: l.word1Fg)),
        TextSpan(text: l.word2, style: TextStyle(color: l.word2Fg)),
      ],
    );
  }

  /// The wordmark's laid-out width at this viewport's size — what the header
  /// reserves for it when it decides whether the word still fits.
  static double wordWidth(BuildContext context) => (TextPainter(
        text: _word(context),
        maxLines: 1,
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout())
          .width;

  Widget _wordText(BuildContext context) => Text.rich(
        _word(context),
        maxLines: 1,
        softWrap: false,
        textScaler: TextScaler.noScaling,
      );

  @override
  Widget build(BuildContext context) {
    final t = Ds.touch;
    final h = Ds.header;
    final l = h.logo;

    // ONE box, from the backend, on both sides of loading. CMD #2193.
    final double tileW = tileSize ?? l.size;
    final double tileR = tileRadius ?? l.radius;

    // What the tile holds while there is nothing to draw: the same box, empty.
    // It reserves the mark's room so the row does not reflow when the bytes
    // land, and it draws no mark of its own — that was the "old logo".
    final Widget empty = SizedBox(width: tileW, height: tileW);

    RenderLog.write('c2173_logo_tile', l.hasTileImage ? 'image' : 'empty');

    final mark = Container(
      width: tileW,
      height: tileW,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // Transparent in both states: the PNG carries its own field, and an
        // empty tile is empty, not a green square waiting to be replaced.
        color: Colors.transparent,
        borderRadius: BorderRadius.all(Radius.circular(tileR)),
      ),
      child: l.hasTileImage
          ? Image.network(
              l.tileUrl,
              width: tileW,
              height: tileW,
              fit: BoxFit.contain,
              // Cached by the engine under this URL, so the header redraws
              // from memory on every rebuild and every later screen.
              filterQuality: FilterQuality.medium,
              // A URL that fails leaves the box empty. Never a broken image,
              // and never a SECOND mark drawn in its place.
              errorBuilder: (_, _, _) {
                RenderLog.write('c2173_logo_tile', 'empty');
                return empty;
              },
              frameBuilder: (_, child, frame, wasSync) =>
                  (wasSync || frame != null) ? child : empty,
            )
          : empty,
    );

    if (markOnly) return mark;

    RenderLog.write(
        'c2173_logo_word', l.hasWordmarkImage ? 'image' : 'words');

    final wordHeight = h.wordFor(MediaQuery.sizeOf(context).width);
    Widget word = l.hasWordmarkImage
        ? Image.network(
            l.wordmarkUrl,
            height: wordHeight,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            errorBuilder: (ctx, _, _) {
              RenderLog.write('c2173_logo_word', 'words');
              return _wordText(ctx);
            },
            frameBuilder: (ctx, child, frame, wasSync) =>
                (wasSync || frame != null) ? child : _wordText(ctx),
          )
        : _wordText(context);

    final wrap = wordWrapper;
    if (wrap != null) word = wrap(word);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        SizedBox(width: t.headerWordGap),
        word,
      ],
    );
  }
}
