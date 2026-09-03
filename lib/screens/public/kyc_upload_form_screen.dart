import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../kyc/kyc_verify_block.dart';

/// CHANGE #705 — the public licence-upload page, reached from the WhatsApp
/// link `/kyc-upload/[token]`. No auth: the token in the URL is the
/// authorisation, exactly the way `/stock-update/<token>` and
/// `/feedback/<token>` already work. Forty-six approved accounts trade today
/// with no document on file and none of them will install an app to fix it.
///
/// Every string is `kyc_token_form()`'s — the title, the "For [shop]" line, the
/// deadline sentence, both hints, the submit caption, the thank-you and all
/// three refusals (unknown link / expired / already used). This file owns only
/// which file was picked.
class KycUploadFormScreen extends StatefulWidget {
  final String token;
  const KycUploadFormScreen({super.key, required this.token});

  /// Test seam, same shape as StockUpdateFormScreen.rpcTransport.
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
  State<KycUploadFormScreen> createState() => _KycUploadFormScreenState();
}

class _KycUploadFormScreenState extends State<KycUploadFormScreen> {
  bool _loading = true;
  bool _busy = false;

  Map<String, dynamic> _payload = const {};
  Map<String, dynamic>? _verify;
  String _refusal = '';
  String _error = '';
  String _done = '';

  final _numberCtl = TextEditingController();
  DateTime? _validTo;
  Uint8List? _bytes;
  String _fileName = '';
  String _ext = 'jpg';

  @override
  void initState() {
    super.initState();
    RenderLog.write(
        'c705_kyc_token_init',
        widget.token.length >= 8 ? widget.token.substring(0, 8) : widget.token);
    _load();
  }

  @override
  void dispose() {
    _numberCtl.dispose();
    super.dispose();
  }

  Map<String, dynamic>? _asMap(dynamic raw) {
    final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  String _s(String k) => (_payload[k] ?? '').toString();

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final map = _asMap(await KycUploadFormScreen.rpc(
          'kyc_token_form', {'p_token': widget.token}));
      if (!mounted) return;
      if (map == null) {
        setState(() {
          _error = 'invalid';
          _loading = false;
        });
        return;
      }
      setState(() {
        _payload = map;
        // ok:false is a page the backend wrote, not an exception.
        _error = map['ok'] == true ? '' : (map['error'] ?? 'invalid').toString();
        _loading = false;
      });
      RenderLog.write('c705_kyc_token_page', _error.isEmpty ? 1 : 0);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'invalid';
          _loading = false;
        });
      }
    }
  }

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles(withData: true, allowMultiple: false);
    final f = picked?.files.isNotEmpty == true ? picked!.files.first : null;
    if (f?.bytes == null || !mounted) return;
    setState(() {
      _bytes = f!.bytes;
      _fileName = f.name;
      _ext = (f.extension ?? 'jpg').toLowerCase();
    });
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year + 1, now.month, now.day),
      firstDate: now,
      lastDate: DateTime(now.year + 30),
    );
    if (d != null && mounted) setState(() => _validTo = d);
  }

  /// Test seam: the file picker is a platform channel, so a widget test seeds
  /// the picked bytes and submits the same code path a tap does.
  @visibleForTesting
  Future<void> submitForTest({String ext = 'jpg', String name = 'dl.jpg'}) async {
    setState(() {
      _bytes = Uint8List.fromList(const [1, 2, 3]);
      _fileName = name;
      _ext = ext;
    });
    await _submit();
  }

  Future<void> _submit() async {
    final bytes = _bytes;
    if (bytes == null) return;
    setState(() => _busy = true);
    try {
      final mime = _ext == 'pdf'
          ? 'application/pdf'
          : _ext == 'png'
              ? 'image/png'
              : 'image/jpeg';
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final path = await KycUploadFormScreen.upload(
          _s('bucket'), '${_s('upload_prefix')}/$stamp.$_ext', bytes, mime);

      final res = _asMap(await KycUploadFormScreen.rpc('kyc_token_submit', {
        'p_token': widget.token,
        'p_path': path,
        'p_number': _numberCtl.text.trim().isEmpty ? null : _numberCtl.text.trim(),
        'p_valid_to': _validTo?.toIso8601String().split('T').first,
        'p_file_name': _fileName,
      }));
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (res?['ok'] == true) {
          _done = (res?['message'] ?? '').toString();
          // CHANGE #706 — the checks that ran the moment it was written. It
          // may already say "reading the document"; that sentence is the
          // backend's too.
          final v = res?['verify'];
          _verify = v is Map ? Map<String, dynamic>.from(v) : null;
        } else {
          // CHANGE #706 — a refusal is NOT a thank-you. A duplicate licence
          // used to land in _done and draw the green tick over the backend's
          // own refusal; it now stays on the form with the sentence above it,
          // so the applicant can correct the number and send again.
          _refusal = (res?['message'] ?? '').toString();
        }
      });
      RenderLog.write('c705_kyc_token_submit', 1);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(Ds.space.x16),
              child: Container(
                padding: EdgeInsets.all(Ds.space.x16),
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rCard,
                  boxShadow: Ds.elevation.e1,
                ),
                child: _body(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 4; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Container(
                height: Ds.space.x24,
                decoration:
                    BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rChip),
              ),
            ),
        ],
      );
    }
    if (_done.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, color: Ds.c.success),
          SizedBox(height: Ds.space.x12),
          Text(_s('done_title'), style: Ds.t.title),
          SizedBox(height: Ds.space.x8),
          Text(_done, style: Ds.t.body),
          KycVerifyBlock(verify: _verify),
        ],
      );
    }
    if (_error.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_s('title'), style: Ds.t.title),
          SizedBox(height: Ds.space.x8),
          Text(_s('message'), style: Ds.t.bodySecondary),
        ],
      );
    }
    if (_payload['already_done'] == true) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_s('title'), style: Ds.t.title),
          SizedBox(height: Ds.space.x8),
          Text(_s('used_message'), style: Ds.t.bodySecondary),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_s('title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x4),
        Text(_s('for_line'), style: Ds.t.bodySecondary),
        if (_refusal.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
                color: Ds.c.dangerSoft, borderRadius: Ds.r.rCard),
            child: Text(_refusal,
                style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ),
        ],
        SizedBox(height: Ds.space.x12),
        Text(_s('subtitle'), style: Ds.t.body),
        if (_s('deadline_line').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(_s('deadline_line'),
              style: Ds.t.caption.copyWith(color: Ds.c.warning)),
        ],
        SizedBox(height: Ds.space.x24),
        TextField(
          controller: _numberCtl,
          decoration: InputDecoration(
            labelText: _s('number_label'),
            hintText: _s('number_hint'),
          ),
        ),
        SizedBox(height: Ds.space.x16),
        SizedBox(
          height: Ds.touch.minTarget,
          child: OutlinedButton.icon(
            onPressed: _pickExpiry,
            icon: const Icon(Icons.event),
            label: Text(_validTo == null
                ? _s('expiry_hint')
                : '${_s('expiry_hint')}: '
                    '${_validTo!.toIso8601String().split('T').first}'),
          ),
        ),
        SizedBox(height: Ds.space.x16),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: OutlinedButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.attach_file),
            label: Text(_fileName.isEmpty ? _s('file_hint') : _fileName),
          ),
        ),
        SizedBox(height: Ds.space.x24),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: FilledButton(
            onPressed: (_busy || _bytes == null) ? null : _submit,
            child: Text(_s('submit_label')),
          ),
        ),
      ],
    );
  }
}
