// CMD #452 — feature_gaps #131: no returns or credit-note path for the
// customer. Pharmacy buying runs on saleable and expiry returns; damaged stock,
// short supply, wrong product and near-expiry had no route back.
//
// The returns ENGINE already existed (CHANGE #867: the frozen slab, the
// reversed GST, the credit value). This is the buyer's door onto it. What is
// returnable is `my_order_return_sheet()`'s answer — a line opens up only once
// the supplier bill covering it is verified, and when nothing is returnable the
// backend says so in its own words. The sheet never works that out from a
// quantity it can see.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/customer_care_service.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'order_cancel_sheet.dart'
    show CareSheetShell, CareSheetSkeleton, CareRefusal, CareReasonRow;

/// Returns true when at least one return was raised.
Future<bool> showOrderReturnSheet(BuildContext context, String orderId) async {
  final raised = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _OrderReturnSheet(orderId: orderId),
  );
  return raised == true;
}

class _OrderReturnSheet extends StatefulWidget {
  final String orderId;
  const _OrderReturnSheet({required this.orderId});

  @override
  State<_OrderReturnSheet> createState() => _OrderReturnSheetState();
}

class _OrderReturnSheetState extends State<_OrderReturnSheet> {
  Map<String, dynamic>? _sheet;
  Map<String, dynamic>? _panel;
  bool _busy = false;

  /// order_item_id -> the qty this buyer typed. A line the buyer never touched
  /// is absent, never defaulted to zero-or-all.
  final Map<String, int> _picked = {};
  String _reason = '';
  String _condition = '';
  final _note = TextEditingController();

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

  Future<void> _load() async {
    final s = await CustomerCare.returnSheet(widget.orderId);
    final p = await CustomerCare.returns(widget.orderId);
    if (!mounted) return;
    setState(() {
      _sheet = s;
      _panel = p;
    });
    RenderLog.write('c452_return_sheet', careRows(s['lines']).length);
  }

  bool get _canSubmit =>
      _picked.values.any((q) => q > 0) && _reason.isNotEmpty && !_busy;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _busy = true);
    final items = [
      for (final e in _picked.entries)
        if (e.value > 0)
          {
            'order_item_id': e.key,
            'qty': e.value,
            'reason_code': _reason,
            if (_condition.isNotEmpty) 'condition_code': _condition,
            if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
          }
    ];
    final res = await CustomerCare.requestReturn(widget.orderId, items);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['ok'] != true) {
      showToast(context, careStr(res, 'message'), isError: true);
      return;
    }
    showToast(context, careStr(res, 'toast'));
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final s = _sheet;
    return CareSheetShell(
      child: s == null
          ? const CareSheetSkeleton()
          : s['ok'] != true
              ? CareRefusal(message: careStr(s, 'message'))
              : _body(s),
    );
  }

  Widget _body(Map<String, dynamic> s) {
    final lines = careRows(s['lines']);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(careStr(s, 'title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x8),
        Text(careStr(s, 'body'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        if (s['can_return'] != true) ...[
          Text(careStr(s, 'empty_title'), style: Ds.t.bodyStrong),
          SizedBox(height: Ds.space.x8),
          Text(careStr(s, 'empty_note'), style: Ds.t.caption),
        ] else ...[
          for (final l in lines)
            _ReturnLine(
              line: l,
              qtyLabel: careStr(s, 'qty_label'),
              qty: _picked[careStr(l, 'order_item_id')] ?? 0,
              onQty: (q) => setState(
                  () => _picked[careStr(l, 'order_item_id')] = q),
            ),
          SizedBox(height: Ds.space.x16),
          Text(careStr(s, 'reason_label'), style: Ds.t.bodyStrong),
          SizedBox(height: Ds.space.x8),
          for (final r in careRows(s['reasons']))
            CareReasonRow(
              label: careStr(r, 'label'),
              selected: _reason == careStr(r, 'code'),
              onTap: () => setState(() => _reason = careStr(r, 'code')),
            ),
          SizedBox(height: Ds.space.x16),
          Text(careStr(s, 'condition_label'), style: Ds.t.bodyStrong),
          SizedBox(height: Ds.space.x8),
          for (final co in careRows(s['conditions']))
            CareReasonRow(
              label: careStr(co, 'label'),
              selected: _condition == careStr(co, 'code'),
              onTap: () => setState(() => _condition = careStr(co, 'code')),
            ),
          SizedBox(height: Ds.space.x16),
          Text(careStr(s, 'note_label'), style: Ds.t.bodyStrong),
          SizedBox(height: Ds.space.x8),
          TextField(
            controller: _note,
            minLines: 2,
            maxLines: 4,
            style: Ds.t.body,
            decoration: InputDecoration(
              filled: true,
              fillColor: Ds.c.bg,
              border: OutlineInputBorder(
                  borderRadius: Ds.r.rButton, borderSide: BorderSide.none),
            ),
          ),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: _canSubmit ? _submit : null,
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              child: Text(careStr(s, 'cta')),
            ),
          ),
        ],
        if (_panel?['has_returns'] == true) ...[
          SizedBox(height: Ds.space.x32),
          OrderReturnsPanel(panel: _panel!),
        ],
      ],
    );
  }
}

class _ReturnLine extends StatelessWidget {
  final Map<String, dynamic> line;
  final String qtyLabel;
  final int qty;
  final ValueChanged<int> onQty;
  const _ReturnLine(
      {required this.line,
      required this.qtyLabel,
      required this.qty,
      required this.onQty});

  @override
  Widget build(BuildContext context) {
    // `returnable` is the server's cap; the stepper never goes past it and the
    // server refuses anyway.
    final max = (line['returnable'] as num?)?.toInt() ?? 0;
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rCard),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(careStr(line, 'name'), style: Ds.t.body),
              SizedBox(height: Ds.space.x4),
              Text('$qtyLabel · ${careStr(line, 'returnable_label')}',
                  style: Ds.t.caption),
            ],
          ),
        ),
        SizedBox(width: Ds.space.x12),
        _Stepper(
            value: qty,
            max: max,
            onChanged: onQty),
      ]),
    );
  }
}

class _Stepper extends StatelessWidget {
  final int value;
  final int max;
  final ValueChanged<int> onChanged;
  const _Stepper(
      {required this.value, required this.max, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, VoidCallback? onTap) => SizedBox(
          width: Ds.touch.minTarget,
          height: Ds.touch.minTarget,
          child: IconButton(
              onPressed: onTap, icon: Icon(icon, size: 18)),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      btn(Icons.remove, value > 0 ? () => onChanged(value - 1) : null),
      SizedBox(
        width: Ds.space.x32,
        child: Text('$value',
            textAlign: TextAlign.center, style: Ds.t.bodyStrong),
      ),
      btn(Icons.add, value < max ? () => onChanged(value + 1) : null),
    ]);
  }
}

/// The returns already on this order and the credit that came out of them.
/// Every rupee, status word and tone is the payload's.
class OrderReturnsPanel extends StatelessWidget {
  final Map<String, dynamic> panel;
  const OrderReturnsPanel({super.key, required this.panel});

  @override
  Widget build(BuildContext context) {
    final rows = careRows(panel['returns']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(careStr(panel, 'title'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (rows.isEmpty)
          Text(careStr(panel, 'empty_note'), style: Ds.t.caption)
        else
          for (final r in rows) _ReturnRow(row: r),
        if (panel['has_credit'] == true) ...[
          SizedBox(height: Ds.space.x16),
          Row(children: [
            Expanded(
                child: Text(careStr(panel, 'credit_total_label'),
                    style: Ds.t.bodyStrong)),
            Text(careStr(panel, 'credit_total_display'),
                style: Ds.t.bodyStrong),
          ]),
          SizedBox(height: Ds.space.x4),
          Text(careStr(panel, 'credit_note'), style: Ds.t.caption),
        ],
      ],
    );
  }
}

class _ReturnRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const _ReturnRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final tone = careStr(row, 'status_tone');
    final fg = switch (tone) {
      'success' => Ds.c.success,
      'warning' => Ds.c.warning,
      'danger' => Ds.c.danger,
      _ => Ds.c.info,
    };
    final bg = switch (tone) {
      'success' => Ds.c.successSoft,
      'warning' => Ds.c.warningSoft,
      'danger' => Ds.c.dangerSoft,
      _ => Ds.c.infoSoft,
    };
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rCard),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(careStr(row, 'name'), style: Ds.t.body)),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x4),
              decoration:
                  BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
              child: Text(careStr(row, 'status_label'),
                  style: Ds.t.caption.copyWith(color: fg)),
            ),
          ]),
          SizedBox(height: Ds.space.x4),
          Text(
              [
                careStr(row, 'qty_label'),
                careStr(row, 'reason_label'),
                careStr(row, 'condition_label'),
              ].where((s) => s.isNotEmpty).join(' · '),
              style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Row(children: [
            Expanded(
                child: Text(careStr(row, 'raised_label'),
                    style: Ds.t.caption)),
            Text(careStr(row, 'credit_display'), style: Ds.t.caption),
          ]),
          if (careStr(row, 'reject_reason').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(careStr(row, 'reject_reason'),
                style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
        ],
      ),
    );
  }
}
