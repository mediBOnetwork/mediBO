// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// Renders the picked selfie via a registered platform-view <img>. The
/// registration and HtmlElementView construction moved here verbatim from the
/// cash sheet; `onTap` replaces the inline openFullscreenImage() closure.
Widget selfiePreview({
  required Uint8List bytes,
  required String dataUrl,
  required VoidCallback onTap,
}) {
  final vt = 'cash-preview-${DateTime.now().millisecondsSinceEpoch}';
  ui_web.platformViewRegistry.registerViewFactory(vt, (int viewId) {
    final img = html.ImageElement()
      ..src = dataUrl
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover'
      ..style.borderRadius = '10px'
      ..style.cursor = 'pointer';
    img.onClick.listen((_) => onTap());
    return img;
  });
  return HtmlElementView(viewType: vt);
}
