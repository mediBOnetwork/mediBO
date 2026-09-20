// CMD #2119 item 3 — the uploaded order opens INSIDE the app.
//
// Before this, the file chip in the Bulk Upload review was a label: the buyer
// could read its name and nothing else, and the only way to look at what they
// had sent was to leave mediBO and open it in another app. A phone buyer
// checking "did it read my line 4 right?" lost the review to do it.
//
// This is a pushed route, so Back returns to the same review at the same
// scroll offset. It renders the bytes the app already holds:
//   image  → Image.memory inside an InteractiveViewer (pinch and pan)
//   pdf    → the app's own <iframe> (web), the browser's renderer inside our
//            page — never a hand-off to another application
//   text / spreadsheet → the extracted text the app parsed, selectable
//   anything else → the backend's own "no preview" sentence
//
// Every word here is ui_copy. Nothing about the file is worded in Dart.
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/ui_copy.dart';
import '../utils/object_url.dart';
import '../utils/render_log.dart';
import 'pdf_frame.dart';

/// Opens the viewer as a full-screen route.
///
/// [bytes] are the file exactly as it was picked. [text] is the plain-text
/// rendition the ingest pipeline already produced for spreadsheets, CSV and
/// text files — the app has it, so a .xlsx is readable here too.
Future<void> showBulkFileViewer(
  BuildContext context, {
  required String fileName,
  required String mimeType,
  Uint8List? bytes,
  String? text,
}) {
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => BulkFileViewerScreen(
      fileName: fileName,
      mimeType: mimeType,
      bytes: bytes,
      text: text,
    ),
  ));
}

class BulkFileViewerScreen extends StatefulWidget {
  final String fileName;
  final String mimeType;
  final Uint8List? bytes;
  final String? text;

  const BulkFileViewerScreen({
    super.key,
    required this.fileName,
    required this.mimeType,
    this.bytes,
    this.text,
  });

  @override
  State<BulkFileViewerScreen> createState() => _BulkFileViewerScreenState();
}

class _BulkFileViewerScreenState extends State<BulkFileViewerScreen> {
  String? _objectUrl;

  bool get _isImage =>
      widget.mimeType.startsWith('image/') || _hasExt(_imageExts);

  bool get _isPdf =>
      widget.mimeType.contains('pdf') || _hasExt(const ['pdf']);

  static const _imageExts = ['jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'gif'];

  bool _hasExt(List<String> exts) {
    final n = widget.fileName.toLowerCase();
    return exts.any((e) => n.endsWith('.$e'));
  }

  @override
  void initState() {
    super.initState();
    // Only the PDF path needs a URL; an image renders from the bytes directly
    // and a spreadsheet renders from the text the pipeline already extracted.
    final b = widget.bytes;
    if (_isPdf && kIsWeb && b != null && b.isNotEmpty) {
      _objectUrl = createObjectUrl(b, 'application/pdf');
    }
  }

  @override
  void dispose() {
    final u = _objectUrl;
    if (u != null) revokeObjectUrl(u);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    try {
      RenderLog.write('c2119_file_viewer', '1');
    } catch (_) {}
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(
          widget.fileName.isEmpty ? c('bulk.file_viewer_title') : widget.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: Semantics(
          identifier: 'bulk_file_viewer_close',
          button: true,
          label: c('bulk.file_viewer_close'),
          child: IconButton(
            icon: const Icon(Icons.close),
            tooltip: c('bulk.file_viewer_close'),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    final b = widget.bytes;
    if (_isImage && b != null && b.isNotEmpty) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 6,
        child: Center(
          child: Image.memory(
            b,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => _message(c('bulk.file_viewer_error')),
          ),
        ),
      );
    }
    final url = _objectUrl;
    if (url != null) {
      return PdfFrame(url: url);
    }
    final t = widget.text;
    if (t != null && t.trim().isNotEmpty) {
      return SingleChildScrollView(
        padding: EdgeInsets.all(Ds.space.x16),
        child: SelectableText(t, style: Ds.t.body),
      );
    }
    return _message(c('bulk.file_viewer_no_preview'));
  }

  Widget _message(String msg) => Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Center(
          child: Text(msg, textAlign: TextAlign.center, style: Ds.t.body),
        ),
      );
}
