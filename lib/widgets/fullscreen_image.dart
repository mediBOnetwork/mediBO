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
      ..style.cursor = 'pointer'
      ..style.pointerEvents = 'none'; // let taps fall through to Flutter
  });

  showDialog(
    context: context,
    barrierColor: Colors.black.withOpacity(0.92),
    builder: (ctx) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(ctx).pop(),
      child: Stack(children: [
        Positioned.fill(child: Container(color: Colors.transparent)),
        Center(
          child: SizedBox(
            width: MediaQuery.of(ctx).size.width * 0.95,
            height: MediaQuery.of(ctx).size.height * 0.85,
            // IgnorePointer ensures Flutter sees the tap even through the platform view.
            child: IgnorePointer(child: HtmlElementView(viewType: vt)),
          ),
        ),
      ]),
    ),
  );
}
