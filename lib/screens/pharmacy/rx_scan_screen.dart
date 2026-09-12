// CMD #418 — the counter screen: the prescription beside the bill it produced.
//
// THE ONE RULE THIS SCREEN EXISTS TO ENFORCE: the human always confirms. There
// is no path from a photo to a bill that does not pass through a person looking
// at both at once. That is why the layout is a split — the photo on one side,
// the draft on the other — and why a line only starts ticked when the BACKEND
// said `default_on`, which it says only for a line this shop can actually fill.
// An unreadable line, an unmatched line and a substitute line all start
// unticked, so the counter has to make each of those decisions deliberately.
//
// THIS FILE ADDS UP NOTHING. Every rupee, every state word, every tone, every
// "Oldest batch first" and every refusal sentence arrives finished from
// `rx_scan_detail()`. It does not decide what matched, which batch to use, or
// what anything costs — `pos_commit_sale` prices the confirmed lines, exactly
// as it prices every other retail bill.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../design_tokens.dart';
import '../../services/rx_scan_api.dart';
import '../../utils/render_log.dart';
import 'pharmacy_variance_screen.dart' show ShieldCard, ShieldChip, ShieldSkeleton, ShieldRefusal;
import 'pharmacy_expiry_screen.dart' show toneColor;

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

/// Minted on the device before the network is known to exist — the same offline
/// key #411's counter uses, so a replayed confirm resolves to the bill it
/// already wrote instead of a second one.
String _newActionId() {
  final r = Random.secure();
  String h(int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  return '${h(8)}-${h(4)}-4${h(3)}-'
      '${(8 + r.nextInt(4)).toRadixString(16)}${h(3)}-${h(12)}';
}

class RxScanScreen extends StatefulWidget {
  final RxRpc? rpc;
  const RxScanScreen({super.key, this.rpc});

  @override
  State<RxScanScreen> createState() => _RxScanScreenState();
}

class _RxScanScreenState extends State<RxScanScreen> {
  Map<String, dynamic>? _recent;
  String? _refusal;
  bool _failed = false;
  bool _busy = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : RxScanApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _failed = false;
      _refusal = null;
    });
    try {
      final r = await _call('rx_scan_recent', {'p_limit': 20});
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() => _refusal = _s(r['message']));
        return;
      }
      setState(() => _recent = r);
      RenderLog.write('c418_rx_home', 1);
      RenderLog.write('c418_rx_recent', _rows(r['scans']).length);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _capture() async {
    setState(() => _busy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 88,
      );
      if (picked == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final bytes = await picked.readAsBytes();

      // The backend mints the scan AND the path. The client chooses neither.
      final start = await _call('rx_scan_new', const {});
      if (start['ok'] != true) {
        _toast(_s(start['message']));
        if (mounted) setState(() => _busy = false);
        return;
      }
      final scanId = _s(start['scan_id']);
      final bucket = _s(start['bucket']);
      final path = _s(start['path']);
      final mime = picked.mimeType ?? 'image/jpeg';

      await RxScanApi.upload(bucket, path, bytes, mime);
      await _call('rx_scan_uploaded', {
        'p_scan_id': scanId,
        'p_path': path,
        'p_mime': mime,
        'p_bytes': bytes.length,
      });
      unawaited(RxScanApi.read(scanId));

      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => RxDraftScreen(scanId: scanId, rpc: widget.rpc),
        ),
      );
      if (mounted) _boot();
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    if (_refusal != null) return ShieldRefusal(message: _refusal!);
    if (_failed) {
      return ShieldRefusal(message: '', retryLabel: 'Retry', onRetry: _boot);
    }
    final r = _recent;
    if (r == null) return const ShieldSkeleton();
    final scans = _rows(r['scans']);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Text(_s(r['title']), style: Ds.t.subtitle),
      ),
      body: ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          SizedBox(
            height: Ds.touch.minTarget,
            child: FilledButton.icon(
              onPressed: _busy ? null : _capture,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(_s(r['capture_button'])),
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
            ),
          ),
          SizedBox(height: Ds.space.x24),
          if (scans.isEmpty)
            ShieldCard(
              child: Text(_s(r['empty']), style: Ds.t.bodySecondary),
            )
          else
            for (final sc in scans) ...[
              InkWell(
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => RxDraftScreen(
                        scanId: _s(sc['scan_id']),
                        rpc: widget.rpc,
                      ),
                    ),
                  );
                  if (mounted) _boot();
                },
                borderRadius: Ds.r.rCard,
                child: ShieldCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_s(sc['date_label']), style: Ds.t.bodyStrong),
                            Text(_s(sc['line_count_label']),
                                style: Ds.t.caption),
                          ],
                        ),
                      ),
                      if (_s(sc['invoice_no']).isNotEmpty)
                        ShieldChip(
                          label: _s(sc['invoice_no']),
                          tone: 'success',
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: Ds.space.x12),
            ],
          SizedBox(height: Ds.space.x32),
        ],
      ),
    );
  }
}

/// The photo beside the draft. On a phone they stack; on a counter tablet they
/// sit side by side, because the whole point is to see both at once.
class RxDraftScreen extends StatefulWidget {
  final String scanId;
  final RxRpc? rpc;
  const RxDraftScreen({super.key, required this.scanId, this.rpc});

  @override
  State<RxDraftScreen> createState() => _RxDraftScreenState();
}

class _RxDraftScreenState extends State<RxDraftScreen> {
  Map<String, dynamic>? _detail;
  String? _refusal;
  bool _failed = false;
  bool _saving = false;
  String? _imageUrl;
  Timer? _poll;

  /// line_id → on the bill. Seeded from the BACKEND's `default_on` and then
  /// owned by the human; a tap always outranks the default.
  final Map<String, bool> _ticked = {};

  /// line_id → the quantity as the human left it.
  final Map<String, String> _qty = {};

  /// line_id → a substitute the human chose instead.
  final Map<String, Map<String, dynamic>> _swapped = {};

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : RxScanApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load(first: true);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool first = false}) async {
    try {
      final r = await _call('rx_scan_detail', {'p_scan_id': widget.scanId});
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() => _refusal = _s(r['message']));
        return;
      }
      setState(() {
        _detail = r;
        for (final l in _rows(r['lines'])) {
          final id = _s(l['line_id']);
          _ticked.putIfAbsent(id, () => l['default_on'] == true);
          if (l['qty'] != null) _qty.putIfAbsent(id, () => _s(l['qty']));
        }
      });
      if (first) RenderLog.write('c418_rx_draft', 1);
      if (r['is_draft'] == true) {
        RenderLog.write('c418_rx_lines', _rows(r['lines']).length);
      }

      // The backend owns the poll interval, the same contract #403's document
      // layer uses — this screen never invents a timeout.
      final img = _m(r['image']);
      if (_imageUrl == null && img['has'] == true) {
        final url = await RxScanApi.imageUrl(
          _s(img['bucket']),
          _s(img['path']),
        );
        if (mounted) setState(() => _imageUrl = url);
      }
      if (r['is_reading'] == true) {
        final ms = (r['poll_ms'] is num) ? (r['poll_ms'] as num).toInt() : 2000;
        _poll?.cancel();
        _poll = Timer(Duration(milliseconds: ms), _load);
      }
    } catch (_) {
      if (mounted && first) setState(() => _failed = true);
    }
  }

  Future<void> _confirm() async {
    final d = _detail;
    if (d == null) return;
    final lines = <Map<String, dynamic>>[];
    for (final l in _rows(d['lines'])) {
      final id = _s(l['line_id']);
      if (_ticked[id] != true) continue;
      final swap = _swapped[id];
      final qty = num.tryParse((_qty[id] ?? '').trim());
      if (qty == null || qty <= 0) continue;
      lines.add({
        'medicine_id': swap != null ? swap['medicine_id'] : l['medicine_id'],
        'qty': qty,
        if (swap == null && _s(l['batch_label']).isNotEmpty)
          'batch_no': l['batch_no'],
      });
    }
    setState(() => _saving = true);
    try {
      final r = await _call('rx_scan_confirm', {
        'p_scan_id': widget.scanId,
        'p_client_action_id': _newActionId(),
        'p_lines': lines,
        'p_payment_mode': 'cash',
        'p_patient': const {},
      });
      if (!mounted) return;
      setState(() => _saving = false);
      final msg = _s(r['rx_toast']).isNotEmpty
          ? _s(r['rx_toast'])
          : _s(r['message']);
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
      if (r['ok'] == true) {
        RenderLog.write('c418_rx_billed', 1);
        if (mounted) Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _photo(Map<String, dynamic> d) {
    final img = _m(d['image']);
    return ShieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(d['photo_title']), style: Ds.t.bodyStrong),
          SizedBox(height: Ds.space.x8),
          if (img['has'] == true && _imageUrl != null)
            ClipRRect(
              borderRadius: Ds.r.rCard,
              child: Image.network(_imageUrl!, fit: BoxFit.contain),
            )
          else
            Container(
              height: Ds.space.x48 * 3,
              decoration: BoxDecoration(
                color: Ds.c.bg,
                borderRadius: Ds.r.rCard,
              ),
            ),
          SizedBox(height: Ds.space.x8),
          Text(_s(d['legal_note']), style: Ds.t.caption),
        ],
      ),
    );
  }

  Widget _draft(Map<String, dynamic> d) {
    final lines = _rows(d['lines']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_s(d['draft_title']), style: Ds.t.bodyStrong),
        SizedBox(height: Ds.space.x4),
        Text(_s(d['check_note']), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        if (d['is_reading'] == true)
          ShieldCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s(d['reading']), style: Ds.t.bodyStrong),
                SizedBox(height: Ds.space.x4),
                Text(_s(d['reading_hint']), style: Ds.t.caption),
              ],
            ),
          )
        else if (_s(d['failed_message']).isNotEmpty)
          ShieldCard(
            child: Text(_s(d['failed_message']), style: Ds.t.bodySecondary),
          )
        else if (!(d['has_lines'] == true))
          ShieldCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s(d['empty']), style: Ds.t.bodyStrong),
                SizedBox(height: Ds.space.x4),
                Text(_s(d['empty_hint']), style: Ds.t.caption),
              ],
            ),
          )
        else
          for (final l in lines) ...[
            _RxLineCard(
              line: l,
              ticked: _ticked[_s(l['line_id'])] ?? false,
              qty: _qty[_s(l['line_id'])] ?? '',
              swapped: _swapped[_s(l['line_id'])],
              locked: d['confirmed'] == true,
              onTick: (v) =>
                  setState(() => _ticked[_s(l['line_id'])] = v),
              onQty: (v) => _qty[_s(l['line_id'])] = v,
              onSwap: (sub) => setState(() {
                _swapped[_s(l['line_id'])] = sub;
                _ticked[_s(l['line_id'])] = true;
              }),
            ),
            SizedBox(height: Ds.space.x12),
          ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_refusal != null) return ShieldRefusal(message: _refusal!);
    if (_failed) {
      return ShieldRefusal(message: '', retryLabel: 'Retry', onRetry: _load);
    }
    final d = _detail;
    if (d == null) return const ShieldSkeleton();
    final canConfirm =
        d['is_draft'] == true && _ticked.values.any((v) => v);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Text(_s(d['title']), style: Ds.t.subtitle),
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 900;
          final photo = _photo(d);
          final draft = _draft(d);
          return ListView(
            padding: EdgeInsets.all(Ds.space.x16),
            children: [
              if (wide)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: photo),
                      SizedBox(width: Ds.space.x24),
                      Expanded(child: draft),
                    ],
                  ),
                )
              else ...[
                photo,
                SizedBox(height: Ds.space.x24),
                draft,
              ],
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: (!canConfirm || _saving) ? null : _confirm,
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.brand,
                    shape: RoundedRectangleBorder(
                      borderRadius: Ds.r.rButton,
                    ),
                  ),
                  child: Text(
                    _saving
                        ? _s(d['confirming'])
                        : _s(d['confirm_button']),
                  ),
                ),
              ),
              SizedBox(height: Ds.space.x32),
            ],
          );
        },
      ),
    );
  }
}

class _RxLineCard extends StatelessWidget {
  final Map<String, dynamic> line;
  final bool ticked;
  final String qty;
  final Map<String, dynamic>? swapped;
  final bool locked;
  final ValueChanged<bool> onTick;
  final ValueChanged<String> onQty;
  final ValueChanged<Map<String, dynamic>> onSwap;

  const _RxLineCard({
    required this.line,
    required this.ticked,
    required this.qty,
    required this.swapped,
    required this.locked,
    required this.onTick,
    required this.onQty,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    final subs = _rows(line['substitutes']);
    final swap = swapped;
    return ShieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: Ds.touch.minTarget,
                height: Ds.touch.minTarget,
                child: Checkbox(
                  value: ticked,
                  onChanged: locked ? null : (v) => onTick(v ?? false),
                  activeColor: Ds.c.brand,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The paper's own words, always. The counter is checking
                    // the draft AGAINST the photo; it can only do that if what
                    // was written is on the screen next to what was matched.
                    Text(
                      '${_s(line['seen_label'])}: ${_s(line['seen_text'])}',
                      style: Ds.t.body,
                    ),
                    if (_s(line['seen_detail']).isNotEmpty)
                      Text(_s(line['seen_detail']), style: Ds.t.caption),
                    if (_s(swap?['product_name'] ?? line['product_name'])
                        .isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(
                        _s(swap?['product_name'] ?? line['product_name']),
                        style: Ds.t.bodyStrong,
                      ),
                    ],
                    if (_s(line['batch_label']).isNotEmpty && swap == null)
                      Text(
                        '${_s(line['batch_label'])} · ${_s(line['expiry_label'])}',
                        style: Ds.t.caption,
                      ),
                    if (_s(line['on_hand_label']).isNotEmpty && swap == null)
                      Text(_s(line['on_hand_label']), style: Ds.t.caption),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              ShieldChip(
                label: _s(line['state_label']),
                tone: _s(line['tone']),
              ),
              if (_s(line['fefo_note']).isNotEmpty)
                ShieldChip(label: _s(line['fefo_note']), tone: 'info'),
              if (_s(line['confidence_note']).isNotEmpty)
                ShieldChip(
                  label: _s(line['confidence_note']),
                  tone: 'warning',
                ),
            ],
          ),
          if (_s(line['state_hint']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(line['state_hint']), style: Ds.t.caption),
          ],
          if (!locked) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              height: Ds.touch.minTarget,
              child: TextFormField(
                initialValue: qty,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: onQty,
                style: Ds.t.body,
                decoration: InputDecoration(
                  labelText: _s(line['qty_label']),
                  labelStyle: Ds.t.caption,
                  helperText: _s(line['qty_basis']).isEmpty
                      ? null
                      : _s(line['qty_basis']),
                  helperStyle: Ds.t.caption,
                  filled: true,
                  fillColor: Ds.c.bg,
                  border: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.divider),
                  ),
                ),
              ),
            ),
          ],
          if (_s(line['substitutes_none']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(line['substitutes_none']), style: Ds.t.caption),
          ],
          if (subs.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_s(line['substitutes_title']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            for (final sub in subs)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x8),
                child: InkWell(
                  onTap: locked ? null : () => onSwap(sub),
                  borderRadius: Ds.r.rCard,
                  child: Container(
                    width: double.infinity,
                    constraints: BoxConstraints(
                      minHeight: Ds.touch.minTarget,
                    ),
                    padding: EdgeInsets.all(Ds.space.x12),
                    decoration: BoxDecoration(
                      color: Ds.c.bg,
                      borderRadius: Ds.r.rCard,
                      border: Border.all(
                        color: swap != null &&
                                swap['stock_id'] == sub['stock_id']
                            ? Ds.c.brand
                            : Ds.c.divider,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _s(sub['product_name']),
                                style: Ds.t.body,
                              ),
                              Text(
                                '${_s(sub['on_hand_label'])} · ${_s(sub['mrp_display'])}',
                                style: Ds.t.caption,
                              ),
                            ],
                          ),
                        ),
                        Text(
                          _s(sub['margin_display']),
                          style: Ds.t.bodyStrong.copyWith(
                            color: toneColor('success'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
