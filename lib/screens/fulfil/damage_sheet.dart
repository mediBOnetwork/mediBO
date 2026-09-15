import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #709 — "this broke while we were handling it".
///
/// Two surfaces, one contract. The picker lists the order's lines from
/// `damage_lines()` — with what is LEFT on each after everything already
/// logged, and whether this stage may be logged at at all — and the sheet
/// takes the quantity, the reason and (when the reason says so) a photo, then
/// calls `damage_log()`.
///
/// Nothing here decides anything: the stage gate, the remaining quantity, the
/// reason chips, whether a photo is required and every word on the screen all
/// arrive in the payload. The photo goes to the folder the BACKEND names
/// (`upload_prefix`) — the lesson from #705, where a client-built path was
/// refused by storage RLS before the RPC was ever reached.
class DamageSheet extends StatefulWidget {
  final String orderItemId;
  final String stageKey;

  const DamageSheet({super.key, required this.orderItemId, this.stageKey = 'count'});

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

  /// WHERE the photo goes is the backend's answer, never a path built here.
  static String? photoPath(
      Map<String, dynamic> payload, String ext, int stamp) {
    final prefix = (payload['upload_prefix'] ?? '').toString().trim();
    if (prefix.isEmpty) return null;
    return '$prefix/damage_$stamp.$ext';
  }

  @override
  State<DamageSheet> createState() => _DamageSheetState();
}

class _DamageSheetState extends State<DamageSheet> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  bool _busy = false;
  String _reason = '';
  String _photo = '';
  String _photoName = '';
  final TextEditingController _qty = TextEditingController();
  final TextEditingController _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  static Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  String _s(String k) => (_p[k] ?? '').toString();

  Future<void> _load() async {
    try {
      final res = await DamageSheet.rpc('damage_sheet', {
        'p_order_item_id': widget.orderItemId,
        'p_stage': widget.stageKey,
      });
      if (!mounted) return;
      setState(() {
        _p = _asMap(res);
        _loading = false;
      });
      RenderLog.write('c709_damage_sheet', 1);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _reasons =>
      ((_p['reasons'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  bool get _needsPhoto {
    for (final r in _reasons) {
      if ((r['code'] ?? '').toString() == _reason) {
        return r['needs_photo'] == true;
      }
    }
    return false;
  }

  double get _qtyValue => double.tryParse(_qty.text.trim()) ?? 0;

  double get _remaining {
    final v = _p['remaining_qty'];
    if (v is num) return v.toDouble();
    return double.tryParse((v ?? '').toString()) ?? 0;
  }

  bool get _canSubmit =>
      !_busy &&
      _p['can_log'] == true &&
      _reason.isNotEmpty &&
      _qtyValue > 0 &&
      _qtyValue <= _remaining &&
      (!_needsPhoto || _photo.isNotEmpty);

  Future<void> _pickPhoto() async {
    final picked = await FilePicker.pickFiles(withData: true, allowMultiple: false);
    final file = (picked?.files.isNotEmpty ?? false) ? picked!.files.first : null;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    final ext = (file.extension ?? 'jpg').toLowerCase();
    final target = DamageSheet.photoPath(
        _p, ext, DateTime.now().millisecondsSinceEpoch);
    if (target == null) return;
    setState(() => _busy = true);
    try {
      final path = await DamageSheet.upload(_s('bucket'), target, bytes,
          ext == 'png' ? 'image/png' : 'image/jpeg');
      if (!mounted) return;
      setState(() {
        _photo = path;
        _photoName = file.name;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _busy = true);
    final res = _asMap(await DamageSheet.rpc('damage_log', {
      'p_order_item_id': widget.orderItemId,
      'p_qty': _qtyValue,
      'p_reason_code': _reason,
      'p_stage': _s('stage_key').isEmpty ? widget.stageKey : _s('stage_key'),
      'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      'p_photo_path': _photo.isEmpty ? null : _photo,
    }));
    if (!mounted) return;
    setState(() => _busy = false);
    final msg = (res['message'] ?? '').toString();
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor:
            res['ok'] == true ? Ds.c.brand : Ds.c.danger,
      ));
    }
    if (res['ok'] == true) {
      RenderLog.write('c709_damage_log', 1);
      Navigator.of(context).pop(true);
    } else {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Container(
                    height: Ds.space.x48,
                    decoration:
                        BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rCard)),
              ),
          ],
        ),
      );
    }

    if (_p['ok'] != true || _p['can_log'] != true) {
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_s('title'), style: Ds.t.title),
            SizedBox(height: Ds.space.x8),
            Text(_s('message'), style: Ds.t.body),
          ]),
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_s('title'), style: Ds.t.title),
              SizedBox(height: Ds.space.x4),
              Text(_s('subtitle'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              Text(_s('product_name'), style: Ds.t.body),
              SizedBox(height: Ds.space.x16),
              Text(_s('qty_label'), style: Ds.t.body),
              SizedBox(height: Ds.space.x8),
              TextField(
                controller: _qty,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(hintText: _s('remaining_qty')),
              ),
              SizedBox(height: Ds.space.x16),
              Text(_s('reason_label'), style: Ds.t.body),
              SizedBox(height: Ds.space.x8),
              Wrap(
                spacing: Ds.space.x8,
                runSpacing: Ds.space.x8,
                children: [
                  for (final r in _reasons)
                    ChoiceChip(
                      label: Text((r['label'] ?? '').toString()),
                      selected: _reason == (r['code'] ?? '').toString(),
                      onSelected: (_) =>
                          setState(() => _reason = (r['code'] ?? '').toString()),
                    ),
                ],
              ),
              SizedBox(height: Ds.space.x16),
              Text(_s('photo_label'), style: Ds.t.body),
              if (_needsPhoto) ...[
                SizedBox(height: Ds.space.x4),
                Text(_s('photo_hint'), style: Ds.t.caption),
              ],
              SizedBox(height: Ds.space.x8),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _pickPhoto,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: Text(_photoName.isEmpty ? _s('photo_label') : _photoName),
                ),
              ),
              SizedBox(height: Ds.space.x16),
              Text(_s('note_label'), style: Ds.t.body),
              SizedBox(height: Ds.space.x8),
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: InputDecoration(hintText: _s('note_hint')),
              ),
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.space.x48,
                child: FilledButton(
                  onPressed: _canSubmit ? _submit : null,
                  child: Text(_s('submit_label')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line picker a worker meets first: the order's lines, what is left on
/// each, and the ones this stage may be logged against. Rendered in payload
/// order — the backend already sorted it.
class DamageLinePicker extends StatefulWidget {
  final String orderId;
  final String stageKey;

  const DamageLinePicker(
      {super.key, required this.orderId, this.stageKey = 'count'});

  @override
  State<DamageLinePicker> createState() => _DamageLinePickerState();
}

class _DamageLinePickerState extends State<DamageLinePicker> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await DamageSheet.rpc('damage_lines',
          {'p_order_id': widget.orderId, 'p_stage': widget.stageKey});
      if (!mounted) return;
      setState(() {
        _p = res is Map ? Map<String, dynamic>.from(res) : const {};
        _loading = false;
      });
      RenderLog.write('c709_damage_lines',
          ((_p['rows'] as List?)?.length ?? 0).toString());
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Container(
            height: Ds.space.x48,
            decoration: BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rCard)),
      );
    }
    final rows = ((_p['rows'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text((_p['title'] ?? '').toString(), style: Ds.t.title),
            if ((_p['message'] ?? '').toString().isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text((_p['message'] ?? '').toString(), style: Ds.t.body),
            ],
            SizedBox(height: Ds.space.x16),
            if (rows.isEmpty)
              Text((_p['empty_note'] ?? '').toString(), style: Ds.t.caption)
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in rows)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text((r['product_name'] ?? '').toString(),
                            style: Ds.t.body),
                        subtitle: Text(
                          [
                            (r['supplier'] ?? '').toString(),
                            (r['line_note'] ?? '').toString(),
                          ].where((e) => e.isNotEmpty).join(' · '),
                          style: Ds.t.caption,
                        ),
                        enabled: r['can_log'] == true,
                        onTap: r['can_log'] == true
                            ? () async {
                                final done = await showDamageSheet(
                                    context,
                                    (r['order_item_id'] ?? '').toString(),
                                    (_p['stage_key'] ?? 'count').toString());
                                if (!context.mounted) return;
                                if (done) Navigator.of(context).pop(true);
                                await _load();
                              }
                            : null,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One line's sheet.
Future<bool> showDamageSheet(BuildContext context, String orderItemId,
    [String stage = 'count']) async {
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    builder: (_) => DamageSheet(orderItemId: orderItemId, stageKey: stage),
  );
  return done == true;
}

/// The order's lines, then one of them.
Future<bool> showDamagePicker(BuildContext context, String orderId,
    [String stage = 'count']) async {
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    builder: (_) => DamageLinePicker(orderId: orderId, stageKey: stage),
  );
  return done == true;
}
