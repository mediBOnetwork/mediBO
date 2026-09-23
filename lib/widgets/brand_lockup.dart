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
/// The sizes stay the header's own (CMD #2164, unchanged): the tile is
/// [DsTouch.headerTile] square with [DsTouch.headerTileRadius] corners in BOTH
/// header states, and the wordmark is [DsHeader.wordFor] tall — 26 on every
/// phone, 22 only below the narrow breakpoint — never auto-shrunk to fit.
///
/// An image that fails to load, or has not loaded yet, draws the letter/word
/// version instead: the header is never blank and never a broken image.
class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.markOnly = false, this.wordWrapper});

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

    final letter = Text(
      l.letter,
      textScaler: TextScaler.noScaling,
      style: Ds.t.title.copyWith(
        fontSize: t.headerTileMark,
        height: 1,
        color: l.tileFg,
        fontWeight: DsHeader.weight(h.markWeight),
      ),
    );

    RenderLog.write('c2173_logo_tile', l.hasTileImage ? 'image' : 'letter');

    final mark = Container(
      width: t.headerTile,
      height: t.headerTile,
      alignment: Alignment.center,
      clipBehavior: l.hasTileImage ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        // The tile's own colour is the backdrop of the letter AND the frame
        // the image is inset into, so a transparent logo still reads.
        color: l.hasTileImage ? Colors.transparent : l.tileBg,
        borderRadius: BorderRadius.all(Radius.circular(t.headerTileRadius)),
      ),
      child: l.hasTileImage
          ? Image.network(
              l.tileUrl,
              width: t.headerTile,
              height: t.headerTile,
              fit: BoxFit.contain,
              // Cached by the engine under this URL, so the header redraws
              // from memory on every rebuild and every later screen.
              filterQuality: FilterQuality.medium,
              // Never a broken image, and never a gap while it arrives: the
              // letter holds the tile until the bytes are decoded.
              errorBuilder: (_, _, _) {
                RenderLog.write('c2173_logo_tile', 'letter');
                return ColoredBox(color: l.tileBg, child: Center(child: letter));
              },
              frameBuilder: (_, child, frame, wasSync) =>
                  (wasSync || frame != null)
                      ? child
                      : ColoredBox(
                          color: l.tileBg, child: Center(child: letter)),
            )
          : letter,
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
