// PDF rendering uses a native browser <iframe> (package:web + dart:js_interop
// only — never dart:html/dart:js, per CLAUDE.md's defensive import rule) since
// there's no PDF rasterizer available on Flutter web in this project. The
// iframe is set pointer-events:none for the inline thumbnail (so a Flutter
// GestureDetector on top can catch the tap-to-expand) and left interactive in
// the full-screen viewer (so the browser's own PDF viewer can scroll/zoom).
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class PdfFrame extends StatelessWidget {
  final String url;
  final bool interactive;
  const PdfFrame({super.key, required this.url, this.interactive = true});

  @override
  Widget build(BuildContext context) {
    return HtmlElementView.fromTagName(
      tagName: 'iframe',
      onElementCreated: (element) {
        final iframe = element as web.HTMLIFrameElement;
        iframe.src = url;
        iframe.style
          ..border = 'none'
          ..width = '100%'
          ..height = '100%'
          ..pointerEvents = interactive ? 'auto' : 'none';
      },
    );
  }
}
