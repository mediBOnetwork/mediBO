// CMD #2128 — the upload sheet (approved design, Image B · 1).
//
// Four ways to add a paper, and the sheet knows none of them by name: the
// row's own `sheet` block carries its title, its line and the options in the
// order they must appear, each with its label, its hint, its badge and the
// platform capability it needs. This file draws that list and returns the key
// of whichever one was tapped.
import 'package:flutter/material.dart';

import '../design_tokens.dart';

Map<String, dynamic> _m(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

/// Opens the sheet and answers with the chosen option key ('scan', 'camera',
/// 'gallery', 'files'), or null when it was dismissed.
///
/// [capabilities] is what this device can actually do. An option whose `needs`
/// is not in the set is dropped — the list is never rewritten, only filtered.
Future<String?> showDocUploadSheet(
  BuildContext context, {
  required Map<String, dynamic> sheet,
  required Set<String> capabilities,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (ctx) => DocUploadSheet(sheet: sheet, capabilities: capabilities),
  );
}

class DocUploadSheet extends StatelessWidget {
  const DocUploadSheet(
      {super.key, required this.sheet, required this.capabilities});

  final Map<String, dynamic> sheet;
  final Set<String> capabilities;

  List<Map<String, dynamic>> get _options => ((sheet['options'] as List?) ??
          const [])
      .map(_m)
      .where((o) {
        final needs = _s(o, 'needs');
        return needs.isEmpty || capabilities.contains(needs);
      })
      .toList();

  @override
  Widget build(BuildContext context) {
    final options = _options;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: Ds.space.x48,
                height: Ds.space.x4,
                decoration: BoxDecoration(
                    color: Ds.c.divider, borderRadius: Ds.r.rChip),
              ),
            ),
            SizedBox(height: Ds.space.x24),
            Text(_s(sheet, 'title'), style: Ds.t.title),
            if (_s(sheet, 'subtitle').isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(_s(sheet, 'subtitle'), style: Ds.t.bodySecondary),
            ],
            SizedBox(height: Ds.space.x16),
            for (var i = 0; i < options.length; i++) ...[
              if (i > 0) SizedBox(height: Ds.space.x12),
              _option(context, options[i]),
            ],
          ],
        ),
      ),
    );
  }

  IconData _icon(String key) => switch (key) {
        'scan' => Icons.document_scanner_outlined,
        'camera' => Icons.photo_camera_outlined,
        'gallery' => Icons.photo_library_outlined,
        _ => Icons.folder_outlined,
      };

  Widget _option(BuildContext context, Map<String, dynamic> o) {
    final key = _s(o, 'key');
    final best = o['recommended'] == true;
    final badge = _s(o, 'badge');
    return Semantics(
      identifier: 'doc_opt_$key',
      button: true,
      child: Material(
        color: best ? Ds.c.brandSoft : Ds.c.surface,
        borderRadius: Ds.r.rCard,
        child: InkWell(
          borderRadius: Ds.r.rCard,
          onTap: () => Navigator.of(context).pop(key),
          child: Container(
            constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: BoxDecoration(
              borderRadius: Ds.r.rCard,
              border: Border.all(color: best ? Ds.c.brand : Ds.c.divider),
            ),
            child: Row(children: [
              Container(
                width: Ds.space.x48,
                height: Ds.space.x48,
                decoration: BoxDecoration(
                    color: best ? Ds.c.surface : Ds.c.bg,
                    borderRadius: Ds.r.rChip),
                alignment: Alignment.center,
                child: Icon(_icon(key),
                    color: best ? Ds.c.brand : Ds.c.textSecondary),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_s(o, 'label'), style: Ds.t.bodyStrong),
                    if (_s(o, 'hint').isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(_s(o, 'hint'), style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
              if (badge.isNotEmpty) ...[
                SizedBox(width: Ds.space.x8),
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                      color: Ds.c.successSoft, borderRadius: Ds.r.rChip),
                  child: Text(badge,
                      style: Ds.t.caption.copyWith(
                          color: Ds.c.brand, fontWeight: FontWeight.w700)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
