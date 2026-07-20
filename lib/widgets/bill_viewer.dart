// CHANGE #465: shared "bill viewer" — full-screen zoomable view of an
// uploaded bill (image or PDF), plus an inline preview widget that renders
// the actual file (not a placeholder) and opens the viewer on tap. Used by
// both the customer Bill tab (orders_screen.dart) and the admin Customer
// Orders card (admin_customer_screen.dart).
//
// PDF rendering uses a native browser <iframe> (package:web + dart:js_interop
// only — never dart:html/dart:js, per CLAUDE.md's defensive import rule) since
// there's no PDF rasterizer available on Flutter web in this project. The
// iframe is set pointer-events:none for the inline thumbnail (so a Flutter
// GestureDetector on top can catch the tap-to-expand) and left interactive in
// the full-screen viewer (so the browser's own PDF viewer can scroll/zoom).
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web/web.dart' as web;

import '../utils/bill_mime.dart';

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

Future<void> showBillViewer(BuildContext context, {required String url, required bool isImage}) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
    opaque: false,
    barrierColor: Colors.black87,
    transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
    pageBuilder: (_, __, ___) => _BillViewerScreen(url: url, isImage: isImage),
  ));
}

class _BillViewerScreen extends StatelessWidget {
  final String url;
  final bool isImage;
  const _BillViewerScreen({required this.url, required this.isImage});

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).pop();
    return GestureDetector(
      // Backdrop tap-to-close. A real <iframe> (the PDF case) consumes its
      // own clicks at the DOM level so a tap ON the PDF won't reach this —
      // the always-visible close button below covers that case.
      onTap: close,
      child: Scaffold(
        backgroundColor: Colors.black87,
        body: Stack(children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(top: 56),
              child: isImage
                  ? InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 6,
                      child: Center(
                        child: GestureDetector(
                          onTap: close,
                          // CHANGE #466: Image.network with no loadingBuilder/errorBuilder
                          // painted nothing while the signed URL was fetching or if it
                          // failed — on the black Scaffold backdrop that reads as a
                          // "dark/blank screen", not an obvious bug. Both are required.
                          child: Image.network(
                            url,
                            fit: BoxFit.contain,
                            loadingBuilder: (_, child, prog) => prog == null
                                ? child
                                : const SizedBox(
                                    width: 32,
                                    height: 32,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  ),
                            errorBuilder: (_, __, ___) => const Text(
                              "Couldn't load bill",
                              style: TextStyle(color: Colors.white, fontSize: 14),
                            ),
                          ),
                        ),
                      ),
                    )
                  : GestureDetector(
                      onTap: () {}, // absorb: stop the backdrop's close from firing under the frame
                      child: PdfFrame(url: url),
                    ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: close,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.close, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// Inline preview: renders the actual uploaded bill (image inline, PDF via a
// non-interactive iframe thumbnail) and opens the full-screen viewer on tap.
// Self-fetches a signed URL for bucket/path since the bucket is private.
class BillFilePreview extends StatefulWidget {
  final String bucket;
  final String path;
  final String name;
  final double height;
  const BillFilePreview({
    super.key,
    required this.bucket,
    required this.path,
    required this.name,
    this.height = 220,
  });

  @override
  State<BillFilePreview> createState() => _BillFilePreviewState();
}

class _BillFilePreviewState extends State<BillFilePreview> {
  String? _url;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BillFilePreview old) {
    super.didUpdateWidget(old);
    if (old.bucket != widget.bucket || old.path != widget.path) {
      setState(() {
        _url = null;
        _error = false;
      });
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final url = await Supabase.instance.client.storage
          .from(widget.bucket)
          .createSignedUrl(widget.path, 3600);
      if (mounted) setState(() => _url = url);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  bool get _isImage => isImageBillName(widget.name);

  @override
  Widget build(BuildContext context) {
    final box = BoxDecoration(
      color: const Color(0xFFF9FAFB),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFFE5E7EB)),
    );
    if (_error) {
      return Container(
        height: widget.height,
        decoration: box,
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 28, color: Color(0xFF9CA3AF)),
          const SizedBox(height: 8),
          const Text("Couldn't load bill",
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
        ]),
      );
    }
    final url = _url;
    if (url == null) {
      return Container(
        height: widget.height,
        decoration: box,
        alignment: Alignment.center,
        child: const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return GestureDetector(
      onTap: () => showBillViewer(context, url: url, isImage: _isImage),
      child: Container(
        height: widget.height,
        width: double.infinity,
        decoration: box,
        clipBehavior: Clip.antiAlias,
        child: _isImage
            ? Image.network(
                url,
                fit: BoxFit.contain,
                loadingBuilder: (_, child, prog) => prog == null
                    ? child
                    : const Center(
                        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
                errorBuilder: (_, __, ___) => const Center(
                    child: Text("Couldn't load bill",
                        style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)))),
              )
            : PdfFrame(url: url, interactive: false),
      ),
    );
  }
}
