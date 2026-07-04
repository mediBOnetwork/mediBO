// lib/widgets/sup_pay_panel.dart
// CHANGE #330 — shared supplier-order payment panel.
// Admin (isReadOnly:false): chip tabs, UPI pay button, screenshot upload, manual entry.
// Supplier (isReadOnly:true): read-only mirror of same data — cards + copy rows + zoom only.
// ignore_for_file: use_build_context_synchronously
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/render_log.dart';
import '../utils/safe_parse.dart';
import '../utils/toast.dart';
import 'fullscreen_image.dart';
import 'upi_pay_sheet.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const _kOcrUrl =
    'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/gemini-ocr';

const _kUpiPrompt =
    'This is a UPI payment success screenshot (PhonePe/GPay/Paytm/BHIM/bank). '
    'Reply with STRICT JSON only, no markdown, no code fences: '
    '{"amount":number|null,"payee_name":string|null,"payee_vpa":string|null,'
    '"utr":string|null,"txn_id":string|null,"app":string|null,"paid_at":string|null}. '
    'amount = the rupee amount paid (number only). '
    'payee_name = who received the money. '
    'payee_vpa = the UPI id like name@bank if visible. '
    'utr = the UTR or RRN reference number. '
    'txn_id = the transaction id. '
    'app = the payment app name. '
    'paid_at = the date-time text exactly as shown. '
    'Use null for any field not visible.';

String _fmtDt(DateTime dt) {
  final dd  = dt.day.toString().padLeft(2, '0');
  final mm  = dt.month.toString().padLeft(2, '0');
  final yy  = (dt.year % 100).toString().padLeft(2, '0');
  var h     = dt.hour % 12;
  if (h == 0) h = 12;
  final min = dt.minute.toString().padLeft(2, '0');
  final ap  = dt.hour >= 12 ? 'PM' : 'AM';
  return '$dd/$mm/$yy $h:$min $ap';
}

// ── Public widget ─────────────────────────────────────────────────────────────

class SupPayPanel extends StatefulWidget {
  final Map<String, dynamic> data;
  final String orderId;
  final VoidCallback onReload;
  final bool isReadOnly;

  const SupPayPanel({
    super.key,
    required this.data,
    required this.orderId,
    required this.onReload,
    this.isReadOnly = false,
  });

  @override
  State<SupPayPanel> createState() => _SupPayPanelState();
}

class _SupPayPanelState extends State<SupPayPanel> {
  int _tab      = 0;
  bool _uploading = false;

  // ── Data accessors ───────────────────────────────────────────────────────────
  Map<String, dynamic> get _d => widget.data;
  double get _mrpTotal     => safeParseDouble(_d['mrp_total']);
  double get _totalPaid    => safeParseDouble(_d['total_paid']);
  double get _advRequired  => safeParseDouble(_d['advance_required']);
  double get _advPaid      => safeParseDouble(_d['advance_paid']);
  double get _billsTotal   => safeParseDouble(_d['bills_amount_total']);
  double get _remainingDue => safeParseDouble(_d['remaining_due']);
  bool   get _anyImported  => parseBoolField(_d['any_bill_imported']);
  String get _orderCode    => _d['order_code'] as String? ?? '';
  String get _supplierName => _d['supplier_name'] as String? ?? '';
  String get _vpa          => (_d['payment_address'] as String? ?? '').trim();

  List<Map<String, dynamic>> get _payments =>
      (_d['payments'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _adjustments =>
      (_d['adjustments'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  double get _adjustmentsTotal => safeParseDouble(_d['adjustments_total']);

  String _r(double v) => v == v.truncateToDouble()
      ? '₹${v.toInt()}'
      : '₹${v.toStringAsFixed(2)}';

  // ── UPI pay sheet ────────────────────────────────────────────────────────────
  Future<void> _openPaySheet(double due, String kind) async {
    if (_vpa.isEmpty) {
      RenderLog.write('c336_vpa_missing', 'order=$_orderCode');
      return;
    }
    final note = '${kind == 'advance' ? 'Advance' : 'Balance'} $_orderCode';
    RenderLog.write('c330_pay_$kind',
        'due=${due.toStringAsFixed(2)};vpa=$_vpa');
    await showUpiPaySheet(
      context,
      vpa: _vpa,
      payeeName: _supplierName,
      amount: due,
      note: note,
    );
  }

  // ── OCR + upload + confirm pipeline ─────────────────────────────────────────
  Future<void> _recordPaymentProof(String kind) async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
        allowMultiple: false,
        withData: true,
      );
    } catch (_) {}
    if (picked == null || picked.files.isEmpty) return;
    final pf    = picked.files.first;
    final bytes = pf.bytes;
    if (bytes == null) return;
    final ext   = (pf.extension ?? 'jpg').toLowerCase();

    if (bytes.length > 10 * 1024 * 1024) {
      if (mounted) showToast(context, 'Image too large (max 10 MB)', isError: true);
      return;
    }

    if (!mounted) return;
    setState(() => _uploading = true);

    try {
      // Upload to storage
      final path = 'pay/${_orderCode}_${kind}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final contentType = ext == 'png'
          ? 'image/png'
          : ext == 'webp'
              ? 'image/webp'
              : 'image/jpeg';
      try {
        await Supabase.instance.client.storage
            .from('supplier-bills')
            .uploadBinary(path, bytes,
                fileOptions: FileOptions(contentType: contentType));
      } catch (_) {
        if (mounted) showToast(context, 'Upload failed — try again', isError: true);
        return;
      }

      // OCR
      Map<String, dynamic> ocrMap = {};
      try {
        final resp = await http.post(
          Uri.parse(_kOcrUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_base64': base64Encode(bytes),
            'mime_type': contentType,
            'prompt': _kUpiPrompt,
          }),
        ).timeout(const Duration(seconds: 60));
        if (resp.statusCode == 200) {
          var txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
          txt = txt.trim()
              .replaceAll(RegExp(r'^```json\s*'), '')
              .replaceAll(RegExp(r'^```\s*'), '')
              .replaceAll(RegExp(r'```$'), '');
          final s = txt.indexOf('{'), e = txt.lastIndexOf('}');
          if (s != -1 && e >= s) {
            ocrMap =
                (jsonDecode(txt.substring(s, e + 1)) as Map<String, dynamic>?) ?? {};
          }
        }
      } catch (_) {}

      final ocrAmount = ocrMap['amount'] != null
          ? num.tryParse(ocrMap['amount'].toString())?.toDouble()
          : null;

      if (!mounted) return;

      // Show confirm sheet
      final result = await showModalBottomSheet<String?>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) => C330ConfirmSheet(
          imageBytes: bytes,
          ocrMap: ocrMap,
          ocrAmount: ocrAmount,
          kind: kind,
          orderId: widget.orderId,
          uploadedPath: path,
        ),
      );

      if (!mounted) return;
      if (result == 'ok') {
        showToast(context,
            '${kind == 'advance' ? 'Advance' : 'Balance'} payment recorded ✓');
        RenderLog.write('c330_record', 'kind=$kind;ok=true');
        widget.onReload();
      } else if (result == 'duplicate') {
        showToast(context, 'Already recorded — duplicate payment reference');
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    RenderLog.write('c330_pay_tabs', 'tab=$_tab;ro=${widget.isReadOnly}');
    if (widget.isReadOnly) RenderLog.write('c330_sup_mirror', 'built');

    final advPayments = _payments.where((p) => p['kind'] == 'advance').toList();
    final balPayments = _payments.where((p) => p['kind'] == 'balance').toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Chip tab row
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _PayChip(
            label: 'Payment Info',
            selected: _tab == 0,
            onTap: () => setState(() => _tab = 0),
          ),
          const SizedBox(width: 6),
          _PayChip(
            label: 'Advance Payment',
            selected: _tab == 1,
            onTap: () => setState(() => _tab = 1),
          ),
          const SizedBox(width: 6),
          _PayChip(
            label: 'Remaining',
            selected: _tab == 2,
            onTap: () => setState(() => _tab = 2),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      if (_tab == 0) _buildInfoTab()
      else if (_tab == 1) _buildAdvTab(advPayments)
      else _buildRemTab(balPayments),
    ]);
  }

  // ── Payment Info tab ─────────────────────────────────────────────────────────
  Widget _buildInfoTab() {
    final mrp     = _mrpTotal;
    final paid    = _totalPaid;
    final advReq  = _advRequired;
    final advPaid = _advPaid;
    final anyImp  = _anyImported;
    final remDue  = _remainingDue;
    final remDenom = anyImp ? _billsTotal : mrp;
    final remSub   = anyImp
        ? 'of ${_r(_billsTotal)} bill total'
        : 'of ${_r(mrp)} total';
    final pct = mrp > 0 ? ((paid / mrp) * 100).round() : 0;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _StatCard(
        label: 'Total ordered vs paid',
        headline: '${_r(paid)} / ${_r(mrp)}',
        sub: mrp > 0 ? '$pct% paid' : '—',
        fill: mrp > 0 ? (paid / mrp).clamp(0.0, 1.0) : 0.0,
        barColor: const Color(0xFF1B7A43),
      ),
      _StatCard(
        label: 'Advance (30% of MRP)',
        headline: '${_r(advPaid)} / ${_r(advReq)}',
        sub: '',
        fill: advReq > 0 ? (advPaid / advReq).clamp(0.0, 1.0) : 0.0,
        barColor: advPaid >= advReq && advReq > 0
            ? const Color(0xFF1B7A43)
            : const Color(0xFFD97706),
      ),
      _StatCard(
        label: 'Remaining balance',
        headline: '${_r(remDue)} left',
        sub: remSub,
        fill: remDenom > 0
            ? ((remDenom - remDue) / remDenom).clamp(0.0, 1.0)
            : 0.0,
        barColor: const Color(0xFF1B7A43),
      ),
      if (!widget.isReadOnly) ...[
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: _showManualDialog,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add manual payment',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF1B7A43)),
            foregroundColor: const Color(0xFF1B7A43),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            minimumSize: const Size(double.infinity, 40),
          ),
        ),
      ],
      const SizedBox(height: 12),
      const Text('All payments',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
      const SizedBox(height: 6),
      if (_payments.isEmpty)
        const Text('No payments recorded yet.',
            style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
      else
        ..._payments.map(_buildCompactRow),
      // Adjustments block (c349 — excess-kept and other adjustments from backend)
      if (_adjustments.isNotEmpty) ...[
        const SizedBox(height: 12),
        Builder(builder: (_) {
          RenderLog.write('c349_bill_adj', 'n=${_adjustments.length}');
          RenderLog.write('c352_bill_adj', 'n=${_adjustments.length}');
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Adjustments',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280))),
            const SizedBox(height: 6),
            ..._adjustments.map((adj) {
              final label  = (adj['label']  as String? ?? '').trim();
              final amount = safeParseDouble(adj['amount']);
              final amtStr = amount == amount.truncateToDouble()
                  ? '+₹${amount.toInt()}'
                  : '+₹${amount.toStringAsFixed(2)}';
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Expanded(child: Text(label.isNotEmpty ? label : 'Adjustment',
                      style: const TextStyle(fontSize: 13, color: Color(0xFF111827)))),
                  Text(amtStr, style: const TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w600, color: Color(0xFF065F46))),
                ]),
              );
            }),
            const Divider(height: 16, color: Color(0xFFE5E7EB)),
            Row(children: [
              const Expanded(child: Text('Adjustments total',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: Color(0xFF111827)))),
              Text(
                _adjustmentsTotal == _adjustmentsTotal.truncateToDouble()
                    ? '+₹${_adjustmentsTotal.toInt()}'
                    : '+₹${_adjustmentsTotal.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                    color: Color(0xFF065F46)),
              ),
            ]),
          ]);
        }),
      ],
    ]);
  }

  Widget _buildCompactRow(Map<String, dynamic> p) {
    final amount = safeParseDouble(p['amount']);
    final kind   = p['kind'] as String? ?? '';
    final mode   = p['mode'] as String? ?? '';
    final note   = p['note'] as String?;
    final at     = p['at'] != null
        ? DateTime.tryParse(p['at'] as String)?.toLocal()
        : null;
    final atStr  = at != null ? _fmtDt(at) : '—';

    Color pillBg, pillFg;
    String pillLbl;
    switch (kind) {
      case 'advance':
        pillBg = const Color(0xFFD1FAE5); pillFg = const Color(0xFF065F46);
        pillLbl = 'Adv';
        break;
      case 'balance':
        pillBg = const Color(0xFFEFF6FF); pillFg = const Color(0xFF1E40AF);
        pillLbl = 'Bal';
        break;
      default:
        pillBg = const Color(0xFFF3F4F6); pillFg = const Color(0xFF6B7280);
        pillLbl = 'Other';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration:
              BoxDecoration(color: pillBg, borderRadius: BorderRadius.circular(6)),
          child: Text(pillLbl,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: pillFg)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text('${_r(amount)} · $mode · $atStr',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF111827))),
        ),
        if (note != null && note.isNotEmpty) ...[
          const SizedBox(width: 4),
          Flexible(
            child: Text(note,
                style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ]),
    );
  }

  // ── Advance Payment tab ──────────────────────────────────────────────────────
  Widget _buildAdvTab(List<Map<String, dynamic>> advPayments) {
    final advReq  = _advRequired;
    final advPaid = _advPaid;
    final due     = (advReq - advPaid).clamp(0.0, double.infinity);
    final hasVpa  = _vpa.isNotEmpty;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _StatCard(
        label: 'Advance (30% of MRP)',
        headline: '${_r(advPaid)} / ${_r(advReq)}',
        sub: '',
        fill: advReq > 0 ? (advPaid / advReq).clamp(0.0, 1.0) : 0.0,
        barColor: advPaid >= advReq && advReq > 0
            ? const Color(0xFF1B7A43)
            : const Color(0xFFD97706),
      ),
      if (!widget.isReadOnly) ...[
        if (!hasVpa) ...[
          FilledButton(
            onPressed: null,
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 44),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Pay Advance'),
          ),
          const SizedBox(height: 6),
          const Text(
            "Add the supplier's UPI ID in their profile to enable direct payment",
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
        ] else if (due <= 0) ...[
          FilledButton(
            onPressed: null,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              minimumSize: const Size(double.infinity, 44),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Advance fully paid ✓',
                style: TextStyle(color: Colors.white)),
          ),
        ] else ...[
          FilledButton(
            onPressed: () => _openPaySheet(due, 'advance'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              minimumSize: const Size(double.infinity, 44),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text('Pay Advance ${_r(due)}',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _uploading ? null : () => _recordPaymentProof('advance'),
          icon: _uploading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.upload_outlined, size: 16),
          label: Text(
              _uploading ? 'Uploading…' : 'Upload payment screenshot',
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF1B7A43)),
            foregroundColor: const Color(0xFF1B7A43),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            minimumSize: const Size(double.infinity, 40),
          ),
        ),
        const SizedBox(height: 12),
      ],
      const Text('Advance payments',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7280))),
      const SizedBox(height: 6),
      if (advPayments.isEmpty)
        const Text('No advance payments yet.',
            style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
      else
        ...advPayments.map((p) => C330PayCard(payment: p)),
    ]);
  }

  // ── Remaining Payment tab ────────────────────────────────────────────────────
  Widget _buildRemTab(List<Map<String, dynamic>> balPayments) {
    if (!_anyImported) {
      RenderLog.write('c330_remaining_gate', 'locked');
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 32, color: Color(0xFF9CA3AF)),
          SizedBox(height: 8),
          Text('Remaining payment unlocks after a bill is imported.',
              style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          SizedBox(height: 4),
          Text("Import the supplier's bill in View Bill to continue.",
              style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
        ],
      );
    }

    final remDue   = _remainingDue;
    final billsTot = _billsTotal;
    final paid     = _totalPaid;
    final hasVpa   = _vpa.isNotEmpty;
    final paidFrac = billsTot > 0
        ? ((billsTot - remDue) / billsTot).clamp(0.0, 1.0)
        : 0.0;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _StatCard(
        label: 'Remaining balance',
        headline: '${_r(remDue)} left',
        sub: 'Bill total ${_r(billsTot)} · Paid ${_r(paid)}',
        fill: paidFrac,
        barColor: const Color(0xFF1B7A43),
      ),
      if (!widget.isReadOnly) ...[
        if (!hasVpa) ...[
          FilledButton(
            onPressed: null,
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 44),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Pay Remaining'),
          ),
          const SizedBox(height: 6),
          const Text(
            "Add the supplier's UPI ID in their profile to enable direct payment",
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
        ] else if (remDue <= 0) ...[
          FilledButton(
            onPressed: null,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              minimumSize: const Size(double.infinity, 44),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Fully paid ✓',
                style: TextStyle(color: Colors.white)),
          ),
        ] else ...[
          FilledButton(
            onPressed: () => _openPaySheet(remDue, 'balance'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              minimumSize: const Size(double.infinity, 44),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text('Pay Remaining ${_r(remDue)}',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _uploading ? null : () => _recordPaymentProof('balance'),
          icon: _uploading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.upload_outlined, size: 16),
          label: Text(
              _uploading ? 'Uploading…' : 'Upload payment screenshot',
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF1B7A43)),
            foregroundColor: const Color(0xFF1B7A43),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            minimumSize: const Size(double.infinity, 40),
          ),
        ),
        const SizedBox(height: 12),
      ],
      const Text('Balance payments',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7280))),
      const SizedBox(height: 6),
      if (balPayments.isEmpty)
        const Text('No balance payments yet.',
            style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
      else
        ...balPayments.map((p) => C330PayCard(payment: p)),
    ]);
  }

  // ── Manual payment dialog (admin only) ───────────────────────────────────────
  Future<void> _showManualDialog() async {
    final amtCtrl  = TextEditingController();
    final noteCtrl = TextEditingController();
    String mode    = 'cash';
    String? amtErr;
    bool saving    = false;
    String? saveErr;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('Add manual payment',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: amtCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount (₹)',
                errorText: amtErr,
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              onChanged: (_) {
                if (amtErr != null) set(() => amtErr = null);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: mode,
              decoration: const InputDecoration(
                labelText: 'Mode',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              items: const [
                DropdownMenuItem(value: 'cash',   child: Text('Cash')),
                DropdownMenuItem(value: 'online', child: Text('Online')),
              ],
              onChanged: (v) {
                if (v != null) set(() => mode = v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
            if (saveErr != null) ...[
              const SizedBox(height: 8),
              Text(saveErr!,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFDC2626))),
            ],
          ]),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final amount =
                          double.tryParse(amtCtrl.text.trim());
                      if (amount == null || amount <= 0) {
                        set(() => amtErr = 'Enter a valid amount');
                        return;
                      }
                      set(() { saving = true; saveErr = null; });
                      RenderLog.write('c328_admin_addpay',
                          'order=${widget.orderId};amount=$amount');
                      try {
                        await Supabase.instance.client.rpc(
                          'sup_add_payment',
                          params: {
                            'p_supplier_order_id': widget.orderId,
                            'p_amount': amount,
                            'p_mode': mode,
                            'p_note': noteCtrl.text.trim().isEmpty
                                ? null
                                : noteCtrl.text.trim(),
                          },
                        );
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        if (mounted) {
                          showToast(context, 'Payment recorded ✓');
                          widget.onReload();
                        }
                      } catch (e) {
                        set(() {
                          saving  = false;
                          saveErr = e
                              .toString()
                              .replaceFirst('Exception: ', '');
                        });
                      }
                    },
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1B7A43)),
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
    amtCtrl.dispose();
    noteCtrl.dispose();
  }
}

// ── Chip ──────────────────────────────────────────────────────────────────────

class _PayChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PayChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1B7A43) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : const Color(0xFF374151),
          ),
        ),
      ),
    );
  }
}

// ── Stat card ─────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String headline;
  final String sub;
  final double fill;
  final Color barColor;

  const _StatCard({
    required this.label,
    required this.headline,
    required this.sub,
    required this.fill,
    required this.barColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Color(0xFF9CA3AF))),
        const SizedBox(height: 4),
        Text(headline,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827))),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(sub,
              style:
                  const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
        ],
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fill,
            minHeight: 10,
            backgroundColor: const Color(0xFFF3F4F6),
            color: barColor,
          ),
        ),
      ]),
    );
  }
}

// ── Copy row (public — reused in UPI fallback dialog) ─────────────────────────

class C330CopyRow extends StatelessWidget {
  final String label;
  final String? value;

  const C330CopyRow({super.key, required this.label, this.value});

  @override
  Widget build(BuildContext context) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF9CA3AF))),
            const SizedBox(height: 2),
            Text(v,
                style: const TextStyle(
                    fontSize: 14, color: Color(0xFF111827))),
          ]),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          icon: const Icon(Icons.copy, size: 18, color: Color(0xFF2E7D32)),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: v));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
              content: Text('Copied: $v',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              duration: const Duration(seconds: 1),
            ));
          },
        ),
      ]),
    );
  }
}

// ── Payment card (public — used in all three tabs) ────────────────────────────

class C330PayCard extends StatefulWidget {
  final Map<String, dynamic> payment;
  const C330PayCard({super.key, required this.payment});

  @override
  State<C330PayCard> createState() => _C330PayCardState();
}

class _C330PayCardState extends State<C330PayCard> {
  String? _url;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadUrl();
  }

  Future<void> _loadUrl() async {
    final path   = widget.payment['screenshot_path'] as String?;
    final bucket = widget.payment['screenshot_bucket'] as String? ?? 'supplier-bills';
    if (path == null || path.isEmpty) return;
    setState(() => _loading = true);
    try {
      final url = await Supabase.instance.client.storage
          .from(bucket)
          .createSignedUrl(path, 3600);
      if (mounted) setState(() { _url = url; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p       = widget.payment;
    final amount  = safeParseDouble(p['amount']);
    final kind    = p['kind']       as String? ?? '';
    final mode    = p['mode']       as String? ?? '';
    final payee   = p['payee_name'] as String?;
    final vpa     = p['payee_vpa']  as String?;
    final utr     = p['utr']        as String?;
    final txn     = p['txn_id']     as String?;
    final app     = p['app']        as String?;
    final paidAt  = p['paid_at']    as String?;
    final atRaw   = p['at']         as String?;
    final at      = atRaw != null ? DateTime.tryParse(atRaw)?.toLocal() : null;
    final hasSnap = (p['screenshot_path'] as String? ?? '').isNotEmpty;

    Color kindBg, kindFg;
    String kindLbl;
    switch (kind) {
      case 'advance':
        kindBg = const Color(0xFFD1FAE5); kindFg = const Color(0xFF065F46);
        kindLbl = 'Advance';
        break;
      case 'balance':
        kindBg = const Color(0xFFEFF6FF); kindFg = const Color(0xFF1E40AF);
        kindLbl = 'Balance';
        break;
      default:
        kindBg = const Color(0xFFF3F4F6); kindFg = const Color(0xFF6B7280);
        kindLbl = 'Other';
    }

    final modeLabel = switch (mode) {
      'upi'    => 'UPI',
      'cash'   => 'Cash',
      'online' => 'Online',
      'neft'   => 'NEFT',
      'rtgs'   => 'RTGS',
      _        => mode,
    };

    final amtStr = amount == amount.truncateToDouble()
        ? '₹${amount.toInt()}'
        : '₹${amount.toStringAsFixed(2)}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Pills + amount
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: kindBg, borderRadius: BorderRadius.circular(12)),
            child: Text(kindLbl,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: kindFg)),
          ),
          if (modeLabel.isNotEmpty) ...[
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(12)),
              child: Text(modeLabel,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF374151))),
            ),
          ],
          const Spacer(),
          Text(amtStr,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827))),
        ]),
        const SizedBox(height: 10),
        C330CopyRow(label: 'Payee',          value: payee),
        C330CopyRow(label: 'UPI ID',         value: vpa),
        C330CopyRow(label: 'App',            value: app),
        C330CopyRow(label: 'UTR / RRN',      value: utr),
        C330CopyRow(label: 'Transaction ID', value: txn),
        C330CopyRow(label: 'Paid at',        value: paidAt),
        if (hasSnap) ...[
          const SizedBox(height: 8),
          if (_loading)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF1B7A43)),
            )
          else if (_url != null)
            GestureDetector(
              onTap: () => openFullscreenImage(context, _url!),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  _url!,
                  fit: BoxFit.contain,
                  width: double.infinity,
                  height: 160,
                  errorBuilder: (_, _e, _st) => const Text(
                    'Screenshot unavailable',
                    style:
                        TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                  ),
                ),
              ),
            ),
        ],
        if (at != null) ...[
          const SizedBox(height: 8),
          Text(
            'Recorded ${_fmtDt(at)}',
            style:
                const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
          ),
        ],
      ]),
    );
  }
}

// ── OCR Confirm Sheet ─────────────────────────────────────────────────────────

class C330ConfirmSheet extends StatefulWidget {
  final Uint8List imageBytes;
  final Map<String, dynamic> ocrMap;
  final double? ocrAmount;
  final String kind;
  final String orderId;
  final String uploadedPath;

  const C330ConfirmSheet({
    super.key,
    required this.imageBytes,
    required this.ocrMap,
    required this.ocrAmount,
    required this.kind,
    required this.orderId,
    required this.uploadedPath,
  });

  @override
  State<C330ConfirmSheet> createState() => _C330ConfirmSheetState();
}

class _C330ConfirmSheetState extends State<C330ConfirmSheet> {
  late final TextEditingController _amtCtrl;
  bool _saving   = false;
  String? _amtErr;
  String? _saveErr;

  @override
  void initState() {
    super.initState();
    _amtCtrl = TextEditingController(
      text: widget.ocrAmount != null
          ? widget.ocrAmount!.toStringAsFixed(0)
          : '',
    );
    RenderLog.write('c330_ocr_confirm', 'kind=${widget.kind}');
  }

  @override
  void dispose() {
    _amtCtrl.dispose();
    super.dispose();
  }

  String _s(String key) => (widget.ocrMap[key] as String? ?? '').trim();

  Future<void> _save() async {
    final amount = double.tryParse(_amtCtrl.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _amtErr = 'Enter a valid amount');
      return;
    }
    setState(() { _saving = true; _amtErr = null; _saveErr = null; });
    try {
      final res = await Supabase.instance.client.rpc(
        'sup_record_payment',
        params: {
          'p_supplier_order_id': widget.orderId,
          'p_kind':              widget.kind,
          'p_amount':            amount,
          'p_mode':              'online',
          'p_note':              null,
          'p_screenshot_path':   widget.uploadedPath,
          'p_screenshot_bucket': 'supplier-bills',
          'p_ocr':               widget.ocrMap,
        },
      );
      final resMap = (res as Map<String, dynamic>?) ?? {};
      if (!mounted) return;
      if (resMap['ok'] == true) {
        Navigator.of(context).pop('ok');
      } else {
        final err = resMap['error'] as String? ?? 'unknown';
        if (err == 'duplicate_utr' || err == 'duplicate_txn') {
          Navigator.of(context).pop('duplicate');
        } else if (err == 'bad_amount') {
          setState(() { _saving = false; _amtErr = 'Invalid amount'; });
        } else {
          setState(() { _saving = false; _saveErr = err; });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving  = false;
          _saveErr = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom    = MediaQuery.of(context).viewInsets.bottom;
    final kindLabel = widget.kind == 'advance' ? 'Advance' : 'Balance';
    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
              color: const Color(0xFFD1D5DB),
              borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text('Confirm $kindLabel Payment',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 8),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 32 + bottom),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  widget.imageBytes,
                  fit: BoxFit.contain,
                  width: double.infinity,
                  height: 200,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Details read automatically — verify before saving.',
                style:
                    TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amtCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Amount (₹)*',
                  errorText: _amtErr,
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                ),
                onChanged: (_) {
                  if (_amtErr != null) setState(() => _amtErr = null);
                },
              ),
              const SizedBox(height: 12),
              C330CopyRow(label: 'Payee Name',    value: _s('payee_name')),
              C330CopyRow(label: 'Payee UPI ID',  value: _s('payee_vpa')),
              C330CopyRow(label: 'App',            value: _s('app')),
              C330CopyRow(label: 'UTR / RRN',      value: _s('utr')),
              C330CopyRow(label: 'Transaction ID', value: _s('txn_id')),
              C330CopyRow(label: 'Paid At',        value: _s('paid_at')),
              if (_saveErr != null) ...[
                const SizedBox(height: 8),
                Text(_saveErr!,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFDC2626))),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1B7A43),
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Confirm & Save',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed:
                    _saving ? null : () => Navigator.of(context).pop(null),
                style: TextButton.styleFrom(
                    minimumSize: const Size(double.infinity, 44)),
                child: const Text('Cancel',
                    style: TextStyle(color: Color(0xFF6B7280))),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
