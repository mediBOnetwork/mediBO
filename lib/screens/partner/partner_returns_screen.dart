// CHANGE #710 — the partner sends stock back to a supplier and the debit note
// raises itself.
//
// Before this screen, supplier_debits_list() only LISTED money already taken
// off a bill (customer returns and shop-count disputes). There was no way to
// send wrong, damaged, short-packed or near-expiry stock back and put a number
// on it. This is that door.
//
// The screen computes nothing. The collections it offers, the lines that can
// still go back and how many of each, the reason list, every rupee, the status
// word and its colour, the send button's label, every refusal and every toast
// are partner_returns_console() / partner_return_get()'s. The only state this
// file owns is which collection is open, which line the sheet is editing, and
// the two values the user is typing into it.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../services/partner_state.dart';
import '../../services/supplier_records_api.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import 'partner_ui.dart';

String _s(Map? m, String key) {
  final v = m == null ? null : m[key];
  return v == null ? '' : v.toString();
}

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

double _n(Map? m, String key) {
  final v = m == null ? null : m[key];
  return v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
}

class PartnerReturnsScreen extends StatefulWidget {
  const PartnerReturnsScreen({super.key, this.rpc});

  /// Test seam. Null in production -> the real RPCs.
  final PartnerRpc? rpc;

  @override
  State<PartnerReturnsScreen> createState() => _PartnerReturnsScreenState();
}

class _PartnerReturnsScreenState extends State<PartnerReturnsScreen> {
  Map<String, dynamic>? _console;
  Map<String, dynamic>? _editor;
  bool _loading = true;
  bool _busy = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PartnerApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final map = await _call('partner_returns_console', {'p_limit': 40});
      RenderLog.write('c710_partner_returns', _rows(map['rows']).length);
      if (!mounted) return;
      setState(() {
        _console = map;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _toast(String message, String tone) {
    if (message.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: partnerToneColor(tone)));
  }

  /// Every editor call comes back as the WHOLE editor payload, so the screen
  /// replaces its state with the backend's rather than patching its own copy.
  Future<void> _editorCall(String fn, Map<String, dynamic> params) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await _call(fn, params);
      if (!mounted) return;
      if (res['ok'] != true) {
        _toast(_s(res, 'message'), 'danger');
        return;
      }
      setState(() => _editor = res);
      _toast(_s(res, 'toast'), 'success');
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openReturn(String id) async {
    setState(() => _busy = true);
    try {
      final res = await _call('partner_return_get', {'p_id': id});
      if (!mounted) return;
      if (res['ok'] != true) {
        _toast(_s(res, 'message'), 'danger');
        return;
      }
      setState(() => _editor = res);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start(String supplierOrderId) =>
      _editorCall('partner_return_start', {'p_supplier_order_id': supplierOrderId});

  /// The debit note PDF is NOT an editor call: it answers with a document
  /// handoff, not the editor payload, so it must never be fed back into
  /// _editor. Ask, then poll on the BACKEND's own `poll_ms` — no invented
  /// interval and no invented timeout — then sign and open the file.
  Future<void> _doc(String id) async {
    if (id.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      var res = await _call('partner_return_doc', {'p_id': id});
      var tries = 0;
      while (res['ok'] == true &&
          _s(res, 'status') == 'building' &&
          tries < 20) {
        final ms = res['poll_ms'];
        await Future<void>.delayed(
            Duration(milliseconds: ms is num ? ms.toInt() : 1500));
        if (!mounted) return;
        res = await _call('partner_return_doc_status', {'p_id': id});
        tries++;
      }
      if (!mounted) return;
      if (res['ok'] != true || _s(res, 'status') != 'ready') {
        _toast(_s(res, 'message'), res['ok'] == true ? 'info' : 'danger');
        return;
      }
      final url = await SupplierRecordsApi.signedUrl(
          _s(res, 'bucket'), _s(res, 'path'));
      if (url.isEmpty || !mounted) return;
      await launchUrl(Uri.parse(url),
          webOnlyWindowName: '_blank', mode: LaunchMode.externalApplication);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _console;
    // No Scaffold and no AppBar: PartnerFeaturePage owns both and titles the
    // page with the BACKEND's own label for the feature.
    return ColoredBox(
      color: Ds.c.bg,
      child: _loading
          ? const PartnerSkeleton()
          : (d == null || d['ok'] != true)
              ? PartnerNotice(
                  title: _s(d, 'message').isEmpty ? c('partner.error_title') : '',
                  text: _s(d, 'message').isEmpty
                      ? c('partner.error_message')
                      : _s(d, 'message'),
                  onRetry: _load,
                  retryLabel: c('partner.retry_label'),
                )
              : _editor != null
                  ? _Editor(
                      payload: _editor!,
                      busy: _busy,
                      onClose: () => setState(() => _editor = null),
                      onLine: (itemId, qty, reason, note) => _editorCall(
                          'partner_return_line_set', {
                            'p_id': _s(_editor?['row'], 'id'),
                            'p_order_item_id': itemId,
                            'p_qty': qty,
                            'p_reason_code': reason,
                            'p_note': note,
                          }),
                      onSend: () => _editorCall('partner_return_send',
                          {'p_id': _s(_editor?['row'], 'id')}),
                      onCancel: () => _editorCall('partner_return_cancel',
                          {'p_id': _s(_editor?['row'], 'id')}),
                      onDoc: () => _doc(_s(_editor?['row'], 'id')),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _Console(
                        payload: d,
                        busy: _busy,
                        onStart: _start,
                        onOpen: _openReturn,
                      ),
                    ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// THE LIST — the returns already raised, and the collections one can start from
// ═══════════════════════════════════════════════════════════════════════════
class _Console extends StatelessWidget {
  const _Console({
    required this.payload,
    required this.busy,
    required this.onStart,
    required this.onOpen,
  });

  final Map<String, dynamic> payload;
  final bool busy;
  final void Function(String supplierOrderId) onStart;
  final void Function(String returnId) onOpen;

  @override
  Widget build(BuildContext context) {
    final rows = _rows(payload['rows']);
    final orders = _rows(payload['orders']);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(payload, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        if (payload['can_write'] == true) ...[
          Text(_s(payload, 'pick_order_label'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          if (orders.isEmpty)
            PartnerNotice(text: _s(payload, 'pick_order_empty'))
          else
            SizedBox(
              height: Ds.touch.listRowMinHeight + Ds.space.x48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: orders.length,
                separatorBuilder: (_, __) => SizedBox(width: Ds.space.x12),
                itemBuilder: (context, i) {
                  final o = orders[i];
                  return _OrderPill(
                    order: o,
                    label: _s(payload, 'new_label'),
                    onTap: busy
                        ? null
                        : () => onStart(_s(o, 'supplier_order_id')),
                  );
                },
              ),
            ),
          SizedBox(height: Ds.space.x32),
        ],
        Text(_s(payload, 'title'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (rows.isEmpty)
          PartnerNotice(text: _s(payload, 'empty_text'))
        else
          for (final r in rows)
            PartnerCard(
              onTap: busy ? null : () => onOpen(_s(r, 'id')),
              child: _ReturnSummary(row: r),
            ),
      ],
    );
  }
}

class _OrderPill extends StatelessWidget {
  const _OrderPill({required this.order, required this.label, this.onTap});

  final Map<String, dynamic> order;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        child: InkWell(
          borderRadius: Ds.r.rCard,
          onTap: onTap,
          child: Container(
            width: Ds.space.x48 * 5,
            padding: EdgeInsets.all(Ds.space.x12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_s(order, 'supplier_name'),
                    style: Ds.t.bodyStrong, maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                SizedBox(height: Ds.space.x4),
                Text(
                    '${_s(order, 'order_label')} · ${_s(order, 'date_label')}',
                    style: Ds.t.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                SizedBox(height: Ds.space.x4),
                Text(label, style: Ds.t.caption.copyWith(color: Ds.c.brand)),
              ],
            ),
          ),
        ),
      );
}

class _ReturnSummary extends StatelessWidget {
  const _ReturnSummary({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final debitNo = _s(row, 'debit_no');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(_s(row, 'supplier_name'), style: Ds.t.bodyStrong),
            ),
            SizedBox(width: Ds.space.x12),
            Text(_s(row, 'total_value'),
                style: Ds.t.bodyStrong.copyWith(color: Ds.c.danger)),
          ],
        ),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            PartnerChip(
                text: _s(row, 'status_label'), tone: _s(row, 'status_tone')),
            if (debitNo.isNotEmpty) PartnerChip(text: debitNo, tone: 'info'),
            PartnerChip(
                text: '${_s(row, 'count_label')} ${_s(row, 'count_value')}'),
          ],
        ),
        SizedBox(height: Ds.space.x8),
        Text('${_s(row, 'order_label')} · ${_s(row, 'at_label')}',
            style: Ds.t.caption),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// THE EDITOR — what came in, what is going back
// ═══════════════════════════════════════════════════════════════════════════
class _Editor extends StatelessWidget {
  const _Editor({
    required this.payload,
    required this.busy,
    required this.onClose,
    required this.onLine,
    required this.onSend,
    required this.onCancel,
    required this.onDoc,
  });

  final Map<String, dynamic> payload;
  final bool busy;
  final VoidCallback onClose;
  final void Function(String orderItemId, num qty, String reason, String note)
      onLine;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final VoidCallback onDoc;

  @override
  Widget build(BuildContext context) {
    final row = payload['row'] is Map
        ? Map<String, dynamic>.from(payload['row'] as Map)
        : <String, dynamic>{};
    final items = _rows(payload['items']);
    final candidates = _rows(payload['candidates']);
    final reasons = _rows(payload['reasons']);
    final canWrite = payload['can_write'] == true && row['can_edit'] == true;

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Row(
          children: [
            Expanded(child: Text(_s(payload, 'title'), style: Ds.t.subtitle)),
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close),
              tooltip: _s(payload, 'cancel_label'),
            ),
          ],
        ),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            PartnerChip(
                text: _s(row, 'status_label'), tone: _s(row, 'status_tone')),
            if (_s(row, 'debit_no').isNotEmpty)
              PartnerChip(text: _s(row, 'debit_no'), tone: 'info'),
          ],
        ),
        SizedBox(height: Ds.space.x24),
        Text(_s(payload, 'items_label'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (items.isEmpty)
          PartnerNotice(text: _s(payload, 'items_empty'))
        else
          for (final i in items)
            PartnerCard(
              child: _LineRow(
                line: i,
                removeLabel: _s(payload, 'remove_label'),
                onRemove: !canWrite || busy
                    ? null
                    : () => onLine(_s(i, 'order_item_id'), 0, '', ''),
              ),
            ),
        SizedBox(height: Ds.space.x16),
        _Totals(row: row),
        SizedBox(height: Ds.space.x24),
        if (canWrite) ...[
          Text(_s(payload, 'candidates_label'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          if (candidates.isEmpty)
            PartnerNotice(text: _s(payload, 'candidates_empty'))
          else
            for (final cand in candidates)
              PartnerCard(
                onTap: busy
                    ? null
                    : () => _pick(context, cand, reasons, payload, onLine),
                child: _CandidateRow(candidate: cand),
              ),
          SizedBox(height: Ds.space.x24),
        ],
        Row(
          children: [
            if (row['can_send'] == true)
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: busy ? null : onSend,
                    child: Text(_s(payload, 'send_label')),
                  ),
                ),
              ),
            if (row['can_send'] == true && row['can_doc'] == true)
              SizedBox(width: Ds.space.x12),
            if (row['can_doc'] == true)
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: busy ? null : onDoc,
                    child: Text(_s(payload, 'doc_label')),
                  ),
                ),
              ),
          ],
        ),
        if (row['can_cancel'] == true) ...[
          SizedBox(height: Ds.space.x12),
          SizedBox(
            height: Ds.touch.minTarget,
            child: TextButton(
              onPressed: busy ? null : onCancel,
              child: Text(_s(payload, 'cancel_label'),
                  style: Ds.t.body.copyWith(color: Ds.c.danger)),
            ),
          ),
        ],
        SizedBox(height: Ds.space.x32),
      ],
    );
  }

  static Future<void> _pick(
    BuildContext context,
    Map<String, dynamic> candidate,
    List<Map<String, dynamic>> reasons,
    Map<String, dynamic> payload,
    void Function(String orderItemId, num qty, String reason, String note) onLine,
  ) async {
    final res = await showModalBottomSheet<_LineDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _LineSheet(
        candidate: candidate,
        reasons: reasons,
        payload: payload,
      ),
    );
    if (res == null) return;
    onLine(_s(candidate, 'order_item_id'), res.qty, res.reason, res.note);
  }
}

class _LineDraft {
  const _LineDraft(this.qty, this.reason, this.note);
  final num qty;
  final String reason;
  final String note;
}

class _LineSheet extends StatefulWidget {
  const _LineSheet({
    required this.candidate,
    required this.reasons,
    required this.payload,
  });

  final Map<String, dynamic> candidate;
  final List<Map<String, dynamic>> reasons;
  final Map<String, dynamic> payload;

  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  final TextEditingController _qty = TextEditingController();
  final TextEditingController _note = TextEditingController();
  String _reason = '';

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payload;
    final maxQty = _n(widget.candidate, 'max_qty');
    return Padding(
      padding: EdgeInsets.only(
        left: Ds.space.x16,
        right: Ds.space.x16,
        top: Ds.space.x16,
        bottom: MediaQuery.of(context).viewInsets.bottom + Ds.space.x16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(widget.candidate, 'product_name'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text(_s(widget.candidate, 'max_qty_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          Text(_s(p, 'reason_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final r in widget.reasons)
                GestureDetector(
                  onTap: () => setState(() => _reason = _s(r, 'code')),
                  child: Opacity(
                    opacity: _reason == _s(r, 'code') ? 1 : 0.45,
                    child: PartnerChip(
                        text: _s(r, 'label'), tone: _s(r, 'tone')),
                  ),
                ),
            ],
          ),
          SizedBox(height: Ds.space.x16),
          TextField(
            controller: _qty,
            keyboardType: TextInputType.number,
            style: Ds.t.body,
            decoration: InputDecoration(
              labelText: _s(p, 'qty_label'),
              labelStyle: Ds.t.caption,
              filled: true,
              fillColor: Ds.c.bg,
              border: OutlineInputBorder(borderRadius: Ds.r.rButton),
            ),
          ),
          SizedBox(height: Ds.space.x12),
          TextField(
            controller: _note,
            style: Ds.t.body,
            decoration: InputDecoration(
              labelText: _s(p, 'note_label'),
              labelStyle: Ds.t.caption,
              filled: true,
              fillColor: Ds.c.bg,
              border: OutlineInputBorder(borderRadius: Ds.r.rButton),
            ),
          ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              // The backend re-checks the ceiling and the reason and answers in
              // its own words; this only stops an empty submit.
              onPressed: _reason.isEmpty || (num.tryParse(_qty.text) ?? 0) <= 0
                  ? null
                  : () => Navigator.of(context).pop(_LineDraft(
                      num.tryParse(_qty.text) ?? 0, _reason, _note.text.trim())),
              child: Text(_s(p, 'add_label')),
            ),
          ),
          if (maxQty > 0) SizedBox(height: Ds.space.x8),
        ],
      ),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({required this.candidate});

  final Map<String, dynamic> candidate;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(_s(candidate, 'product_name'), style: Ds.t.body),
              ),
              SizedBox(width: Ds.space.x12),
              Text(_s(candidate, 'rate_label'), style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Row(
            children: [
              Expanded(
                  child: Text(_s(candidate, 'max_qty_label'),
                      style: Ds.t.caption)),
              if (candidate['in_return'] == true)
                PartnerChip(text: _s(candidate, 'order_label'), tone: 'success'),
            ],
          ),
        ],
      );
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.removeLabel,
    this.onRemove,
  });

  final Map<String, dynamic> line;
  final String removeLabel;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(_s(line, 'product_name'), style: Ds.t.bodyStrong),
              ),
              SizedBox(width: Ds.space.x12),
              Text(_s(line, 'amount_value'), style: Ds.t.bodyStrong),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              PartnerChip(text: _s(line, 'reason_label'), tone: 'warning'),
              PartnerChip(text: _s(line, 'qty_value')),
              PartnerChip(text: _s(line, 'rate_value')),
              PartnerChip(text: _s(line, 'gst_value')),
            ],
          ),
          if (onRemove != null) ...[
            SizedBox(height: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: TextButton(
                onPressed: onRemove,
                child: Text(removeLabel,
                    style: Ds.t.body.copyWith(color: Ds.c.danger)),
              ),
            ),
          ],
        ],
      );
}

class _Totals extends StatelessWidget {
  const _Totals({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          children: [
            _TotalLine(
                label: _s(row, 'taxable_label'),
                value: _s(row, 'taxable_value')),
            _TotalLine(
                label: _s(row, 'gst_label'), value: _s(row, 'gst_value')),
            _TotalLine(
                label: _s(row, 'total_label'),
                value: _s(row, 'total_value'),
                bold: true),
          ],
        ),
      );
}

class _TotalLine extends StatelessWidget {
  const _TotalLine({
    required this.label,
    required this.value,
    this.bold = false,
  });

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x4),
      child: Row(
        children: [
          Expanded(
              child:
                  Text(label, style: bold ? Ds.t.bodyStrong : Ds.t.caption)),
          Text(value, style: bold ? Ds.t.bodyStrong : Ds.t.body),
        ],
      ),
    );
  }
}
