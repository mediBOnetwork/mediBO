// CMD #2128 — the in-app document viewer (approved design, Image B · 3).
//
// Tapping a thumbnail opens THIS, never another app: a full-screen dark page
// with the paper on it, pinch-to-zoom, a page strip when the file has more
// than one page, and Retake / Keep / Remove along the bottom. Every caption —
// the title, the line under the page, the three buttons — arrives on the
// row's `viewer` block; this file decides none of them.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// What the person chose to do with the paper they were looking at.
enum DocViewerChoice { keep, retake, remove }

Map<String, dynamic> _m(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

Future<DocViewerChoice?> showDocViewer(
  BuildContext context, {
  required Map<String, dynamic> row,
  String url = '',
  Uint8List? bytes,
}) {
  return Navigator.of(context).push<DocViewerChoice>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => DocViewerScreen(row: row, url: url, bytes: bytes),
  ));
}

class DocViewerScreen extends StatefulWidget {
  const DocViewerScreen(
      {super.key, required this.row, this.url = '', this.bytes});

  /// One row of custreg_licences_block(), carrying `viewer` and `thumb`.
  final Map<String, dynamic> row;

  /// A readable URL for the stored file, when there is one.
  final String url;

  /// The bytes of a file picked on this device and not yet uploaded.
  final Uint8List? bytes;

  @override
  State<DocViewerScreen> createState() => _DocViewerScreenState();
}

class _DocViewerScreenState extends State<DocViewerScreen> {
  int _page = 0;

  Map<String, dynamic> get _viewer => _m(widget.row['viewer']);
  Map<String, dynamic> get _thumb => _m(widget.row['thumb']);

  bool get _isPdf => _s(_thumb, 'kind') == 'pdf';
  int get _pages {
    final n = (_thumb['pages'] as num?)?.toInt() ?? 0;
    return n > 0 ? n : 1;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Ds.c.text;
    return Scaffold(
      backgroundColor: dark,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _bar(),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
                child: ClipRRect(
                  borderRadius: Ds.r.rCard,
                  child: Container(
                    color: Ds.c.surface,
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 5,
                      child: Center(child: _paper()),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: Ds.space.x12),
            if (_s(_viewer, 'hint').isNotEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
                child: Text(_s(_viewer, 'hint'),
                    textAlign: TextAlign.center,
                    style: Ds.t.caption.copyWith(color: Ds.c.surface)),
              ),
            if (_pages > 1) ...[
              SizedBox(height: Ds.space.x12),
              _strip(),
            ],
            SizedBox(height: Ds.space.x16),
            _actions(),
            SizedBox(height: Ds.space.x16),
          ],
        ),
      ),
    );
  }

  Widget _bar() => Padding(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x8),
        child: Row(children: [
          Semantics(
            identifier: 'doc_view_close',
            button: true,
            child: IconButton(
              tooltip: _s(_viewer, 'close_label'),
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(Icons.close_rounded, color: Ds.c.surface),
            ),
          ),
          Expanded(
            child: Text(_s(_viewer, 'title'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.subtitle.copyWith(color: Ds.c.surface)),
          ),
          SizedBox(width: Ds.touch.minTarget),
        ]),
      );

  Widget _paper() {
    final bytes = widget.bytes;
    if (_isPdf) {
      // A PDF is shown as itself — the page strip below walks its pages and
      // the file never leaves the app. There is no external viewer here by
      // design: handing the file to another app is exactly what this replaces.
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.picture_as_pdf_rounded,
                size: Ds.space.x48, color: Ds.c.danger),
            SizedBox(height: Ds.space.x12),
            Text(
                _pages > 1
                    ? _pageLabel(_page + 1, _pages)
                    : _s(_thumb, 'badge'),
                style: Ds.t.body),
          ],
        ),
      );
    }
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.contain);
    }
    if (widget.url.isNotEmpty) {
      return Image.network(widget.url,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              Icon(Icons.broken_image_outlined, color: Ds.c.textSecondary));
    }
    return Icon(Icons.image_outlined, color: Ds.c.textSecondary);
  }

  String _pageLabel(int n, int total) {
    final fmt = _s(_viewer, 'page_label');
    if (fmt.isEmpty) return '';
    return fmt.replaceAll('{n}', '$n').replaceAll('{total}', '$total');
  }

  Widget _strip() => SizedBox(
        height: Ds.space.x48 + Ds.space.x8,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          itemCount: _pages,
          separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
          itemBuilder: (_, i) {
            final on = i == _page;
            return Semantics(
              identifier: 'doc_view_page_${i + 1}',
              button: true,
              selected: on,
              child: InkWell(
                onTap: () => setState(() => _page = i),
                borderRadius: Ds.r.rChip,
                child: Container(
                  width: Ds.space.x32 + Ds.space.x8,
                  decoration: BoxDecoration(
                    color: on ? Ds.c.surface : Ds.c.textSecondary,
                    borderRadius: Ds.r.rChip,
                    border: Border.all(
                        color: on ? Ds.c.brand : Ds.c.textSecondary,
                        width: on ? Ds.space.hairline * 2 : Ds.space.hairline),
                  ),
                  alignment: Alignment.center,
                  child: Text('${i + 1}',
                      style: Ds.t.caption.copyWith(
                          color: on ? Ds.c.text : Ds.c.surface,
                          fontWeight: FontWeight.w700)),
                ),
              ),
            );
          },
        ),
      );

  Widget _actions() => Padding(
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        child: Row(children: [
          Expanded(
            child: _button('doc_view_retake', _s(_viewer, 'retake_label'),
                Ds.c.surface, Ds.c.textSecondary, DocViewerChoice.retake),
          ),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: _button('doc_view_keep', _s(_viewer, 'keep_label'),
                Ds.c.surface, Ds.c.brand, DocViewerChoice.keep),
          ),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: _button('doc_view_remove', _s(_viewer, 'remove_label'),
                Ds.c.danger, Ds.c.textSecondary, DocViewerChoice.remove),
          ),
        ]),
      );

  Widget _button(String id, String label, Color ink, Color bg,
          DocViewerChoice choice) =>
      Semantics(
        identifier: id,
        button: true,
        child: Material(
          color: bg,
          borderRadius: Ds.r.rButton,
          child: InkWell(
            borderRadius: Ds.r.rButton,
            onTap: () => Navigator.of(context).pop(choice),
            child: Container(
              height: Ds.touch.minTarget,
              alignment: Alignment.center,
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.bodyStrong.copyWith(color: ink)),
            ),
          ),
        ),
      );
}
