// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';

void openFullscreenImage(BuildContext context, String imageUrl) {
  final vt = 'fs-${DateTime.now().microsecondsSinceEpoch}';
  ui_web.platformViewRegistry.registerViewFactory(vt, (int viewId) {
    return html.ImageElement()
      ..src = imageUrl
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.cursor = 'pointer';
  });

  showDialog(
    context: context,
    barrierColor: Colors.black.withOpacity(0.9),
    builder: (ctx) => Stack(
      children: [
        // Tap backdrop to close (behind the image).
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(ctx).pop(),
            child: const SizedBox.expand(),
          ),
        ),
        Center(
          child: SizedBox(
            width: MediaQuery.of(ctx).size.width * 0.95,
            height: MediaQuery.of(ctx).size.height * 0.85,
            child: HtmlElementView(viewType: vt),
          ),
        ),
        // Close button above the platform view.
        Positioned(
          top: 40,
          right: 20,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(ctx).pop(),
            child: Container(
              decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(24)),
              padding: const EdgeInsets.all(8),
              child: const Icon(Icons.close, color: Colors.white, size: 30),
            ),
          ),
        ),
      ],
    ),
  );
}
