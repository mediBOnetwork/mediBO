// lib/screens/delivery/rider_verification_card.dart — CHANGE #463, register row 121.
//
// "Rider identity is never verified beyond an OCR read of a document."
//
// The three checks the register row asked for, on one card the applicant works
// top to bottom: verify the mobile number with a code, add a photo of the face,
// then submit. The card decides NONE of it. `delivery_reg_verification()`
// returns the title, the hints, both button labels, the state chip and the one
// sentence that says what is still missing; every write RPC returns the same
// block back, so a tap re-renders from the server's answer rather than from a
// guess made here.
//
// It carries no wording of its own, no validation of its own, and no colour of
// its own: the chip arrives as a semantic `tone` and is resolved against the
// design tokens — register row 112 is what happens when a payload posts hex at
// a screen instead.


import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

class RiderVerificationCard extends StatefulWidget {
  /// Fired after every successful write, so the host form can re-read whatever
  /// it shows about the applicant's own state.
  final VoidCallback? onChanged;

  const RiderVerificationCard({super.key, this.onChanged});

  @override
  State<RiderVerificationCard> createState() => _RiderVerificationCardState();
}

class _RiderVerificationCardState extends State<RiderVerificationCard> {
  final _phone = TextEditingController();
  final _code = TextEditingController();

  Map<String, dynamic> _state = const {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Map<String, dynamic> _map(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const {};

  Map<String, dynamic> get _phoneBlock => _map(_state['phone']);
  Map<String, dynamic> get _selfieBlock => _map(_state['selfie']);
  Map<String, dynamic> get _statusBlock => _map(_state['status']);

  String _s(dynamic v) => v?.toString() ?? '';

  void _apply(Map<String, dynamic> m) {
    if (!mounted) return;
    setState(() {
      _state = m;
      _loading = false;
      _busy = false;
    });
    // The number the server holds wins over whatever is half-typed here.
    final v = _s(_map(m['phone'])['value']);
    if (v.isNotEmpty && _phone.text.trim().isEmpty) _phone.text = v;
    widget.onChanged?.call();
  }

  Future<void> _load() async {
    try {
      final raw =
          await Supabase.instance.client.rpc('delivery_reg_verification');
      final m = _map(raw is List ? raw.first : raw);
      _apply(m);
      RenderLog.write('c463_rider_verification',
          'open;status=${_s(_map(m['status'])['key'])};'
          'phone=${_map(m['phone'])['verified'] == true};'
          'selfie=${_map(m['selfie'])['has'] == true}');
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// Every write RPC answers with `{ok, message, state}`. The message is
  /// printed verbatim and the state replaces this card's own — success and
  /// refusal take exactly the same path, so a refusal can never leave the card
  /// showing something the server does not agree with.
  Future<void> _write(String fn, Map<String, dynamic> params) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final raw = await Supabase.instance.client.rpc(fn, params: {'p': params});
      final m = _map(raw is List ? raw.first : raw);
      final next = _map(m['state']);
      if (next.isNotEmpty) {
        _apply(next);
      } else {
        await _load();
      }
      _toast(_s(m['message']));
      RenderLog.write('c463_rider_verification', '$fn;ok=${m['ok'] == true}');
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      RenderLog.write('c463_rider_verification', '${fn}_err');
    }
  }

  // ── the selfie ────────────────────────────────────────────────────────────

  String _mimeFor(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  String _extFor(String mime) {
    if (mime.contains('png')) return 'png';
    if (mime.contains('webp')) return 'webp';
    return 'jpg';
  }

  Future<void> _captureSelfie() async {
    if (_busy) return;
    ({String name, Uint8List bytes})? shot;
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 85,
        maxWidth: 1200,
      );
      if (picked != null) {
        shot = (name: picked.name, bytes: await picked.readAsBytes());
      }
    } catch (_) {
      shot = null;
    }
    // #259's lesson: on web PWA the native chooser is the reliable path when
    // the camera source is not available at all.
    if (shot == null) {
      try {
        final res =
            await FilePicker.pickFiles(type: FileType.image, withData: true);
        final f = (res == null || res.files.isEmpty) ? null : res.files.first;
        final bytes = f?.bytes;
        if (f != null && bytes != null) shot = (name: f.name, bytes: bytes);
      } catch (_) {
        shot = null;
      }
    }
    if (shot == null) return;

    setState(() => _busy = true);
    final uid = Supabase.instance.client.auth.currentUser?.id ?? '';
    final mime = _mimeFor(shot.name);
    // The bucket is the payload's, and the folder is this account's — the RPC
    // refuses any other prefix, so the two agree by construction.
    final bucket = _s(_selfieBlock['bucket']);
    final path =
        'selfies/$uid/${DateTime.now().millisecondsSinceEpoch}.${_extFor(mime)}';
    try {
      await Supabase.instance.client.storage.from(bucket).uploadBinary(
            path,
            shot.bytes,
            fileOptions: FileOptions(contentType: mime, upsert: true),
          );
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      RenderLog.write('c463_rider_verification', 'selfie_upload_err');
      return;
    }
    setState(() => _busy = false);
    await _write('delivery_reg_selfie_save', {'path': path});
  }

  // ── tone → token ──────────────────────────────────────────────────────────

  Color _toneBg(String tone) {
    switch (tone) {
      case 'good':
        return Ds.c.successSoft;
      case 'bad':
        return Ds.c.dangerSoft;
      case 'warn':
        return Ds.c.warningSoft;
      default:
        return Ds.c.infoSoft;
    }
  }

  Color _toneFg(String tone) {
    switch (tone) {
      case 'good':
        return Ds.c.success;
      case 'bad':
        return Ds.c.danger;
      case 'warn':
        return Ds.c.warning;
      default:
        return Ds.c.info;
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
        child: Center(child: CircularProgressIndicator(color: Ds.c.brand)),
      );
    }
    if (_state['ok'] != true) {
      final msg = _s(_state['message']);
      if (msg.isEmpty) return const SizedBox.shrink();
      return _shell([Text(msg, style: Ds.t.body)]);
    }

    final phoneOk = _phoneBlock['verified'] == true;
    final selfieOk = _selfieBlock['has'] == true;
    final awaiting = _phoneBlock['awaiting_code'] == true;
    final tone = _s(_statusBlock['tone']);

    return _shell([
      Row(children: [
        Expanded(child: Text(_s(_state['title']), style: Ds.t.subtitle)),
        Container(
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12, vertical: Ds.space.x4),
          decoration: BoxDecoration(
            color: _toneBg(tone),
            borderRadius: Ds.r.rChip,
          ),
          child: Text(_s(_statusBlock['label']),
              style: Ds.t.caption.copyWith(color: _toneFg(tone))),
        ),
      ]),
      SizedBox(height: Ds.space.x4),
      Text(_s(_state['note']), style: Ds.t.caption),
      SizedBox(height: Ds.space.x24),

      // ── step one: the number ────────────────────────────────────────────
      if (phoneOk)
        _doneRow(_s(_phoneBlock['ok_label']), _s(_phoneBlock['value']))
      else ...[
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: _s(_phoneBlock['label']),
            helperText: _s(_phoneBlock['hint']),
            border: OutlineInputBorder(borderRadius: Ds.r.rButton),
          ),
        ),
        SizedBox(height: Ds.space.x12),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _write('delivery_reg_send_otp',
                        {'phone': _phone.text.trim()}),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.brand,
                  side: BorderSide(color: Ds.c.brand),
                  shape:
                      RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(_s(_phoneBlock['send_label'])),
              ),
            ),
          ),
        ]),
        if (awaiting) ...[
          SizedBox(height: Ds.space.x12),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: _s(_phoneBlock['code_label']),
              border: OutlineInputBorder(borderRadius: Ds.r.rButton),
            ),
          ),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: _busy
                  ? null
                  : () => _write('delivery_reg_verify_otp', {
                        'phone': _phone.text.trim(),
                        'code': _code.text.trim(),
                      }),
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              child: Text(_s(_phoneBlock['verify_label'])),
            ),
          ),
        ],
      ],

      SizedBox(height: Ds.space.x24),

      // ── step two: the face ──────────────────────────────────────────────
      Text(_s(_selfieBlock['label']), style: Ds.t.bodyStrong),
      SizedBox(height: Ds.space.x4),
      Text(_s(_selfieBlock['hint']), style: Ds.t.caption),
      SizedBox(height: Ds.space.x12),
      Row(children: [
        if (selfieOk) ...[
          Icon(Icons.check_circle_outline,
              size: Ds.space.x16, color: Ds.c.success),
          SizedBox(height: Ds.space.x4, width: Ds.space.x8),
        ],
        Expanded(
          child: SizedBox(
            height: Ds.touch.minTarget,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _captureSelfie,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(_s(_selfieBlock['cta'])),
              style: OutlinedButton.styleFrom(
                foregroundColor: Ds.c.brand,
                side: BorderSide(color: Ds.c.brand),
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
            ),
          ),
        ),
      ]),

      // ── what is still missing, in the backend's own sentence ────────────
      if (_s(_state['blocked_message']).isNotEmpty) ...[
        SizedBox(height: Ds.space.x16),
        _band(_s(_state['blocked_message']), 'warn'),
      ] else if (_s(_state['ready_message']).isNotEmpty) ...[
        SizedBox(height: Ds.space.x16),
        _band(_s(_state['ready_message']), 'good'),
      ],
    ]);
  }

  Widget _shell(List<Widget> children) => Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _doneRow(String label, String value) => Row(children: [
        Icon(Icons.check_circle_outline,
            size: Ds.space.x16, color: Ds.c.success),
        SizedBox(width: Ds.space.x8),
        Expanded(child: Text(label, style: Ds.t.body)),
        Text(value, style: Ds.t.caption),
      ]);

  Widget _band(String text, String tone) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: _toneBg(tone),
          borderRadius: Ds.r.rButton,
        ),
        child: Text(text, style: Ds.t.body.copyWith(color: _toneFg(tone))),
      );
}
