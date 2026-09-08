import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// CHANGE #636 — the ONE product image widget for the storefront.
///
/// Butter rule: the box is reserved before the bytes arrive. [width] and
/// [height] are always applied to the placeholder, the error state and the
/// decoded image alike, so the placeholder → image swap can never reflow the
/// grid. That is the whole reason product images stopped being raw
/// `Image.network`, which sized itself only once the bytes landed.
///
/// `cacheWidth`/`cacheHeight` are passed as memCacheWidth/Height so a 1000px
/// source does not decode at full size into a 150px tile.
///
/// CHANGE #274 — NO FADE, AND NO DecorationImage. Om reported product images
/// intermittently painting as solid BLACK squares, cleared by a refresh.
///
/// Both halves of that were CachedNetworkImage's default render path on
/// Flutter web:
///
///  * `fadeInDuration` wraps the first paint in an opacity animation. An
///    opacity layer forces a `saveLayer`, and on CanvasKit a layer composited
///    before the texture is ready paints its uninitialised contents — opaque
///    black — for a frame or three. It is a race, which is exactly why it hit
///    "randomly" and never twice in the same place.
///  * With no `imageBuilder`, the package paints the decoded bytes as a
///    `DecorationImage` inside a `Container`. Nested inside this widget's own
///    `ClipRRect`, the card's `Clip.antiAlias` plate and a `Hero`, that is
///    three stacked save-layers around one 150px tile.
///
/// A refresh "fixed" it because the second load is a memory-cache hit, which
/// skips the fade entirely — the strongest evidence it was the fade and not
/// the bytes. So: zero-length fades, and an explicit `Image` in `imageBuilder`
/// that draws straight into the parent layer. The placeholder still reserves
/// the box, so the butter rule is untouched.
class ProductImage extends StatelessWidget {
  final String url;
  final double width;
  final double height;
  final BoxFit fit;

  /// Rounded corners applied to the image AND to both fallback boxes, so all
  /// three states occupy an identical shape.
  final BorderRadius? radius;

  const ProductImage({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.fit = BoxFit.contain,
    this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final r = radius ?? BorderRadius.zero;
    // An empty string is the backend's explicit "no image" (never null in a
    // payload), so this is an absence, not a failure.
    if (url.isEmpty) return _fallback(r);

    return ClipRRect(
      borderRadius: r,
      child: CachedNetworkImage(
        imageUrl: url,
        width: width,
        height: height,
        fit: fit,
        memCacheWidth: (width * 2).round(),
        memCacheHeight: (height * 2).round(),
        // Zero, not short: any non-zero duration re-introduces the opacity
        // layer that was painting black. The swap from placeholder to image is
        // already invisible because both occupy the same reserved box.
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        imageBuilder: (_, provider) => Image(
          image: provider,
          width: width,
          height: height,
          fit: fit,
          filterQuality: FilterQuality.medium,
          // gaplessPlayback keeps the previous frame on screen while a new
          // provider resolves, so a rebuilt tile never blanks either.
          gaplessPlayback: true,
        ),
        placeholder: (_, __) => _box(r, const Color(0xFFF6F7F9)),
        errorWidget: (_, __, ___) => _fallback(r),
      ),
    );
  }

  Widget _box(BorderRadius r, Color c) => SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(color: c, borderRadius: r),
        ),
      );

  Widget _fallback(BorderRadius r) => SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFF6F7F9),
            borderRadius: r,
          ),
          child: Center(
            child: Icon(
              Icons.medication_outlined,
              size: width * 0.34,
              color: const Color(0xFFC7CBD1),
            ),
          ),
        ),
      );
}
