import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import 'kyc_verify_block.dart';

/// CHANGE #705 — the ONE licence-and-documents panel.
///
/// A pharmacy completing its registration and a supplier editing its profile
/// see the same widget, because they are answering the same question: is there
/// a verified drug licence on file? Everything printed here — the title, every
/// row label, every status word, every button caption, the expiry sentence and
/// the rejection reason — arrives from `kyc_my_panel()`. This file decides
/// nothing: it picks a file, puts it in the bucket the payload named, and calls
/// `kyc_upload_register` with the path.
///
/// The payload's `items[]` are rendered IN ORDER. A `kind` this build has never
/// heard of still draws, because the label and the status came with it.
class KycPanel extends StatefulWidget {
  const KycPanel({super.key, this.onChanged});

  /// Called after a successful upload, so a host screen can refresh its own
  /// gate copy (the cart banner, the registration step) from the backend.
  final VoidCallback? onChanged;

  /// Test seam — same shape as the public screens use.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  /// Test seam for the storage put. Returns the stored path.
  @visibleForTesting
  static Future<String> Function(
      String bucket, String path, Uint8List bytes, String mime)? uploadTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  /// WHERE the file goes is the BACKEND's answer. `upload_prefix` is the folder
  /// the storage policy admits for this login; owner_id is the profile id and
  /// is a different uuid, so building the path from it had every authenticated
  /// upload refused by RLS before the RPC was ever reached. Absent prefix =
  /// no upload, not a guessed one.
  static String? storagePath(
      Map<String, dynamic> payload, String kind, String ext, int stamp) {
    final prefix = (payload['upload_prefix'] ?? '').toString().trim();
    if (prefix.isEmpty) return null;
    return '$prefix/${kind}_$stamp.$ext';
  }

  static Future<String> upload(
      String bucket, String path, Uint8List bytes, String mime) async {
    final t = uploadTransport;
    if (t != null) return t(bucket, path, bytes, mime);
    await Supabase.instance.client.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
    return path;
  }

  @override
  State<KycPanel> createState() => _KycPanelState();
}

class _KycPanelState extends State<KycPanel> {
  bool _loading = true;
  String _busyKind = '';
  Map<String, dynamic> _payload = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic>? _asMap(dynamic raw) {
    final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  List<Map<String, dynamic>> get _items => ((_payload['items'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  /// A document the checks rejected asks for a corrected one, in the backend's
  /// words (`reupload_label`). Every other state keeps the panel's own caption.
  /// Both strings are payload; neither is composed here.
  String _reuploadLabel(Map<String, dynamic> it) {
    final v = KycVerifyBlock.of(it);
    final re = (v?['reupload_label'] ?? '').toString();
    return re.isNotEmpty ? re : _s(it, 'button_label');
  }

  Future<void> _load() async {
    try {
      final map = _asMap(await KycPanel.rpc('kyc_my_panel'));
      if (!mounted) return;
      setState(() {
        _payload = map ?? const {};
        _loading = false;
      });
      RenderLog.write('c705_kyc_panel', _items.length);
      RenderLog.write('c706_kyc_checks',
          _items.where((e) => (KycVerifyBlock.of(e)?['has'] ?? false) == true).length);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickAndUpload(Map<String, dynamic> item) async {
    final kind = _s(item, 'kind');
    setState(() => _busyKind = kind);
    try {
      final picked = await FilePicker.pickFiles(withData: true, allowMultiple: false);
      final f = picked?.files.isNotEmpty == true ? picked!.files.first : null;
      final bytes = f?.bytes;
      if (bytes == null) {
        if (mounted) setState(() => _busyKind = '');
        return;
      }
      final bucket = _s(_payload, 'bucket');
      final ext = (f!.extension ?? 'jpg').toLowerCase();
      final mime = ext == 'pdf'
          ? 'application/pdf'
          : ext == 'png'
              ? 'image/png'
              : 'image/jpeg';
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final target = KycPanel.storagePath(_payload, kind, ext, stamp);
      if (target == null) {
        if (mounted) setState(() => _busyKind = '');
        return;
      }
      final path = await KycPanel.upload(bucket, target, bytes, mime);

      final res = _asMap(await KycPanel.rpc('kyc_upload_register', {
        'p_kind': kind,
        'p_path': path,
        'p_file_name': f.name,
        'p_mime': mime,
        'p_bytes': bytes.length,
      }));
      if (!mounted) return;
      setState(() {
        _busyKind = '';
        // A refusal (CHANGE #706: a duplicate licence or GSTIN) carries no
        // panel — the old one is still the truth, and the message below is
        // the backend's own sentence.
        final panel = _asMap(res?['panel']);
        if (panel != null) _payload = panel;
      });
      final msg = (res?['message'] ?? '').toString();
      if (msg.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
      RenderLog.write('c705_kyc_upload', 1);
      widget.onChanged?.call();
    } catch (_) {
      if (mounted) setState(() => _busyKind = '');
    }
  }

  Color _tone(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.warning;
    }
  }

  Color _toneSoft(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.warningSoft;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Container(
                  height: Ds.space.x48,
                  decoration:
                      BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rCard),
                ),
              ),
          ],
        ),
      );
    }

    // ok:false is a page the backend wrote, not an exception.
    if (_payload['ok'] != true) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(_payload, 'title'), style: Ds.t.title),
            SizedBox(height: Ds.space.x8),
            Text(_s(_payload, 'message'), style: Ds.t.bodySecondary),
          ],
        ),
      );
    }

    final items = _items;
    final grace = (_payload['state'] as Map?)?['grace_until'];
    return Padding(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(_payload, 'title'), style: Ds.t.title),
          SizedBox(height: Ds.space.x4),
          Text(_s(_payload, 'subtitle'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          if (items.isEmpty)
            Text(_s(_payload, 'empty_note'), style: Ds.t.bodySecondary)
          else
            for (final it in items) ...[
              _row(it),
              SizedBox(height: Ds.space.x12),
            ],
          if (grace != null) SizedBox(height: Ds.space.x4),
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> it) {
    final kind = _s(it, 'kind');
    final tone = _s(it, 'status_tone');
    final reason = _s(it, 'reason_line');
    final busy = _busyKind == kind;
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(it, 'label'), style: Ds.t.subtitle),
                    SizedBox(height: Ds.space.x4),
                    Text(_s(it, 'requirement_label'), style: Ds.t.caption),
                  ],
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                    color: _toneSoft(tone), borderRadius: Ds.r.rChip),
                child: Text(_s(it, 'status_label'),
                    style: Ds.t.caption.copyWith(color: _tone(tone))),
              ),
            ],
          ),
          if (_s(it, 'number').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text('${_s(it, 'number_label')}: ${_s(it, 'number')}',
                style: Ds.t.caption),
          ],
          if (_s(it, 'expiry_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(it, 'expiry_label'), style: Ds.t.caption),
          ],
          if (reason.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(reason, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          // CHANGE #706 — what the automatic checks made of this document. The
          // block draws itself, or nothing, from the payload alone.
          KycVerifyBlock(verify: KycVerifyBlock.of(it)),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              onPressed: busy ? null : () => _pickAndUpload(it),
              child: Text(_reuploadLabel(it)),
            ),
          ),
        ],
      ),
    );
  }
}
