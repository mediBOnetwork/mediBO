import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import 'kyc_doc_thumb.dart';
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
///
/// CMD #1914 — the panel stopped reading like a debug log. A card is now the
/// FILE (a thumbnail, tapped to see it full), its name, ONE chip
/// (Uploaded / Checking / Verified / Rejected) and Replace beside it. A
/// rejection is ONE plain sentence the backend chose; the machine's worksheet
/// — the check rows, the tier, "Decided 10m ago · Automatic" — is folded
/// behind "See checks" and is never the first thing a pharmacist reads.
/// Underneath: what WhatsApp actually went out, and a Call/WhatsApp pair that
/// launch a URL the backend finished, customer code and document type already
/// in the message.
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

  /// Test seam for the one-tap help buttons. Returns whether the URL launched.
  @visibleForTesting
  static Future<bool> Function(String url)? launchTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  /// CMD #1914 — one tap. The URL is finished in the backend (tel:+91…,
  /// https://wa.me/…?text=… already url-encoded and already carrying the
  /// customer code and the document type); this launches the string it was
  /// handed and composes nothing.
  static Future<bool> launch(String url) {
    final t = launchTransport;
    if (t != null) return t(url);
    return launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
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

  /// Which cards have their check worksheet open. Folded away by default —
  /// that is the whole point of CMD #1914.
  final Set<String> _checksOpen = <String>{};

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
      RenderLog.write('c1914_kyc_chips',
          _items.where((e) => _s(e, 'chip_label').isNotEmpty).length);
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
        // A fresh upload starts its checks again: the worksheet from the
        // PREVIOUS attempt must not stay open over the new chip.
        _checksOpen.remove(kind);
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
          _waTimeline(),
          _help(),
        ],
      ),
    );
  }

  /// CMD #1914 — the chip. ONE word for the state of this document, and the
  /// spinner spins only while the checks are actually running, because the
  /// backend said so (`chip_busy`) rather than because this file guessed from
  /// a status string.
  Widget _chip(Map<String, dynamic> it) {
    final label = _s(it, 'chip_label').isNotEmpty
        ? _s(it, 'chip_label')
        : _s(it, 'status_label');
    final tone = _s(it, 'chip_tone').isNotEmpty
        ? _s(it, 'chip_tone')
        : _s(it, 'status_tone');
    final busy = it['chip_busy'] == true;
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration:
          BoxDecoration(color: _toneSoft(tone), borderRadius: Ds.r.rChip),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            SizedBox(
              width: Ds.space.x12,
              height: Ds.space.x12,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: _tone(tone)),
            ),
            SizedBox(width: Ds.space.x8),
          ],
          Text(label, style: Ds.t.caption.copyWith(color: _tone(tone))),
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> it) {
    final kind = _s(it, 'kind');
    final busy = _busyKind == kind;
    final plain = _s(it, 'plain_reason');
    final showChecks = _s(it, 'checks_show_label');
    final open = _checksOpen.contains(kind);
    final preview = it['preview'] is Map
        ? Map<String, dynamic>.from(it['preview'] as Map)
        : null;
    // The line under the name — what this document IS on file as. It arrives
    // JOINED (`meta_line`): which facts belong on it, in what order and with
    // what separator is a backend decision, like every other display decision.
    // An older payload without it falls back to the requirement word.
    final meta = _s(it, 'meta_line').isNotEmpty
        ? _s(it, 'meta_line')
        : _s(it, 'requirement_label');

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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KycDocThumb(preview: preview),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(it, 'label'), style: Ds.t.subtitle),
                    SizedBox(height: Ds.space.x4),
                    Text(meta, style: Ds.t.caption, maxLines: 3),
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _chip(it),
                  SizedBox(height: Ds.space.x8),
                  SizedBox(
                    height: Ds.touch.minTarget,
                    child: OutlinedButton(
                      onPressed: busy ? null : () => _pickAndUpload(it),
                      child: Text(_reuploadLabel(it)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          // CMD #1914 — ONE sentence, chosen in the backend from the check that
          // failed. The composed check list it replaced is still available, one
          // tap away, and is no longer what a pharmacist reads first.
          if (plain.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(plain, style: Ds.t.body.copyWith(color: Ds.c.danger)),
          ],
          if (showChecks.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: Ds.touch.minTarget,
                child: TextButton(
                  onPressed: () => setState(() {
                    if (open) {
                      _checksOpen.remove(kind);
                    } else {
                      _checksOpen.add(kind);
                      RenderLog.write('c1914_kyc_checks_open', 1);
                    }
                  }),
                  child: Text(open ? _s(it, 'checks_hide_label') : showChecks),
                ),
              ),
            ),
            if (open) KycVerifyBlock(verify: KycVerifyBlock.of(it)),
          ] else if (KycVerifyBlock.of(it)?['has'] != true)
            // Nothing to fold away: the block is a state line ("Reading the
            // document…"), which belongs on the surface.
            KycVerifyBlock(verify: KycVerifyBlock.of(it)),
        ],
      ),
    );
  }

  /// CMD #1914 — what WhatsApp actually went out, read-only. The frontend half
  /// of the lifecycle-WhatsApp work: `_cus_wa_timeline()` writes the same rows
  /// for the admin customer page, so the two surfaces can never disagree.
  Widget _waTimeline() {
    final t = _payload['wa_timeline'];
    if (t is! Map) return const SizedBox.shrink();
    final block = Map<String, dynamic>.from(t);
    final items = ((block['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    RenderLog.write('c1914_kyc_wa_rows', items.length);
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(block, 'title'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
              border: Border.all(color: Ds.c.divider),
            ),
            child: items.isEmpty
                ? Text(_s(block, 'empty'), style: Ds.t.bodySecondary)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < items.length; i++) ...[
                        if (i > 0) SizedBox(height: Ds.space.x12),
                        _waRow(items[i]),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _waRow(Map<String, dynamic> it) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: Ds.space.x8,
          height: Ds.space.x8,
          margin: EdgeInsets.only(top: Ds.space.x4, right: Ds.space.x12),
          decoration: BoxDecoration(
              color: _tone(_s(it, 'tone')), shape: BoxShape.circle),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(it, 'line'), style: Ds.t.body),
              if (_s(it, 'subtitle').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(_s(it, 'subtitle'), style: Ds.t.caption),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// CMD #1914 — the troubleshooting row. Both URLs arrive finished; a tap
  /// launches one. Nothing here knows the phone number.
  Widget _help() {
    final h = _payload['help'];
    if (h is! Map) return const SizedBox.shrink();
    final help = Map<String, dynamic>.from(h);
    final callUrl = _s(help, 'call_url');
    final waUrl = _s(help, 'wa_url');
    if (callUrl.isEmpty && waUrl.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c1914_kyc_help', 1);
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x24),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.bg,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(help, 'title'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
            Text(_s(help, 'note'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                if (callUrl.isNotEmpty)
                  Expanded(
                    child: SizedBox(
                      height: Ds.touch.minTarget,
                      child: OutlinedButton.icon(
                        onPressed: () => KycPanel.launch(callUrl),
                        icon: const Icon(Icons.call_outlined),
                        label: Text(_s(help, 'call_label'),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ),
                if (callUrl.isNotEmpty && waUrl.isNotEmpty)
                  SizedBox(width: Ds.space.x12),
                if (waUrl.isNotEmpty)
                  Expanded(
                    child: SizedBox(
                      height: Ds.touch.minTarget,
                      child: FilledButton.icon(
                        onPressed: () => KycPanel.launch(waUrl),
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: Text(_s(help, 'wa_label'),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
