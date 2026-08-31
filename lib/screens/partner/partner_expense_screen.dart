// CHANGE #399 (3/3) — the partner files an expense against one of its orders.
//
// #323 gave order_costs a manual source and an edited_by stamp, and the
// settlement statement already reads whatever sits there. So this screen adds
// no arithmetic: it writes the line through partner_expense_save, which takes
// the SAME path the admin cost editor takes (build the day's lines, override
// one, recompute the order row and the period totals) and the expense is in
// that day's settlement before the sheet closes.
//
// The receipt lands in the private partner-receipts bucket under the partner's
// own p<id>/ prefix — the same string the storage policy checks, and the
// backend refuses a path outside it.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'partner_ui.dart';

class PartnerExpenseScreen extends StatefulWidget {
  const PartnerExpenseScreen({super.key});

  @override
  State<PartnerExpenseScreen> createState() => _PartnerExpenseScreenState();
}

class _PartnerExpenseScreenState extends State<PartnerExpenseScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client
          .rpc('partner_expense_console', params: {'p_limit': 40});
      final map = Map<String, dynamic>.from(res as Map);
      RenderLog.write('partner_expenses',
          'ok=${map['ok']} rows=${(map['rows'] as List?)?.length ?? 0} '
          'write=${map['can_write']}');
      if (!mounted) return;
      setState(() { _d = map; _loading = false; });
    } catch (_) {
      // The console RPC never answered. The screen falls to its error state,
      // whose words come from ui_copy — cached at boot, so they survive the
      // very outage that produced them.
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    // No Scaffold and no AppBar: PartnerFeaturePage owns both and titles the
    // page with the BACKEND's own label for the feature.
    return ColoredBox(
      color: Ds.c.bg,
      child: _loading
          ? const PartnerSkeleton()
          : (d == null || d['ok'] != true)
              ? PartnerNotice(
                  title: (d?['message'] as String?) == null
                      ? c('partner.error_title')
                      : '',
                  text: (d?['message'] as String?) ??
                      c('partner.error_message'),
                  onRetry: _load,
                  retryLabel: c('partner.retry_label'),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: PartnerExpenseView(
                    payload: d,
                    onTapRow: (row) => _expenseSheet(d, row),
                  ),
                ),
    );
  }

  Future<void> _expenseSheet(
      Map<String, dynamic> d, Map<String, dynamic> r) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => _ExpenseSheet(payload: d, row: r),
    );
    await _load();
  }
}


/// The zone's orders, split out from the screen so a protected test can pump a
/// payload without Supabase. A frozen settlement and a read-only grant both
/// arrive as backend flags — the widget never works out for itself whether an
/// expense may be added.
class PartnerExpenseView extends StatelessWidget {
  const PartnerExpenseView({super.key, required this.payload, required this.onTapRow});

  final Map<String, dynamic> payload;
  final void Function(Map<String, dynamic> row) onTapRow;

  @override
  Widget build(BuildContext context) {
    final d = payload;
    final rows = (d['rows'] as List? ?? const []);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text((d['subtitle'] as String?) ?? '', style: Ds.t.bodySecondary),
        if (((d['readonly_text'] as String?) ?? '').isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          PartnerChip(text: d['readonly_text'] as String, tone: 'warning'),
        ],
        SizedBox(height: Ds.space.x24),
        if (rows.isEmpty)
          PartnerNotice(text: (d['empty_text'] as String?) ?? '')
        else
          for (final r in rows) _row(d, Map<String, dynamic>.from(r as Map)),
      ],
    );
  }

  Widget _row(Map<String, dynamic> d, Map<String, dynamic> r) {
    final frozen = r['frozen'] == true;
    final canAdd = r['can_add'] == true && !frozen;
    final existing = (r['existing'] as List? ?? const []);
    return PartnerCard(
      onTap: canAdd ? () => onTapRow(r) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text((r['order_label'] as String?) ?? '',
                      style: Ds.t.body)),
              Text((r['total_text'] as String?) ?? '', style: Ds.t.body),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            [
              (r['customer_label'] as String?) ?? '',
              (r['date_label'] as String?) ?? '',
            ].where((s) => s.isNotEmpty).join(' · '),
            style: Ds.t.caption,
          ),
          if (frozen) ...[
            SizedBox(height: Ds.space.x12),
            PartnerChip(text: (d['frozen_text'] as String?) ?? '', tone: 'warning'),
          ],
          if (existing.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            Text((r['existing_label'] as String?) ?? '', style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            for (final e in existing)
              _existingRow(Map<String, dynamic>.from(e as Map)),
          ],
          if (canAdd) ...[
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                const Spacer(),
                Icon(Icons.add, color: Ds.c.brand),
                SizedBox(width: Ds.space.x4),
                Text((d['save_label'] as String?) ?? '',
                    style: Ds.t.caption.copyWith(color: Ds.c.brand)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _existingRow(Map<String, dynamic> e) {
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x4),
      child: Row(
        children: [
          Expanded(child: Text((e['label'] as String?) ?? '', style: Ds.t.caption)),
          if (e['has_receipt'] == true) ...[
            Icon(Icons.receipt_long, size: Ds.space.x16, color: Ds.c.textSecondary),
            SizedBox(width: Ds.space.x4),
          ],
          Text((e['value_text'] as String?) ?? '', style: Ds.t.caption),
        ],
      ),
    );
  }

}


class _ExpenseSheet extends StatefulWidget {
  const _ExpenseSheet({required this.payload, required this.row});

  final Map<String, dynamic> payload;
  final Map<String, dynamic> row;

  @override
  State<_ExpenseSheet> createState() => _ExpenseSheetState();
}

class _ExpenseSheetState extends State<_ExpenseSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String _costType = '';
  String _receiptPath = '';
  String _receiptName = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final types = (widget.payload['cost_types'] as List? ?? const []);
    if (types.isNotEmpty) {
      _costType =
          (Map<String, dynamic>.from(types.first as Map)['value'] as String?) ?? '';
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickReceipt() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'pdf'],
        allowMultiple: false,
        withData: true,
      );
    } catch (_) {}
    final bytes = picked?.files.firstOrNull?.bytes;
    if (bytes == null) return;
    final pf = picked!.files.first;
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('partner_upload_path',
          params: {
            'p_kind': 'expense',
            'p_key': widget.row['order_id'],
            'p_ext': (pf.extension ?? 'jpg').toLowerCase(),
          });
      final m = Map<String, dynamic>.from(res as Map);
      if (m['ok'] != true) {
        if (mounted) {
          showToast(context, (m['message'] as String?) ?? '', isError: true);
        }
        return;
      }
      await Supabase.instance.client.storage
          .from(m['bucket'] as String)
          .uploadBinary(m['path'] as String, bytes);
      if (!mounted) return;
      setState(() {
        _receiptPath = m['path'] as String;
        _receiptName = pf.name;
      });
    } catch (e) {
      if (mounted) {
        showToast(context,
            (widget.payload['generic_error'] as String?) ?? e.toString(),
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('partner_expense_save',
          params: {
            'p_order_id': widget.row['order_id'],
            'p_cost_type': _costType,
            'p_amount': double.tryParse(_amount.text.trim()) ?? 0,
            'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
            'p_receipt_path': _receiptPath.isEmpty ? null : _receiptPath,
          });
      final m = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      final msg = (m['message'] as String?) ?? '';
      if (msg.isNotEmpty) showToast(context, msg, isError: m['ok'] != true);
      if (m['ok'] == true) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.payload;
    final types = (d['cost_types'] as List? ?? const [])
        .map((o) => Map<String, dynamic>.from(o as Map))
        .toList();
    return Padding(
      padding: EdgeInsets.only(
        left: Ds.space.x16,
        right: Ds.space.x16,
        top: Ds.space.x24,
        bottom: MediaQuery.of(context).viewInsets.bottom + Ds.space.x24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text((widget.row['order_label'] as String?) ?? '',
                style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
            Text((widget.row['customer_label'] as String?) ?? '',
                style: Ds.t.caption),
            SizedBox(height: Ds.space.x24),
            InputDecorator(
              decoration:
                  InputDecoration(labelText: (d['type_label'] as String?) ?? ''),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _costType.isEmpty ? null : _costType,
                  isExpanded: true,
                  style: Ds.t.body,
                  onChanged: (v) {
                    if (v != null) setState(() => _costType = v);
                  },
                  items: [
                    for (final t in types)
                      DropdownMenuItem<String>(
                        value: t['value'] as String?,
                        child: Text((t['label'] as String?) ?? ''),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.right,
              decoration: InputDecoration(
                  labelText: (d['amount_label'] as String?) ?? ''),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _note,
              decoration:
                  InputDecoration(labelText: (d['note_label'] as String?) ?? ''),
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _pickReceipt,
                icon: const Icon(Icons.receipt_long),
                label: Text(_receiptName.isEmpty
                    ? ((d['pick_label'] as String?) ?? '')
                    : _receiptName),
              ),
            ),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: Text((d['save_label'] as String?) ?? ''),
              ),
            ),
            SizedBox(height: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text((d['cancel_label'] as String?) ?? ''),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
