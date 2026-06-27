// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';

void openFullscreenImage(BuildContext context, String imageUrl) {
  final vt = 'fullscreen-${DateTime.now().millisecondsSinceEpoch}';
  ui_web.platformViewRegistry.registerViewFactory(vt, (int viewId) {
    return html.ImageElement()
      ..src = imageUrl
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain';
  });

  showDialog(
    context: context,
    barrierColor: Colors.black87,
    builder: (ctx) => GestureDetector(
      onTap: () => Navigator.pop(ctx),
      child: Container(
        color: Colors.transparent,
        child: Stack(
          children: [
            Center(
              child: SizedBox(
                width: MediaQuery.of(ctx).size.width * 0.95,
                height: MediaQuery.of(ctx).size.height * 0.85,
                child: HtmlElementView(viewType: vt),
              ),
            ),
            Positioned(
              top: 40,
              right: 20,
              child: GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: const Icon(Icons.close, color: Colors.white, size: 28),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
