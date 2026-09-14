// CMD #1937 — Customer Documents: ONE payload, three surfaces.
//
// `customer_documents_screen(p_customer_id)` answers everything on this page:
// which documents exist, what each is called, the thumbnail's bucket and path,
// the number line, the valid-till line, the status chip and its tone, the
// rejection sentence, the header summary, whether the account may be approved
// — and, per row, exactly which ACTIONS this viewer may take. The widget below
// decides nothing: it paints `actions[]` in the order the backend sent them and
// calls the RPC each one names.
//
// Three callers, one file:
//   • admin / zone partner → CustomerDocumentsScreen(customerId: …)
//   • the shop itself      → CustomerDocumentsScreen() (null customer = me)
//   • My Profile           → CustomerDocumentsPanel(embedded: true) inline
//
// Approve / Reject go to kyc_review_set(), which zone-checks, stamps
// verified_by and fires kyc_document_rejected over WhatsApp (#1936). This file
// never writes a verdict itself.
//
// Mobile-first: the row is a 56 px thumbnail, a text column that wraps, and a
// chip — laid out at 360 px first. Actions sit UNDER the row in a wrap, so a
// fourth button never squeezes the title into vertical text.
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

/// Every backend call this surface makes, behind a test seam.
class CustomerDocumentsTransport {
  CustomerDocumentsTransport._();

  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)? rpc;

  @visibleForTesting
  static Future<String> Function(
      String bucket, String path, Uint8List bytes, String mime)? upload;

  /// Returns a readable URL for a private object, or '' when there is none.
  @visibleForTesting
  static Future<String> Function(String bucket, String path)? signedUrl;

  /// Returns the chosen file, or null when the picker was cancelled.
  @visibleForTesting
  static Future<({String name, String ext, Uint8List bytes})?> Function(
      bool imagesOnly)? pick;

  static Future<dynamic> call(String fn, [Map<String, dynamic>? params]) {
    final t = rpc;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  static Future<String> put(
      String bucket, String path, Uint8List bytes, String mime) async {
    final t = upload;
    if (t != null) return t(bucket, path, bytes, mime);
    await Supabase.instance.client.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
    return path;
  }

  static Future<String> sign(String bucket, String path) async {
    final t = signedUrl;
    if (t != null) return t(bucket, path);
    if (bucket.isEmpty || path.isEmpty) return '';
    try {
      return await Supabase.instance.client.storage
          .from(bucket)
          .createSignedUrl(path, 600);
    } catch (_) {
      return '';
    }
  }

  static Future<({String name, String ext, Uint8List bytes})?> choose(
      bool imagesOnly) async {
    final t = pick;
    if (t != null) return t(imagesOnly);
    final res = await FilePicker.pickFiles(
      withData: true,
      allowMultiple: false,
      type: imagesOnly ? FileType.image : FileType.any,
    );
    final f = res?.files.isNotEmpty == true ? res!.files.first : null;
    final bytes = f?.bytes;
    if (f == null || bytes == null) return null;
    return (
      name: f.name,
      ext: (f.extension ?? 'jpg').toLowerCase(),
      bytes: bytes
    );
  }
}

Map<String, dynamic>? _asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

List<Map<String, dynamic>> _asRows(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

String _s(Map<String, dynamic>? m, String k) => (m?[k] ?? '').toString();
bool _b(Map<String, dynamic>? m, String k) => m?[k] == true;

Color _toneBg(String tone) => switch (tone) {
      'success' => Ds.c.successSoft,
      'danger' => Ds.c.dangerSoft,
      'warning' => Ds.c.warningSoft,
      'info' => Ds.c.infoSoft,
      'brand' => Ds.c.brandSoft,
      _ => Ds.c.bg,
    };

Color _toneFg(String tone) => switch (tone) {
      'success' => Ds.c.success,
      'danger' => Ds.c.danger,
      'warning' => Ds.c.warning,
      'info' => Ds.c.info,
      'brand' => Ds.c.brand,
      _ => Ds.c.textSecondary,
    };

/// The full-screen surface. `customerId` null = the signed-in shop's own
/// documents, which needs no reviewer role at all.
class CustomerDocumentsScreen extends StatelessWidget {
  final String? customerId;

  const CustomerDocumentsScreen({super.key, this.customerId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: CustomerDocumentsPanel(customerId: customerId, embedded: false),
      ),
    );
  }
}

/// The body. `embedded: true` drops the title block and the scroll view so the
/// same rows can sit inside another page's card (My Profile).
class CustomerDocumentsPanel extends StatefulWidget {
  final String? customerId;
  final bool embedded;

  const CustomerDocumentsPanel({
    super.key,
    this.customerId,
    this.embedded = false,
  });

  @override
  State<CustomerDocumentsPanel> createState() =>
      _CustomerDocumentsPanelState();
}

class _CustomerDocumentsPanelState extends State<CustomerDocumentsPanel> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String _error = '';
  String _busyKind = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final raw = await CustomerDocumentsTransport.call(
          'customer_documents_screen', {'p_customer_id': widget.customerId});
      final m = _asMap(raw is List && raw.isNotEmpty ? raw.first : raw);
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_b(m, 'ok')) {
          _payload = m;
          _error = '';
        } else {
          _payload = m;
          _error = _s(m, 'message');
        }
      });
      if (_b(m, 'ok')) {
        RenderLog.write('c1937_doc_rows', _asRows(m?['rows']).length);
        RenderLog.write(
            'c1937_doc_review', _b(m, 'can_review') ? 'true' : 'false');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _review(
      Map<String, dynamic> row, String status, String reason) async {
    setState(() => _busyKind = _s(row, 'kind'));
    try {
      final raw = await CustomerDocumentsTransport.call('kyc_review_set', {
        'p_doc_id': _s(row, 'doc_id'),
        'p_status': status,
        'p_reason': reason.isEmpty ? null : reason,
      });
      final res = _asMap(raw is List && raw.isNotEmpty ? raw.first : raw);
      if (!mounted) return;
      setState(() => _busyKind = '');
      _toast(_s(res, 'message'));
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busyKind = '');
      _toast(_s(_payload, 'err_upload'));
    }
  }

  Future<void> _upload(Map<String, dynamic> row, bool camera) async {
    final kind = _s(row, 'kind');
    final picked = await CustomerDocumentsTransport.choose(camera);
    if (picked == null) return;
    setState(() => _busyKind = kind);
    try {
      final pathRaw = await CustomerDocumentsTransport.call(
          'customer_doc_upload_path', {
        'p_customer_id': _s(_payload, 'customer_id'),
        'p_kind': kind,
        'p_ext': picked.ext,
      });
      final p = _asMap(pathRaw is List && pathRaw.isNotEmpty
          ? pathRaw.first
          : pathRaw);
      if (!_b(p, 'ok')) {
        if (!mounted) return;
        setState(() => _busyKind = '');
        _toast(_s(p, 'message'));
        return;
      }
      final mime = switch (picked.ext) {
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        _ => 'image/jpeg',
      };
      final stored = await CustomerDocumentsTransport.put(
          _s(p, 'bucket'), _s(p, 'path'), picked.bytes, mime);
      final regRaw = await CustomerDocumentsTransport.call(
          'customer_doc_upload_register', {
        'p_customer_id': _s(_payload, 'customer_id'),
        'p_kind': kind,
        'p_path': stored,
        'p_file_name': picked.name,
        'p_mime': mime,
        'p_bytes': picked.bytes.length,
      });
      final res =
          _asMap(regRaw is List && regRaw.isNotEmpty ? regRaw.first : regRaw);
      if (!mounted) return;
      setState(() => _busyKind = '');
      _toast(_s(res, 'message'));
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busyKind = '');
      _toast(_s(_payload, 'err_upload'));
    }
  }

  Future<void> _act(Map<String, dynamic> row, String key) async {
    switch (key) {
      case 'approve':
        await _review(row, 'verified', '');
        return;
      case 'reject':
        final reason = await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Ds.c.surface,
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
          builder: (_) => _RejectSheet(payload: _payload ?? const {}),
        );
        if (reason != null && reason.isNotEmpty) {
          await _review(row, 'rejected', reason);
        }
        return;
      case 'upload':
      case 'replace':
        final camera = await showModalBottomSheet<bool>(
          context: context,
          backgroundColor: Ds.c.surface,
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
          builder: (_) => _SourceSheet(
            payload: _payload ?? const {},
            row: row,
          ),
        );
        if (camera != null) await _upload(row, camera);
        return;
    }
  }

  void _openViewer(Map<String, dynamic> row) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _DocViewer(payload: _payload ?? const {}, row: row),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _DocSkeleton();

    if (_error.isNotEmpty) {
      return _ErrorState(
        message: _error,
        retryLabel: _s(_payload, 'retry_label'),
        onRetry: _load,
      );
    }

    final p = _payload ?? const <String, dynamic>{};
    final rows = _asRows(p['rows']);

    final body = <Widget>[
      _SummaryStrip(
        line: _s(p, 'summary_line'),
        tone: _s(p, 'summary_tone'),
        approve: _asMap(p['approve']),
        canReview: _b(p, 'can_review'),
      ),
      if (rows.isEmpty)
        _EmptyState(note: _s(p, 'empty_note'))
      else
        for (final row in rows)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: _DocRow(
              row: row,
              busy: _busyKind == _s(row, 'kind'),
              onThumbnail: () => _openViewer(row),
              onAction: (k) => _act(row, k),
            ),
          ),
    ];

    if (widget.embedded) {
      // Embedded, the panel sits in a host page's own scroll view, so it keeps
      // the page's 16 px gutter and adds no scroll view of its own.
      return Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x12, Ds.space.x16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: body,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: _s(p, 'title'),
          subtitle: _s(p, 'customer_name').isEmpty
              ? _s(p, 'subtitle')
              : _s(p, 'customer_name'),
          onClose: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
              children: body,
            ),
          ),
        ),
      ],
    );
  }
}

/// Title row. A back affordance that is always a pop, never a route guess.
class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onClose;

  const _Header({
    required this.title,
    required this.subtitle,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x8, Ds.space.x8, Ds.space.x16, Ds.space.x8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: Ds.touch.minTarget,
            height: Ds.touch.minTarget,
            child: IconButton(
              icon: const Icon(Icons.arrow_back),
              color: Ds.c.text,
              onPressed: onClose,
            ),
          ),
          SizedBox(width: Ds.space.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Ds.t.title),
                if (subtitle.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(subtitle, style: Ds.t.caption),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "3 of 5 verified · DL 20B missing" — one sentence, built in SQL, printed
/// verbatim. The Approve-account button underneath is the #1935 gate: enabled
/// only while `approve.can` is true, and its label and refusal both arrive on
/// the payload.
class _SummaryStrip extends StatelessWidget {
  final String line;
  final String tone;
  final Map<String, dynamic>? approve;
  final bool canReview;

  const _SummaryStrip({
    required this.line,
    required this.tone,
    required this.approve,
    required this.canReview,
  });

  @override
  Widget build(BuildContext context) {
    final gateLabel = _s(approve, 'label');
    final gateReason = _s(approve, 'reason');
    final can = _b(approve, 'can');
    final approved = _b(approve, 'is_approved');
    final showGate = canReview && gateLabel.isNotEmpty && !approved;

    if (line.isEmpty && !showGate) return const SizedBox.shrink();

    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x24),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: _toneBg(tone),
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (line.isNotEmpty)
            Text(line, style: Ds.t.bodyStrong.copyWith(color: _toneFg(tone))),
          if (showGate) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                // Disabled is the backend's answer, and the sentence below says
                // why — never a button that fails after the tap.
                onPressed: can ? () {} : null,
                child: Text(gateLabel),
              ),
            ),
            if (!can && gateReason.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(gateReason, style: Ds.t.caption),
            ],
          ],
        ],
      ),
    );
  }
}

/// One document: a 56 px thumbnail, the text column, the chip — then the
/// actions the backend allowed, wrapped so they never crush the title.
class _DocRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool busy;
  final VoidCallback onThumbnail;
  final ValueChanged<String> onAction;

  const _DocRow({
    required this.row,
    required this.busy,
    required this.onThumbnail,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final actions = _asRows(row['actions']);
    final numberLine = _s(row, 'number_line');
    final validLine = _s(row, 'valid_line');
    final reasonLine = _s(row, 'reason_line');
    final sourceLine = _s(row, 'source_line');

    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumbnail(row: row, onTap: onThumbnail),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(row, 'label'), style: Ds.t.subtitle),
                    SizedBox(height: Ds.space.x4),
                    Text(
                      numberLine.isEmpty
                          ? _s(row, 'requirement_label')
                          : numberLine,
                      style: Ds.t.caption,
                    ),
                    if (validLine.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(validLine, style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x8),
              _Chip(
                label: _s(row, 'status_label'),
                tone: _s(row, 'status_tone'),
              ),
            ],
          ),
          if (reasonLine.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.dangerSoft,
                borderRadius: Ds.r.rButton,
              ),
              child: Text(reasonLine,
                  style: Ds.t.body.copyWith(color: Ds.c.danger)),
            ),
          ],
          if (sourceLine.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(sourceLine, style: Ds.t.caption),
          ],
          if (busy) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              height: Ds.touch.minTarget,
              child: const Center(child: CircularProgressIndicator()),
            ),
          ] else if (actions.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                for (final a in actions)
                  _ActionButton(action: a, onTap: () => onAction(_s(a, 'key'))),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The thumbnail. 56 px, square, tappable into the viewer. A private object
/// needs a signed URL, so it resolves one and holds the placeholder until it
/// lands; no URL is a neutral tile, never a broken-image glyph.
class _Thumbnail extends StatefulWidget {
  final Map<String, dynamic> row;
  final VoidCallback onTap;

  const _Thumbnail({required this.row, required this.onTap});

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  String _url = '';

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    if (!_b(widget.row, 'has_file') || !_b(widget.row, 'is_image')) return;
    final u = await CustomerDocumentsTransport.sign(
        _s(widget.row, 'bucket'), _s(widget.row, 'path'));
    if (mounted && u.isNotEmpty) setState(() => _url = u);
  }

  @override
  Widget build(BuildContext context) {
    final side = Ds.touch.listRowMinHeight;
    final hasFile = _b(widget.row, 'has_file');
    return InkWell(
      onTap: hasFile ? widget.onTap : null,
      borderRadius: Ds.r.rButton,
      child: Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          color: Ds.c.bg,
          borderRadius: Ds.r.rButton,
          border: Border.all(color: Ds.c.divider, width: Ds.space.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: _url.isNotEmpty
            ? Image.network(_url, fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(hasFile))
            : _placeholder(hasFile),
      ),
    );
  }

  Widget _placeholder(bool hasFile) => Center(
        child: Icon(
          hasFile ? Icons.description_outlined : Icons.add_photo_alternate_outlined,
          color: Ds.c.textSecondary,
        ),
      );
}

/// A backend-described button: the label, the tone and whether it is filled all
/// come off the action row.
class _ActionButton extends StatelessWidget {
  final Map<String, dynamic> action;
  final VoidCallback onTap;

  const _ActionButton({required this.action, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = _s(action, 'label');
    final tone = _s(action, 'tone');
    final filled = _s(action, 'style') == 'filled';
    final fg = _toneFg(tone);

    return SizedBox(
      height: Ds.touch.minTarget,
      child: filled
          ? FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(backgroundColor: fg),
              child: Text(label),
            )
          : OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                foregroundColor: fg,
                side: BorderSide(color: fg),
              ),
              child: Text(label),
            ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String tone;

  const _Chip({required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: _toneBg(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label, style: Ds.t.caption.copyWith(color: _toneFg(tone))),
    );
  }
}

/// The reason sheet. Reject stays disabled until there is a sentence, because
/// kyc_review_set refuses a reasonless rejection — the button mirrors the rule
/// instead of discovering it.
class _RejectSheet extends StatefulWidget {
  final Map<String, dynamic> payload;

  const _RejectSheet({required this.payload});

  @override
  State<_RejectSheet> createState() => _RejectSheetState();
}

class _RejectSheetState extends State<_RejectSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payload;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Ds.space.x16,
        Ds.space.x24,
        Ds.space.x16,
        Ds.space.x16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_s(p, 'reject_title'), style: Ds.t.title),
          SizedBox(height: Ds.space.x8),
          Text(_s(p, 'reject_hint'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          TextField(
            controller: _ctrl,
            minLines: 2,
            maxLines: 4,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: _s(p, 'reject_label')),
          ),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Ds.c.danger),
              onPressed: _ctrl.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, _ctrl.text.trim()),
              child: Text(_s(p, 'reject_submit')),
            ),
          ),
          SizedBox(height: Ds.space.x8),
          SizedBox(
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_s(p, 'reject_cancel')),
            ),
          ),
        ],
      ),
    );
  }
}

/// Camera or file. `camera_only` on the row removes the file option entirely —
/// a shop photo taken from the gallery is not a shop photo.
class _SourceSheet extends StatelessWidget {
  final Map<String, dynamic> payload;
  final Map<String, dynamic> row;

  const _SourceSheet({required this.payload, required this.row});

  @override
  Widget build(BuildContext context) {
    final cameraOnly = _b(row, 'camera_only');
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_s(row, 'sheet_title'), style: Ds.t.title),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            height: Ds.touch.minTarget,
            child: FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(_s(payload, 'upload_camera')),
            ),
          ),
          if (!cameraOnly) ...[
            SizedBox(height: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, false),
                icon: const Icon(Icons.attach_file),
                label: Text(_s(payload, 'upload_file')),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Full-screen viewer with pinch/double-tap zoom. A non-image (a PDF) is not
/// forced into an Image widget — the file name is shown instead of a broken
/// glyph.
class _DocViewer extends StatefulWidget {
  final Map<String, dynamic> payload;
  final Map<String, dynamic> row;

  const _DocViewer({required this.payload, required this.row});

  @override
  State<_DocViewer> createState() => _DocViewerState();
}

class _DocViewerState extends State<_DocViewer> {
  String _url = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final u = await CustomerDocumentsTransport.sign(
        _s(widget.row, 'bucket'), _s(widget.row, 'path'));
    if (!mounted) return;
    setState(() {
      _url = u;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isImage = _b(widget.row, 'is_image');
    return Scaffold(
      backgroundColor: Ds.c.text,
      appBar: AppBar(
        backgroundColor: Ds.c.text,
        foregroundColor: Ds.c.surface,
        title: Text(_s(widget.row, 'label')),
        actions: [
          IconButton(
            tooltip: _s(widget.payload, 'viewer_close'),
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : (_url.isNotEmpty && isImage
                ? InteractiveViewer(
                    minScale: 1,
                    maxScale: 5,
                    child: Image.network(_url, fit: BoxFit.contain),
                  )
                : Padding(
                    padding: EdgeInsets.all(Ds.space.x24),
                    child: Text(
                      _s(widget.row, 'file_name').isEmpty
                          ? _s(widget.payload, 'viewer_title')
                          : _s(widget.row, 'file_name'),
                      style: Ds.t.body.copyWith(color: Ds.c.surface),
                      textAlign: TextAlign.center,
                    ),
                  )),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String note;

  const _EmptyState({required this.note});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
      ),
      child: Text(note, style: Ds.t.bodySecondary, textAlign: TextAlign.center),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  const _ErrorState({
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(message, style: Ds.t.body, textAlign: TextAlign.center),
          if (retryLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: onRetry,
                child: Text(retryLabel),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The page's own shape while the RPC answers — not a bare spinner.
class _DocSkeleton extends StatelessWidget {
  const _DocSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget block(double h) => Container(
          margin: EdgeInsets.only(bottom: Ds.space.x12),
          height: h,
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
          ),
        );
    return Padding(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          block(Ds.space.x48 + Ds.space.x24),
          block(Ds.space.x48 + Ds.space.x48),
          block(Ds.space.x48 + Ds.space.x48),
          block(Ds.space.x48 + Ds.space.x48),
        ],
      ),
    );
  }
}
