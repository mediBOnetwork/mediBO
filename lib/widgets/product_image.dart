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
        fadeInDuration: const Duration(milliseconds: 160),
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
