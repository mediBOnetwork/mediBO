// CHANGE #399 (2/3) — the partner records what it paid a supplier.
//
// The partner pays suppliers in the fulfilment split, but the only door onto
// supplier_payments was super_admin-only. partner_sup_record_payment is the
// partner's door onto the SAME writer, so a payment recorded here is
// indistinguishable on the supplier statement from one the office recorded —
// except for the created_by stamp, which says which partner login did it.
//
// The list is the partner's zone and nothing else: the backend selects it, and
// refuses again on save if a hostile client sends a foreign order id.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'partner_ui.dart';

class PartnerSupplierPaymentScreen extends StatefulWidget {
  const PartnerSupplierPaymentScreen({super.key});

  @override
  State<PartnerSupplierPaymentScreen> createState() =>
      _PartnerSupplierPaymentScreenState();
}

class _PartnerSupplierPaymentScreenState
    extends State<PartnerSupplierPaymentScreen> {
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
          .rpc('partner_supplier_payment_console', params: {'p_limit': 40});
      final map = Map<String, dynamic>.from(res as Map);
      RenderLog.write('partner_sup_pay',
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
                  child: PartnerSupplierPaymentView(
                    payload: d,
                    onTapRow: (row) => _recordSheet(d, row),
                  ),
                ),
    );
  }

  Future<void> _recordSheet(
      Map<String, dynamic> d, Map<String, dynamic> r) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => _RecordSheet(payload: d, row: r),
    );
    await _load();
  }
}


/// The zone's supplier orders, split out from the screen so a protected test can
/// pump a payload without Supabase. Every number and label on a row — total,
/// paid, due, and the tone the due chip wears — arrives already formatted; this
/// widget adds no arithmetic and no currency formatting.
class PartnerSupplierPaymentView extends StatelessWidget {
  const PartnerSupplierPaymentView({super.key, required this.payload, required this.onTapRow});

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
    final canRecord = r['can_record'] == true;
    return PartnerCard(
      onTap: canRecord ? () => onTapRow(r) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text((r['supplier_name'] as String?) ?? '',
                      style: Ds.t.body)),
              Text((r['total_text'] as String?) ?? '', style: Ds.t.body),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Row(
            children: [
              Expanded(
                child: Text(
                  [
                    (r['order_label'] as String?) ?? '',
                    (r['date_label'] as String?) ?? '',
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: Ds.t.caption,
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          Row(
            children: [
              PartnerChip(
                  text:
                      '${(r['paid_label'] as String?) ?? ''} ${(r['paid_text'] as String?) ?? ''}',
                  tone: 'neutral'),
              SizedBox(width: Ds.space.x8),
              PartnerChip(
                  text:
                      '${(r['due_label'] as String?) ?? ''} ${(r['due_text'] as String?) ?? ''}',
                  tone: r['due_tone'] as String?),
              const Spacer(),
              if (canRecord)
                Icon(Icons.chevron_right, color: Ds.c.textSecondary),
            ],
          ),
        ],
      ),
    );
  }

}


class _RecordSheet extends StatefulWidget {
  const _RecordSheet({required this.payload, required this.row});

  final Map<String, dynamic> payload;
  final Map<String, dynamic> row;

  @override
  State<_RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<_RecordSheet> {
  final _amount = TextEditingController();
  final _ref = TextEditingController();
  final _note = TextEditingController();
  late String _kind;
  late String _mode;
  String _proofPath = '';
  String _proofName = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _kind = _firstSelected('kind_options');
    _mode = _firstSelected('mode_options');
  }

  String _firstSelected(String key) {
    final opts = (widget.payload[key] as List? ?? const [])
        .map((o) => Map<String, dynamic>.from(o as Map))
        .toList();
    if (opts.isEmpty) return '';
    final sel = opts.firstWhere((o) => o['selected'] == true,
        orElse: () => opts.first);
    return (sel['value'] as String?) ?? '';
  }

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickProof() async {
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
    final ext = (pf.extension ?? 'jpg').toLowerCase();
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('partner_upload_path',
          params: {
            'p_kind': 'supplier_payment',
            'p_key': widget.row['supplier_order_id'],
            'p_ext': ext,
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
        _proofPath = m['path'] as String;
        _proofName = pf.name;
      });
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client
          .rpc('partner_sup_record_payment', params: {
        'p_supplier_order_id': widget.row['supplier_order_id'],
        'p_kind': _kind,
        'p_amount': double.tryParse(_amount.text.trim()) ?? 0,
        'p_mode': _mode,
        'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        'p_screenshot_path': _proofPath.isEmpty ? null : _proofPath,
        'p_screenshot_bucket':
            _proofPath.isEmpty ? null : widget.payload['proof_bucket'],
        'p_ocr': _ref.text.trim().isEmpty
            ? null
            : <String, dynamic>{'utr': _ref.text.trim()},
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
            Text((widget.row['supplier_name'] as String?) ?? '',
                style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
            Text((widget.row['order_label'] as String?) ?? '',
                style: Ds.t.caption),
            SizedBox(height: Ds.space.x24),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.right,
              decoration: InputDecoration(
                  labelText: (d['amount_label'] as String?) ?? ''),
            ),
            SizedBox(height: Ds.space.x12),
            _dropdown(d, 'kind_label', 'kind_options', _kind,
                (v) => setState(() => _kind = v)),
            SizedBox(height: Ds.space.x12),
            _dropdown(d, 'mode_label', 'mode_options', _mode,
                (v) => setState(() => _mode = v)),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _ref,
              decoration:
                  InputDecoration(labelText: (d['ref_label'] as String?) ?? ''),
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
                onPressed: _busy ? null : _pickProof,
                icon: const Icon(Icons.attach_file),
                label: Text(_proofName.isEmpty
                    ? ((d['pick_label'] as String?) ?? '')
                    : _proofName),
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

  Widget _dropdown(Map<String, dynamic> d, String labelKey, String optionsKey,
      String value, ValueChanged<String> onPick) {
    final opts = (d[optionsKey] as List? ?? const [])
        .map((o) => Map<String, dynamic>.from(o as Map))
        .toList();
    return InputDecorator(
      decoration: InputDecoration(labelText: (d[labelKey] as String?) ?? ''),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value.isEmpty ? null : value,
          isExpanded: true,
          style: Ds.t.body,
          onChanged: (v) { if (v != null) onPick(v); },
          items: [
            for (final o in opts)
              DropdownMenuItem<String>(
                value: o['value'] as String?,
                child: Text((o['label'] as String?) ?? ''),
              ),
          ],
        ),
      ),
    );
  }
}
