// CHANGE #476 — native <img> renderer for signed storage URLs.
// dart:html / dart:ui_web are isolated here per CLAUDE.md's defensive import
// rule (only main.dart and dedicated util/widget files like this one may
// import them; see also utils/download_bytes.dart).
//
// Why not Flutter's Image.network: on Flutter Web (CanvasKit renderer),
// Image.network fetches bytes via XHR/fetch, which is subject to CORS.
// A plain <img src> does NOT need CORS to display an image (only to read its
// pixels via canvas) — so a signed Supabase Storage URL that Image.network
// silently fails to paint (no errorBuilder fires; it just never appears)
// renders fine as a native <img>. This mirrors the technique already used
// for admin's payment-proof viewer in admin_customer_screen.dart.
// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class NativeSignedImage extends StatefulWidget {
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
  State<NativeSignedImage> createState() => _NativeSignedImageState();
}

class _NativeSignedImageState extends State<NativeSignedImage> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    // Flutter web throws if the same viewType is registered twice — the
    // caller must vary `cacheKey` (and pass a matching Key) per retry.
    _viewType = 'native-signed-img-${widget.cacheKey}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final img = html.ImageElement()
        ..src = widget.url
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        ..style.background = '#F3F4F6';
      final onTap = widget.onTap;
      if (onTap != null) {
        img.style.cursor = 'pointer';
        img.onClick.listen((_) => onTap());
      }
      final onError = widget.onError;
      if (onError != null) {
        img.onError.listen((_) => onError());
      }
      return img;
    });
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
