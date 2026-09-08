// CHANGE #527 · feature_gaps #50 + #61 — the supplier's answer to a purchase
// order, and the batch/expiry/HSN he acknowledges with it.
//
// Everything visible here is a payload string. The state name, the three button
// labels, the hint, the blocked-pack reason, the field labels and every error
// message arrive inside `supplier_my_orders().accept` / `.line_details`. This
// file decides nothing: it prints what the backend sent and posts back what the
// supplier typed.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';

Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : <Map<String, dynamic>>[];

String _str(Map<String, dynamic> m, String k) {
  final v = m[k];
  return v == null ? '' : v.toString();
}

/// The backend names a tone; this is the only place that turns one into a
/// colour, and it never guesses one from the state.
Color _tone(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'brand':
      return Ds.c.brand;
    case 'info':
      return Ds.c.info;
    default:
      return Ds.c.textSecondary;
  }
}

Color _toneSoft(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'brand':
      return Ds.c.brandSoft;
    default:
      return Ds.c.infoSoft;
  }
}

/// The pack gate, extracted so it is a decision the BACKEND makes and this
/// app merely reports. `enabled` absent means the payload predates #527 and the
/// button behaves exactly as it did before; `false` means the backend refused,
/// and the reason it prints is the backend's own sentence, never one built here.
class PoPackGate {
  const PoPackGate._();

  static bool enabled(Map<String, dynamic> packButton) =>
      packButton['enabled'] != false;

  static String blockedReason(Map<String, dynamic> packButton) =>
      packButton['blocked_reason']?.toString() ?? '';
}

// ── Accept / part-accept / decline ──────────────────────────────────────────

class SupplierPoAck extends StatefulWidget {
  final Map<String, dynamic> accept;
  final List<Map<String, dynamic>> items;
  final String orderCode;
  final Future<void> Function() onAnswered;

  const SupplierPoAck({
    super.key,
    required this.accept,
    required this.items,
    required this.orderCode,
    required this.onAnswered,
  });

  @override
  State<SupplierPoAck> createState() => _SupplierPoAckState();
}

class _SupplierPoAckState extends State<SupplierPoAck> {
  bool _busy = false;

  Future<void> _send(String action,
      {String? reason, List<Map<String, dynamic>>? lines}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'supplier_respond_order',
        params: <String, dynamic>{
          'p_order_code': widget.orderCode,
          'p_action': action,
          if (reason != null) 'p_reason': reason,
          if (lines != null) 'p_lines': lines,
        },
      );
      final m = _map(res);
      if (mounted && _str(m, 'message').isNotEmpty) {
        showToast(context, _str(m, 'message'), isError: m['ok'] != true);
      }
      RenderLog.write('c527_po_ack', action);
      if (m['ok'] == true) await widget.onAnswered();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _askDecline() async {
    final ctrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.fromLTRB(
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x16 + MediaQuery.of(sheetCtx).viewInsets.bottom,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_str(widget.accept, 'reason_label'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          TextField(
            controller: ctrl,
            maxLines: 2,
            style: Ds.t.body,
            decoration: InputDecoration(border: const OutlineInputBorder()),
          ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Ds.c.danger),
              onPressed: () => Navigator.pop(sheetCtx, true),
              child: Text(_actionLabel('decline')),
            ),
          ),
        ]),
      ),
    );
    if (ok == true) await _send('decline', reason: ctrl.text.trim());
  }

  Future<void> _askPartial() async {
    final ctrls = <String, TextEditingController>{};
    for (final it in widget.items) {
      final pid = _str(it, 'product_id');
      if (pid.isEmpty) continue;
      ctrls[pid] = TextEditingController(text: _str(it, 'quantity'));
    }
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            Ds.space.x16,
            Ds.space.x16,
            Ds.space.x16,
            Ds.space.x16 + MediaQuery.of(sheetCtx).viewInsets.bottom,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_str(widget.accept, 'title'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final it in widget.items)
                    if (ctrls.containsKey(_str(it, 'product_id')))
                      Padding(
                        padding: EdgeInsets.only(bottom: Ds.space.x12),
                        child: Row(children: [
                          Expanded(
                            child: Text(_str(it, 'product_name'),
                                style: Ds.t.body,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                          ),
                          SizedBox(width: Ds.space.x12),
                          SizedBox(
                            width: Ds.touch.minTarget * 2,
                            child: TextField(
                              controller: ctrls[_str(it, 'product_id')],
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.right,
                              style: Ds.t.body,
                              decoration: const InputDecoration(
                                  border: OutlineInputBorder(), isDense: true),
                            ),
                          ),
                        ]),
                      ),
                ],
              ),
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
                onPressed: () => Navigator.pop(sheetCtx, true),
                child: Text(_actionLabel('partial')),
              ),
            ),
          ]),
        ),
      ),
    );
    if (ok != true) return;
    final lines = <Map<String, dynamic>>[];
    ctrls.forEach((pid, ctrl) {
      final qty = num.tryParse(ctrl.text.trim());
      if (qty != null) {
        lines.add(<String, dynamic>{
          'product_id': int.tryParse(pid) ?? pid,
          'accepted_qty': qty,
        });
      }
    });
    await _send('partial', lines: lines);
  }

  String _actionLabel(String action) {
    for (final a in _rows(widget.accept['actions'])) {
      if (_str(a, 'action') == action) return _str(a, 'label');
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.accept;
    if (a.isEmpty) return const SizedBox.shrink();
    final needsReply = a['needs_reply'] == true;
    final tone = _str(a, 'tone');

    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x12, 0, Ds.space.x12, Ds.space.x12),
      child: Container(
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: _toneSoft(tone),
          borderRadius: Ds.r.rCard,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The state name is printed ONCE — as the question while the PO is
            // unanswered, as the chip once it has been answered. Never both.
            Row(children: [
              if (needsReply)
                Expanded(
                  child: Text(_str(a, 'title'), style: Ds.t.bodyStrong),
                )
              else
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                      color: Ds.c.surface, borderRadius: Ds.r.rChip),
                  child: Text(_str(a, 'label'),
                      style: Ds.t.caption.copyWith(color: _tone(tone))),
                ),
            ]),
            if (needsReply && _str(a, 'hint').isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(_str(a, 'hint'), style: Ds.t.caption),
            ],
            if (!needsReply && _str(a, 'reason').isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(_str(a, 'reason'), style: Ds.t.caption),
            ],
            if (needsReply) ...[
              SizedBox(height: Ds.space.x12),
              Row(children: [
                for (final act in _rows(a['actions'])) ...[
                  Expanded(
                    child: SizedBox(
                      height: Ds.touch.minTarget,
                      child: _str(act, 'action') == 'accept'
                          ? FilledButton(
                              style: FilledButton.styleFrom(
                                  backgroundColor: _tone(_str(act, 'tone'))),
                              onPressed:
                                  _busy ? null : () => _send('accept'),
                              child: Text(_str(act, 'label'),
                                  style: Ds.t.caption
                                      .copyWith(color: Ds.c.surface)),
                            )
                          : OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _tone(_str(act, 'tone')),
                                side: BorderSide(
                                    color: _tone(_str(act, 'tone'))),
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => _str(act, 'action') == 'partial'
                                      ? _askPartial()
                                      : _askDecline(),
                              child: Text(_str(act, 'label'),
                                  style: Ds.t.caption
                                      .copyWith(color: _tone(_str(act, 'tone')))),
                            ),
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                ],
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Batch / expiry / HSN (gap #61) ──────────────────────────────────────────

class SupplierPoLineDetails extends StatefulWidget {
  final Map<String, dynamic> block;
  final List<Map<String, dynamic>> items;
  final String orderCode;
  final Future<void> Function() onSaved;

  const SupplierPoLineDetails({
    super.key,
    required this.block,
    required this.items,
    required this.orderCode,
    required this.onSaved,
  });

  @override
  State<SupplierPoLineDetails> createState() => _SupplierPoLineDetailsState();
}

class _SupplierPoLineDetailsState extends State<SupplierPoLineDetails> {
  bool _open = false;
  bool _busy = false;
  final Map<String, TextEditingController> _batch = {};
  final Map<String, TextEditingController> _expiry = {};
  final Map<String, TextEditingController> _hsn = {};

  void _ensure() {
    for (final it in widget.items) {
      final pid = _str(it, 'product_id');
      if (pid.isEmpty) continue;
      _batch.putIfAbsent(
          pid, () => TextEditingController(text: _str(it, 'batch_no')));
      _expiry.putIfAbsent(
          pid, () => TextEditingController(text: _str(it, 'expiry')));
      _hsn.putIfAbsent(pid, () => TextEditingController(text: _str(it, 'hsn')));
    }
  }

  @override
  void dispose() {
    for (final c in [..._batch.values, ..._expiry.values, ..._hsn.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final lines = <Map<String, dynamic>>[];
      _batch.forEach((pid, ctrl) {
        final b = ctrl.text.trim();
        final e = _expiry[pid]?.text.trim() ?? '';
        final h = _hsn[pid]?.text.trim() ?? '';
        if (b.isEmpty && e.isEmpty && h.isEmpty) return;
        lines.add(<String, dynamic>{
          'product_id': int.tryParse(pid) ?? pid,
          if (b.isNotEmpty) 'batch_no': b,
          if (e.isNotEmpty) 'expiry': e,
          if (h.isNotEmpty) 'hsn': h,
        });
      });
      final res = await Supabase.instance.client.rpc(
        'supplier_set_line_details',
        params: <String, dynamic>{
          'p_order_code': widget.orderCode,
          'p_lines': lines,
        },
      );
      final m = _map(res);
      if (mounted && _str(m, 'message').isNotEmpty) {
        showToast(context, _str(m, 'message'), isError: m['ok'] != true);
      }
      RenderLog.write('c527_po_details', lines.length);
      if (m['ok'] == true) await widget.onSaved();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController ctrl, String label) => Expanded(
        child: TextField(
          controller: ctrl,
          style: Ds.t.caption.copyWith(color: Ds.c.text),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: Ds.t.caption,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    if (b.isEmpty || widget.items.isEmpty) return const SizedBox.shrink();
    _ensure();

    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x12, 0, Ds.space.x12, Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: SizedBox(
            height: Ds.touch.minTarget,
            child: Row(children: [
              Icon(Icons.inventory_2_outlined,
                  size: Ds.space.x16, color: Ds.c.textSecondary),
              SizedBox(width: Ds.space.x8),
              Expanded(
                child: Text(_str(b, 'title'), style: Ds.t.bodyStrong),
              ),
              Text(_str(b, 'status_label'),
                  style: Ds.t.caption.copyWith(
                      color: b['complete'] == true
                          ? Ds.c.success
                          : Ds.c.warning)),
              Icon(_open ? Icons.expand_less : Icons.expand_more,
                  color: Ds.c.textSecondary),
            ]),
          ),
        ),
        if (_open) ...[
          Text(_str(b, 'hint'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          for (final it in widget.items)
            if (_batch.containsKey(_str(it, 'product_id')))
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_str(it, 'product_name'),
                          style: Ds.t.body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      SizedBox(height: Ds.space.x4),
                      Row(children: [
                        _field(_batch[_str(it, 'product_id')]!,
                            _str(b, 'batch_label')),
                        SizedBox(width: Ds.space.x8),
                        _field(_expiry[_str(it, 'product_id')]!,
                            _str(b, 'expiry_label')),
                        SizedBox(width: Ds.space.x8),
                        _field(_hsn[_str(it, 'product_id')]!,
                            _str(b, 'hsn_label')),
                      ]),
                    ]),
              ),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
              onPressed: _busy ? null : _save,
              child: Text(_str(b, 'save_label'),
                  style: Ds.t.caption.copyWith(color: Ds.c.surface)),
            ),
          ),
        ],
      ]),
    );
  }
}
