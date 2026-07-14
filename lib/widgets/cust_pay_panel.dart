// lib/widgets/cust_pay_panel.dart — CHANGE #460
// Customer-facing mirror of the supplier payment panel (sup_pay_panel.dart).
// Every string on screen comes straight from customer_order_payment_panel()/
// cust_submit_payment(); nothing is formatted, computed, or decided here.
// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';
import '../utils/safe_parse.dart';
import '../utils/toast.dart';
import 'fullscreen_image.dart';
import 'sup_pay_panel.dart' show C330CopyRow;

class CustPayPanel extends StatefulWidget {
  final String orderId;
  const CustPayPanel({super.key, required this.orderId});

  @override
  State<CustPayPanel> createState() => _CustPayPanelState();
}

class _CustPayPanelState extends State<CustPayPanel> {
  Map<String, dynamic>? _panel;
  bool _loading = true;
  String? _error;
  int _chip = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc(
        'customer_order_payment_panel',
        params: {'p_order_id': widget.orderId},
      );
      final panel = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      final totals = Map<String, dynamic>.from(panel['totals'] as Map? ?? {});
      RenderLog.write('c459_chips', 3);
      RenderLog.write('c459_total', totals['total_label']?.toString() ?? '');
      RenderLog.write('c459_upi_launch', 0);
      RenderLog.write('c459_can_respond', panel['can_respond'] == true);
      final payments = (panel['payments'] as List?) ?? [];
      RenderLog.write('c459_pay_cards', payments.length);
      setState(() { _panel = panel; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Could not load payment details.'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _panel == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43))),
      );
    }
    if (_error != null && _panel == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(_error!, style: const TextStyle(color: Colors.red)),
      );
    }
    final panel = _panel;
    if (panel == null) return const SizedBox.shrink();

    final totals = Map<String, dynamic>.from(panel['totals'] as Map? ?? {});
    final info = Map<String, dynamic>.from(panel['info'] as Map? ?? {});
    final advance = Map<String, dynamic>.from(panel['advance'] as Map? ?? {});
    final remaining = Map<String, dynamic>.from(panel['remaining'] as Map? ?? {});
    final upi = Map<String, dynamic>.from(panel['upi'] as Map? ?? {});
    final canRespond = panel['can_respond'] == true;
    final payments = ((panel['payments'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final paymentsEmptyLabel = panel['payments_empty_label']?.toString() ?? '';
    final advPayments = payments.where((p) => p['kind'] == 'advance').toList();
    final balPayments = payments.where((p) => p['kind'] == 'balance').toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── Headline strip ──────────────────────────────────────────────────
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Expanded(child: _statLine('Total', totals['total_label']?.toString() ?? '')),
          Expanded(child: _statLine('Paid', totals['paid_label']?.toString() ?? '')),
          Expanded(child: _statLine('Due', totals['due_label']?.toString() ?? '')),
        ]),
      ),
      const SizedBox(height: 12),
      // ── Chip row ─────────────────────────────────────────────────────────
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _CustPayChip(label: 'Payment Info', selected: _chip == 0, onTap: () => setState(() => _chip = 0)),
          const SizedBox(width: 6),
          _CustPayChip(label: 'Advance Payment', selected: _chip == 1, onTap: () => setState(() => _chip = 1)),
          const SizedBox(width: 6),
          _CustPayChip(label: 'Remaining', selected: _chip == 2, onTap: () => setState(() => _chip = 2)),
        ]),
      ),
      const SizedBox(height: 12),
      if (_chip == 0) _buildInfoTab(info),
      if (_chip == 1) _buildAdvTab(advance, upi, canRespond, advPayments, paymentsEmptyLabel),
      if (_chip == 2) _buildRemTab(remaining, upi, canRespond, balPayments, paymentsEmptyLabel),
    ]);
  }

  Widget _statLine(String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10.5, color: Color(0xFF9CA3AF))),
      Text(value,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
    ]);
  }

  // ── Chip 1: Payment Info ────────────────────────────────────────────────
  Widget _buildInfoTab(Map<String, dynamic> info) {
    RenderLog.write('c459_bars', 3);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _CustStatCard(
        label: info['ordered_label']?.toString() ?? '',
        headline: info['ordered_value']?.toString() ?? '',
        sub: info['ordered_pct_label']?.toString() ?? '',
        fill: (safeParseInt(info['ordered_pct'])).clamp(0, 100) / 100,
        barColor: const Color(0xFF1B7A43),
      ),
      _CustStatCard(
        label: info['advance_label']?.toString() ?? '',
        headline: info['advance_value']?.toString() ?? '',
        sub: '',
        fill: (safeParseInt(info['advance_pct'])).clamp(0, 100) / 100,
        barColor: const Color(0xFF1B7A43),
      ),
      _CustStatCard(
        label: info['remaining_label']?.toString() ?? '',
        headline: info['remaining_value']?.toString() ?? '',
        sub: info['remaining_sub']?.toString() ?? '',
        fill: (safeParseInt(info['remaining_pct'])).clamp(0, 100) / 100,
        barColor: const Color(0xFF1B7A43),
      ),
    ]);
  }

  // ── Chip 2: Advance Payment ─────────────────────────────────────────────
  Widget _buildAdvTab(
    Map<String, dynamic> advance,
    Map<String, dynamic> upi,
    bool canRespond,
    List<Map<String, dynamic>> advPayments,
    String emptyLabelFallback,
  ) {
    final done = advance['done'] == true;
    final payLabel = advance['pay_label']?.toString() ?? '';
    final emptyLabel = advance['empty_label']?.toString() ?? emptyLabelFallback;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _CustStatCard(
        label: advance['basis_label']?.toString() ?? '',
        headline: advance['value']?.toString() ?? '',
        sub: '',
        fill: (safeParseInt(advance['pct'])).clamp(0, 100) / 100,
        barColor: done ? const Color(0xFF1B7A43) : const Color(0xFFD97706),
      ),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: done ? null : () => _openPaySheet(upi, payLabel),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1B7A43),
            minimumSize: const Size(double.infinity, 44),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(payLabel, style: const TextStyle(color: Colors.white)),
        ),
      ),
      const SizedBox(height: 10),
      _uploadButton(() => _openUploadSheet(advance['required'], advance['paid'])),
      const SizedBox(height: 12),
      const Text('Advance payments',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
      const SizedBox(height: 6),
      if (advPayments.isEmpty)
        Text(emptyLabel, style: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
      else
        ...advPayments.map((p) => _CustPayCard(
              payment: p, orderId: widget.orderId, canRespond: canRespond, onReload: _load,
            )),
    ]);
  }

  // ── Chip 3: Remaining ───────────────────────────────────────────────────
  Widget _buildRemTab(
    Map<String, dynamic> remaining,
    Map<String, dynamic> upi,
    bool canRespond,
    List<Map<String, dynamic>> balPayments,
    String emptyLabelFallback,
  ) {
    final canPay = remaining['can_pay'] == true;
    final payLabel = remaining['pay_label']?.toString() ?? '';
    final emptyLabel = remaining['empty_label']?.toString() ?? emptyLabelFallback;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _CustStatCard(
        label: 'Remaining balance',
        headline: remaining['value']?.toString() ?? '',
        sub: remaining['sub']?.toString() ?? '',
        fill: (safeParseInt(remaining['pct'])).clamp(0, 100) / 100,
        barColor: const Color(0xFF1B7A43),
      ),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: canPay ? () => _openPaySheet(upi, payLabel) : null,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1B7A43),
            minimumSize: const Size(double.infinity, 44),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(payLabel, style: const TextStyle(color: Colors.white)),
        ),
      ),
      const SizedBox(height: 10),
      _uploadButton(() => _openUploadSheet(null, null, dueOverride: remaining['due'])),
      const SizedBox(height: 12),
      const Text('Balance payments',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
      const SizedBox(height: 6),
      if (balPayments.isEmpty)
        Text(emptyLabel, style: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
      else
        ...balPayments.map((p) => _CustPayCard(
              payment: p, orderId: widget.orderId, canRespond: canRespond, onReload: _load,
            )),
    ]);
  }

  Widget _uploadButton(VoidCallback onPressed) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.upload_outlined, size: 16),
      label: const Text('Upload payment screenshot',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Color(0xFF1B7A43)),
        foregroundColor: const Color(0xFF1B7A43),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        minimumSize: const Size(double.infinity, 40),
      ),
    );
  }

  // ── Pay sheet (QR only — no deep link) ──────────────────────────────────
  Future<void> _openPaySheet(Map<String, dynamic> upi, String payLabel) async {
    final qrPayload = upi['qr_payload']?.toString();
    if (qrPayload == null || qrPayload.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _CustPaySheet(
        qrPayload: qrPayload,
        vpa: upi['vpa']?.toString() ?? '',
        payeeName: upi['name']?.toString() ?? '',
        hint: upi['hint']?.toString() ?? '',
        payLabel: payLabel,
      ),
    );
  }

  // ── Upload sheet ─────────────────────────────────────────────────────────
  Future<void> _openUploadSheet(dynamic required, dynamic paid, {dynamic dueOverride}) async {
    num prefill = 0;
    if (dueOverride != null) {
      prefill = num.tryParse(dueOverride.toString()) ?? 0;
    } else if (required != null && paid != null) {
      final r = num.tryParse(required.toString()) ?? 0;
      final p = num.tryParse(paid.toString()) ?? 0;
      prefill = (r - p) < 0 ? 0 : (r - p);
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _CustPaymentUploadSheet(
        orderId: widget.orderId,
        prefillAmount: prefill,
        onSuccess: (message) {
          if (mounted) showToast(context, message);
          _load();
        },
      ),
    );
  }
}

// ── Chip ───────────────────────────────────────────────────────────────────

class _CustPayChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _CustPayChip({required this.label, required this.selected, required this.onTap});

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
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : const Color(0xFF374151))),
      ),
    );
  }
}

// ── Stat card ────────────────────────────────────────────────────────────────

class _CustStatCard extends StatelessWidget {
  final String label;
  final String headline;
  final String sub;
  final double fill;
  final Color barColor;
  const _CustStatCard({
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
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
        const SizedBox(height: 4),
        Text(headline, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
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

// ── Pay sheet — QR + copy only, no deep link ──────────────────────────────

class _CustPaySheet extends StatelessWidget {
  final String qrPayload;
  final String vpa;
  final String payeeName;
  final String hint;
  final String payLabel;
  const _CustPaySheet({
    required this.qrPayload,
    required this.vpa,
    required this.payeeName,
    required this.hint,
    required this.payLabel,
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        Container(
          width: 40, height: 4,
          decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Expanded(
              child: Text('$payLabel — mediBO',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.of(context).pop(),
              visualDensity: VisualDensity.compact,
            ),
          ]),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 32 + bottom),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: QrImageView(
                    data: qrPayload,
                    version: QrVersions.auto,
                    size: 220,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              C330CopyRow(label: 'UPI ID', value: vpa),
              C330CopyRow(label: 'Amount', value: payLabel),
              if (payeeName.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(payeeName, style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
                const SizedBox(height: 10),
              ],
              if (hint.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFFF5F6F8), borderRadius: BorderRadius.circular(10)),
                  child: Text(hint, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ── Upload sheet — gallery first ──────────────────────────────────────────

class _CustPaymentUploadSheet extends StatefulWidget {
  final String orderId;
  final num prefillAmount;
  final void Function(String message) onSuccess;
  const _CustPaymentUploadSheet({required this.orderId, required this.prefillAmount, required this.onSuccess});

  @override
  State<_CustPaymentUploadSheet> createState() => _CustPaymentUploadSheetState();
}

class _CustPaymentUploadSheetState extends State<_CustPaymentUploadSheet> {
  late final TextEditingController _amountCtrl =
      TextEditingController(text: widget.prefillAmount > 0 ? widget.prefillAmount.toString() : '');
  final TextEditingController _utrCtrl = TextEditingController();
  XFile? _picked;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _utrCtrl.dispose();
    super.dispose();
  }

  // C1 — gallery is the default, one-tap action: a payment screenshot is
  // always already in the gallery (just captured in PhonePe/GPay).
  Future<void> _pickFromGallery() async {
    RenderLog.write('c459_gallery', 1);
    try {
      final img = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
      if (img == null) return;
      setState(() { _picked = img; _error = null; });
    } catch (_) {}
  }

  Future<void> _submit() async {
    final amount = num.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter the amount you paid.');
      return;
    }
    final picked = _picked;
    if (picked == null) {
      setState(() => _error = 'Upload the payment screenshot so we can verify it.');
      return;
    }
    setState(() { _submitting = true; _error = null; });

    final ext = (picked.name.split('.').isNotEmpty ? picked.name.split('.').last : 'jpg').toLowerCase();
    final safeExt = ['jpg', 'jpeg', 'png', 'webp'].contains(ext) ? ext : 'jpg';
    final token = '${DateTime.now().microsecondsSinceEpoch}';
    final path = '${widget.orderId}/$token.$safeExt';
    final contentType = safeExt == 'png' ? 'image/png' : safeExt == 'webp' ? 'image/webp' : 'image/jpeg';

    try {
      final bytes = await picked.readAsBytes();
      await Supabase.instance.client.storage.from('payment-proofs').uploadBinary(
            path, bytes,
            fileOptions: FileOptions(contentType: contentType),
          );
    } catch (_) {
      if (mounted) setState(() { _submitting = false; _error = 'Screenshot upload failed. Try again.'; });
      return;
    }

    try {
      final res = await Supabase.instance.client.rpc('cust_submit_payment', params: {
        'p_order_id': widget.orderId,
        'p_amount': amount,
        'p_screenshot_path': path,
        'p_utr': _utrCtrl.text.trim().isEmpty ? null : _utrCtrl.text.trim(),
        'p_app': null,
        'p_ocr': null,
      });
      final result = Map<String, dynamic>.from(res as Map);
      final message = result['message']?.toString() ?? '';
      if (result['ok'] == true) {
        if (mounted) Navigator.of(context).pop();
        widget.onSuccess(message);
      } else {
        if (mounted) setState(() { _submitting = false; _error = message; });
      }
    } catch (e) {
      if (mounted) setState(() { _submitting = false; _error = 'Could not submit payment.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Upload payment proof', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        TextField(
          controller: _amountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Amount paid', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _utrCtrl,
          decoration: const InputDecoration(labelText: 'UTR / reference (optional)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _pickFromGallery,
          icon: const Icon(Icons.photo_library_outlined, size: 16),
          label: Text(_picked == null ? 'Choose screenshot from gallery' : 'Selected: ${_picked!.name}'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 40)),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12.5)),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _submitting ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: _submitting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Submit'),
          ),
        ),
      ]),
    );
  }
}

// ── Payment status card — customer sees everything except accept/reject ────

class _CustPayCard extends StatefulWidget {
  final Map<String, dynamic> payment;
  final String orderId;
  final bool canRespond;
  final VoidCallback onReload;
  const _CustPayCard({
    required this.payment,
    required this.orderId,
    required this.canRespond,
    required this.onReload,
  });

  @override
  State<_CustPayCard> createState() => _CustPayCardState();
}

class _CustPayCardState extends State<_CustPayCard> {
  String? _url;
  bool _loadingUrl = false;
  bool _acting = false;

  @override
  void initState() {
    super.initState();
    _loadUrl();
  }

  Future<void> _loadUrl() async {
    final path = widget.payment['screenshot'] as String?;
    final bucket = widget.payment['bucket'] as String? ?? 'payment-proofs';
    if (path == null || path.isEmpty) return;
    setState(() => _loadingUrl = true);
    try {
      final url = await Supabase.instance.client.storage.from(bucket).createSignedUrl(path, 3600);
      if (mounted) setState(() { _url = url; _loadingUrl = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingUrl = false);
    }
  }

  Color _toneColor(String tone) => switch (tone) {
        'ok' => const Color(0xFF16A34A),
        'bad' => const Color(0xFFDC2626),
        _ => const Color(0xFFD97706),
      };

  Color _toneBg(String tone) => switch (tone) {
        'ok' => const Color(0xFFD1FAE5),
        'bad' => const Color(0xFFFEE2E2),
        _ => const Color(0xFFFEF3C7),
      };

  Future<void> _accept() async {
    setState(() => _acting = true);
    try {
      await Supabase.instance.client.rpc('verify_and_accept_payment', params: {
        'p_claim_id': widget.payment['id'],
        'p_order_id': widget.orderId,
      });
      widget.onReload();
    } catch (_) {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _reject() async {
    final ctrl = TextEditingController(text: 'Not received');
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Payment', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Reason'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626), foregroundColor: Colors.white),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (reason == null || reason.isEmpty || !mounted) return;
    setState(() => _acting = true);
    try {
      await Supabase.instance.client.rpc('reject_payment_claim', params: {
        'p_claim_id': widget.payment['id'],
        'p_order_id': widget.orderId,
        'p_reason': reason,
      });
      widget.onReload();
    } catch (_) {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payment;
    final statusLabel = p['status_label']?.toString() ?? '';
    final statusTone = p['status_tone']?.toString() ?? 'pending';
    final methodLabel = p['method_label']?.toString() ?? '';
    final reason = p['reason']?.toString();
    final hasSnap = (p['screenshot'] as String? ?? '').isNotEmpty;
    final showActions = widget.canRespond && p['status'] == 'claimed';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: _toneBg(statusTone), borderRadius: BorderRadius.circular(12)),
            child: Text(statusLabel,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _toneColor(statusTone))),
          ),
          const Spacer(),
          if (methodLabel.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(12)),
              child: Text(methodLabel,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF374151))),
            ),
        ]),
        const SizedBox(height: 10),
        C330CopyRow(label: 'Amount', value: p['amount_label']?.toString()),
        C330CopyRow(label: 'Payee', value: p['payee_name']?.toString()),
        C330CopyRow(label: 'App', value: p['app']?.toString()),
        C330CopyRow(label: 'UTR', value: p['utr']?.toString()),
        C330CopyRow(label: 'Txn', value: p['txn_id']?.toString()),
        C330CopyRow(label: 'Paid', value: p['paid_label']?.toString()),
        C330CopyRow(label: 'Collected by', value: p['collected_by']?.toString()),
        C330CopyRow(label: 'Location', value: p['location']?.toString()),
        if (reason != null && reason.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(reason, style: const TextStyle(fontSize: 11.5, color: Color(0xFFDC2626))),
        ],
        if (hasSnap) ...[
          const SizedBox(height: 8),
          if (_loadingUrl)
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)))
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
                  errorBuilder: (_, e, st) => const Text('Screenshot unavailable',
                      style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
                ),
              ),
            ),
        ],
        if (showActions) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _acting ? null : _reject,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFDC2626)),
                  foregroundColor: const Color(0xFFDC2626),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  minimumSize: const Size(0, 40),
                ),
                child: const Text('Reject'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _acting ? null : _accept,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B7A43),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  minimumSize: const Size(0, 40),
                ),
                child: _acting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Accept'),
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}
