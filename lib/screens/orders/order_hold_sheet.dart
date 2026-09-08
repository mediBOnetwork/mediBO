import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #708 — "Hold my order", and the way back off hold.
///
/// The sheet computes NOTHING. `order_hold_sheet()` says whether this order may
/// be held at all, words the refusal when it may not, names the reason chips in
/// payload order, and carries every label on the screen. Submitting calls
/// `order_hold()` / `order_resume()` and renders whatever comes back — the
/// toast, the tone, and the fresh state.
///
/// The same sheet serves the customer and mediBO staff: `actor_kind` in the
/// payload decides which chips arrive (a staff-only reason never reaches a
/// pharmacy) and the backend decides who may write at all. There is no role
/// branch on this side of the wire.
class OrderHoldSheet extends StatefulWidget {
  final String orderId;

  const OrderHoldSheet({super.key, required this.orderId});

  /// Test seam. The protected test drives the contract without Supabase.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<OrderHoldSheet> createState() => _OrderHoldSheetState();
}

class _OrderHoldSheetState extends State<OrderHoldSheet> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  bool _busy = false;
  String _picked = '';
  DateTime? _resumeOn;
  final TextEditingController _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  static Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  String _s(String k) => (_p[k] ?? '').toString();

  Future<void> _load() async {
    try {
      final res = await OrderHoldSheet.rpc(
          'order_hold_sheet', {'p_order_id': widget.orderId});
      if (!mounted) return;
      setState(() {
        _p = _asMap(res);
        _loading = false;
      });
      RenderLog.write('c708_hold_sheet', 1);
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

  bool get _needsNote {
    for (final r in _reasons) {
      if ((r['code'] ?? '').toString() == _picked) return r['needs_note'] == true;
    }
    return false;
  }

  /// Submit opens only when the payload allows a hold AND the payload's own
  /// rules are met — a reason is picked, and a note is present when the chip
  /// the backend sent says it needs one.
  bool get _canSubmit =>
      !_busy && _p['can_hold'] == true && _picked.isNotEmpty &&
      (!_needsNote || _note.text.trim().isNotEmpty);

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _busy = true);
    final res = _asMap(await OrderHoldSheet.rpc('order_hold', {
      'p_order_id': widget.orderId,
      'p_reason_code': _picked,
      'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      'p_resume_on': _resumeOn?.toIso8601String().split('T').first,
    }));
    if (!mounted) return;
    setState(() => _busy = false);
    _finish(res);
  }

  Future<void> _resume() async {
    setState(() => _busy = true);
    final res = _asMap(
        await OrderHoldSheet.rpc('order_resume', {'p_order_id': widget.orderId}));
    if (!mounted) return;
    setState(() => _busy = false);
    _finish(res);
  }

  void _finish(Map<String, dynamic> res) {
    final msg = (res['message'] ?? '').toString();
    final ok = res['ok'] == true;
    if (msg.isNotEmpty) {
      final tone = (res['tone'] ?? '').toString();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: tone == 'danger'
            ? Ds.c.danger
            : tone == 'warning'
                ? Ds.c.warning
                : Ds.c.brand,
      ));
    }
    if (ok) {
      RenderLog.write('c708_hold_write', 1);
      Navigator.of(context).pop(true);
    } else {
      // A refusal is the backend's answer, not a dead end: re-read so the
      // sheet shows the state the server actually has.
      _load();
    }
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final maxDays = (_p['max_resume_days'] is int)
        ? _p['max_resume_days'] as int
        : int.tryParse(_s('max_resume_days')) ?? 60;
    final d = await showDatePicker(
      context: context,
      initialDate: _resumeOn ?? today.add(const Duration(days: 1)),
      firstDate: today,
      lastDate: today.add(Duration(days: maxDays)),
    );
    if (d != null && mounted) setState(() => _resumeOn = d);
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
                  decoration: BoxDecoration(
                      color: Ds.c.bg, borderRadius: Ds.r.rCard),
                ),
              ),
          ],
        ),
      );
    }

    if (_p['ok'] != true) {
      return _Frame(children: [
        Text(_s('title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x8),
        Text(_s('message'), style: Ds.t.body),
      ]);
    }

    final state = _asMap(_p['state']);
    final held = state['held'] == true;

    return _Frame(children: [
      Text(_s('title'), style: Ds.t.title),
      SizedBox(height: Ds.space.x4),
      Text(_s('subtitle'), style: Ds.t.caption),
      SizedBox(height: Ds.space.x16),

      // Already parked: the badge the payload wrote, and one way back.
      if (held) ...[
        _Banner(
          text: (state['badge'] ?? '').toString(),
          detail: (state['auto_cancel_note'] ?? '').toString(),
        ),
        if ((state['note'] ?? '').toString().isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text((state['note'] ?? '').toString(), style: Ds.t.body),
        ],
        SizedBox(height: Ds.space.x24),
        SizedBox(
          height: Ds.space.x48,
          child: FilledButton(
            onPressed: _busy ? null : _resume,
            child: Text(_s('resume_submit_label')),
          ),
        ),
      ] else if (_p['can_hold'] != true) ...[
        _Banner(text: _s('message'), detail: ''),
      ] else ...[
        Text(_s('reason_label'), style: Ds.t.body),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final r in _reasons)
              ChoiceChip(
                label: Text((r['label'] ?? '').toString()),
                selected: _picked == (r['code'] ?? '').toString(),
                onSelected: (_) => setState(
                    () => _picked = (r['code'] ?? '').toString()),
              ),
          ],
        ),
        SizedBox(height: Ds.space.x16),
        Text(_s('note_label'), style: Ds.t.body),
        SizedBox(height: Ds.space.x8),
        TextField(
          controller: _note,
          maxLength: (_p['note_max'] is int) ? _p['note_max'] as int : 240,
          minLines: 1,
          maxLines: 3,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(hintText: _s('note_hint')),
        ),
        SizedBox(height: Ds.space.x8),
        Text(_s('resume_label'), style: Ds.t.body),
        SizedBox(height: Ds.space.x8),
        SizedBox(
          height: Ds.space.x48,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _pickDate,
            icon: const Icon(Icons.event_outlined),
            label: Text(_resumeOn == null
                ? _s('resume_hint')
                : '${_resumeOn!.day}/${_resumeOn!.month}/${_resumeOn!.year}'),
          ),
        ),
        SizedBox(height: Ds.space.x16),
        Text(_s('billing_note'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        SizedBox(
          height: Ds.space.x48,
          child: FilledButton(
            onPressed: _canSubmit ? _submit : null,
            child: Text(_s('submit_label')),
          ),
        ),
      ],
    ]);
  }
}

class _Frame extends StatelessWidget {
  final List<Widget> children;
  const _Frame({required this.children});

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      );
}

class _Banner extends StatelessWidget {
  final String text;
  final String detail;
  const _Banner({required this.text, required this.detail});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
            color: Ds.c.warningSoft, borderRadius: Ds.r.rCard),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: Ds.t.body),
            if (detail.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(detail, style: Ds.t.caption),
            ],
          ],
        ),
      );
}

/// The one door. Returns true when the order's hold state changed, so the
/// caller can refetch the surface it sits on.
Future<bool> showOrderHoldSheet(BuildContext context, String orderId) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    builder: (_) => OrderHoldSheet(orderId: orderId),
  );
  return changed == true;
}
