// Native implementation of NativeSignedImage. No CORS restriction exists on
// image loading off the web, so a normal cached network image renders the
// signed storage URL directly. Public API matches native_signed_image_web.dart
// exactly so callers type-check unchanged.
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class NativeSignedImage extends StatelessWidget {
  final String url;
  final String cacheKey; // unique per url/attempt — a fresh retry needs a new key
  final VoidCallback? onError;
  final VoidCallback? onTap;
  const NativeSignedImage({
    super.key,
    required this.url,
    required this.cacheKey,
    this.onError,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final view = CachedNetworkImage(
      imageUrl: url,
      cacheKey: cacheKey,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFFF3F4F6),
      colorBlendMode: BlendMode.dstOver,
      errorWidget: (context, url, error) {
        final cb = onError;
        if (cb != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => cb());
        }
        return Container(color: const Color(0xFFF3F4F6));
      },
    );
    final tap = onTap;
    if (tap == null) return view;
    return GestureDetector(
        behavior: HitTestBehavior.opaque, onTap: tap, child: view);
  }
}
