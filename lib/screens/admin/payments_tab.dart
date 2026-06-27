// CHANGE #211 — Admin Payments verification tab
import 'package:flutter/material.dart';
import '../../services/payment_claims_service.dart';
import '../../utils/render_log.dart';

// ── Public widget ────────────────────────────────────────────────────────────

class PaymentsTab extends StatefulWidget {
  final ValueChanged<int>? onClaimedCountChanged;
  const PaymentsTab({super.key, this.onClaimedCountChanged});

  @override
  State<PaymentsTab> createState() => _PaymentsTabState();
}

class _PaymentsTabState extends State<PaymentsTab> {
  List<Map<String, dynamic>> _claims = [];
  bool _loading = true;
  String? _error;

  // Per-claim busy set (claimId -> bool)
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    RenderLog.write('c211_tab_built', 1);
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() { _loading = true; _error = null; });
    try {
      final data = await PaymentClaimsService.fetchClaims();
      if (!mounted) return;
      setState(() { _claims = data; _loading = false; });
      final claimed = data.where((c) => c['status'] == 'claimed').length;
      RenderLog.write('c211_claims_loaded_$claimed', 1);
      widget.onClaimedCountChanged?.call(claimed);
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, style: const TextStyle(fontSize: 13, color: Color(0xFFDC2626))),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _fetch,
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
              child: const Text('Retry'),
            ),
          ]),
        ),
      );
    }
    if (_claims.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.receipt_long_outlined, size: 48, color: Color(0xFFD1D5DB)),
            SizedBox(height: 16),
            Text('No payment claims yet.',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
          ]),
        ),
      );
    }

    final claimed = _claims.where((c) => c['status'] == 'claimed').length;
    return RefreshIndicator(
      onRefresh: _fetch,
      color: const Color(0xFF1B7A43),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('$claimed pending verification',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
          ),
          ..._claims.map((c) => _ClaimCard(
                claim: c,
                busy: _busy.contains(c['claim_id'] as String? ?? ''),
                onVerify: (orderId) => _doVerify(c['claim_id'] as String, orderId),
                onReject: () => _doReject(c['claim_id'] as String),
              )),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _doVerify(String claimId, String orderId) async {
    if (_busy.contains(claimId)) return;
    RenderLog.write('c211_verify_tapped', 1);

    // Find the PO for the toast
    final claim = _claims.firstWhere((c) => c['claim_id'] == claimId, orElse: () => {});
    final orders = _parseOrders(claim['orders']);
    final order = orders.firstWhere((o) => o['order_id'] == orderId, orElse: () => {});
    final po = order['po'] as String? ?? orderId;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Verify payment?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: Text('Verify payment and accept $po?',
            style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
            child: const Text('Verify & Accept'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy.add(claimId));
    try {
      await PaymentClaimsService.verifyAndAccept(claimId, orderId);
      if (!mounted) return;
      RenderLog.write('c211_verify_ok', 1);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Verified & accepted $po'), backgroundColor: const Color(0xFF1B7A43)));
      await _fetch();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: const Color(0xFFDC2626)));
    } finally {
      if (mounted) setState(() => _busy.remove(claimId));
    }
  }

  Future<void> _doReject(String claimId) async {
    if (_busy.contains(claimId)) return;
    final reasonCtrl = TextEditingController(text: 'Not received');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Reject claim?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Reason:', style: TextStyle(fontSize: 13, color: Color(0xFF374151))),
          const SizedBox(height: 8),
          TextField(
            controller: reasonCtrl,
            autofocus: true,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 13),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final reason = reasonCtrl.text.trim().isEmpty ? 'Not received' : reasonCtrl.text.trim();
    reasonCtrl.dispose();

    setState(() => _busy.add(claimId));
    try {
      await PaymentClaimsService.rejectClaim(claimId, reason);
      if (!mounted) return;
      RenderLog.write('c211_reject_ok', 1);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Claim rejected')));
      await _fetch();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: const Color(0xFFDC2626)));
    } finally {
      if (mounted) setState(() => _busy.remove(claimId));
    }
  }

  static List<Map<String, dynamic>> _parseOrders(dynamic raw) {
    if (raw == null) return [];
    try {
      return List<Map<String, dynamic>>.from(raw as List);
    } catch (_) {
      return [];
    }
  }
}

// ── Claim card ────────────────────────────────────────────────────────────────

class _ClaimCard extends StatelessWidget {
  final Map<String, dynamic> claim;
  final bool busy;
  final Future<void> Function(String orderId) onVerify;
  final VoidCallback onReject;

  const _ClaimCard({
    required this.claim,
    required this.busy,
    required this.onVerify,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final status = claim['status'] as String? ?? 'claimed';
    final app = claim['app'] as String? ?? '—';
    final phone = claim['sender_phone'] as String? ?? '';
    final customerName = claim['customer_name'] as String? ?? 'Unknown customer';
    final amount = claim['amount'];
    final utr = claim['utr'] as String? ?? '—';
    final txnId = claim['txn_id'] as String? ?? '—';
    final paidAt = claim['paid_at'] as String? ?? '—';
    final payeeName = claim['payee_name'] as String? ?? '—';
    final filePath = claim['file_path'] as String? ?? '';
    final verifyReason = claim['verify_reason'] as String? ?? '';
    final orders = _parseOrders(claim['orders']);

    final shortPhone = phone.length >= 10 ? phone.substring(phone.length - 10) : phone;
    final amountStr = _fmtAmount(amount);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Top row: app name + status chip
          Row(children: [
            Expanded(
              child: Text(app,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            ),
            _StatusChip(status: status),
          ]),
          const SizedBox(height: 6),

          // Customer
          Text('$customerName • $shortPhone',
              style: const TextStyle(fontSize: 13, color: Color(0xFF374151))),
          const SizedBox(height: 10),

          // OCR block
          _OcrBlock(amountStr: amountStr, utr: utr, txnId: txnId, paidAt: paidAt, payeeName: payeeName),
          const SizedBox(height: 12),

          // Screenshot
          if (filePath.isNotEmpty) _ScreenshotThumbnail(filePath: filePath),
          if (filePath.isNotEmpty) const SizedBox(height: 12),

          // Orders section (only for claimed)
          if (status == 'claimed') ...[
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            const SizedBox(height: 10),
            if (orders.isEmpty)
              const Text('No pending order found for this customer.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
            else ...[
              const Text('Pending orders:',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
              const SizedBox(height: 8),
              ...orders.map((o) => _OrderRow(
                    order: o,
                    claimAmount: amount,
                    busy: busy,
                    onVerify: () => onVerify(o['order_id'] as String),
                  )),
            ],
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: busy ? null : onReject,
                style: TextButton.styleFrom(foregroundColor: const Color(0xFFDC2626)),
                child: const Text('Reject', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ],

          // Verified / rejected state
          if (status == 'verified' || status == 'rejected') ...[
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            const SizedBox(height: 8),
            if (verifyReason.isNotEmpty)
              Text('Reason: $verifyReason',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          ],
        ]),
      ),
    );
  }

  static List<Map<String, dynamic>> _parseOrders(dynamic raw) {
    if (raw == null) return [];
    try { return List<Map<String, dynamic>>.from(raw as List); } catch (_) { return []; }
  }

  static String _fmtAmount(dynamic amount) {
    if (amount == null) return '—';
    final n = (amount as num).toDouble();
    if (n == n.truncateToDouble()) {
      // Integer — format with Indian grouping
      return _indianGroup(n.toInt().toString());
    }
    return _indianGroup(n.toStringAsFixed(2));
  }

  static String _indianGroup(String s) {
    // Split on decimal
    final parts = s.split('.');
    var intPart = parts[0];
    final decPart = parts.length > 1 ? '.${parts[1]}' : '';
    if (intPart.length <= 3) return '₹$intPart$decPart';
    final last3 = intPart.substring(intPart.length - 3);
    var rest = intPart.substring(0, intPart.length - 3);
    final buffer = StringBuffer(last3);
    while (rest.length > 2) {
      buffer.write(',${rest.substring(rest.length - 2)}');
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) buffer.write(',$rest');
    return '₹${buffer.toString().split('').reversed.join()}$decPart';
  }
}

// ── OCR info block ────────────────────────────────────────────────────────────

class _OcrBlock extends StatelessWidget {
  final String amountStr, utr, txnId, paidAt, payeeName;
  const _OcrBlock({required this.amountStr, required this.utr, required this.txnId, required this.paidAt, required this.payeeName});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Paid: $amountStr',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 4),
        _row('UTR', utr),
        _row('Txn', txnId),
        _row('Time', paidAt),
        _row('Payee', payeeName),
      ]),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(children: [
      SizedBox(width: 44, child: Text('$label:', style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))),
      Expanded(child: Text(value, style: const TextStyle(fontSize: 12, color: Color(0xFF374151)), overflow: TextOverflow.ellipsis)),
    ]),
  );
}

// ── Per-order row inside a claim ──────────────────────────────────────────────

class _OrderRow extends StatelessWidget {
  final Map<String, dynamic> order;
  final dynamic claimAmount;
  final bool busy;
  final VoidCallback onVerify;

  const _OrderRow({required this.order, required this.claimAmount, required this.busy, required this.onVerify});

  @override
  Widget build(BuildContext context) {
    final po = order['po'] as String? ?? '—';
    final itemCount = order['item_count'] as int? ?? 0;
    final advance = order['advance'];
    final advanceNum = advance is num ? advance.toDouble() : 0.0;
    final claimNum = claimAmount is num ? (claimAmount as num).toDouble() : null;

    final matches = claimNum != null && (claimNum - advanceNum).abs() < 0.01;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('$po • $itemCount item${itemCount == 1 ? '' : 's'} • Expected ₹${advanceNum.toInt()}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          // Amount match hint
          if (matches)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(20)),
              child: const Text('✓ matches', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF065F46))),
            )
          else if (claimNum != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(20)),
              child: Text('≠ ₹${claimNum.toInt()}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF92400E))),
            ),
          const Spacer(),
          // Verify & Accept button
          SizedBox(
            height: 34,
            child: FilledButton(
              onPressed: busy ? null : onVerify,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: busy
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Verify & Accept', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ]),
    );
  }
}

// ── Status chip ───────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg, fg;
    String label;
    switch (status) {
      case 'verified':
        bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46); label = 'Verified';
        break;
      case 'rejected':
        bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B); label = 'Rejected';
        break;
      default:
        bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E); label = 'To verify';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

// ── Screenshot thumbnail ─────────────────────────────────────────────────────

class _ScreenshotThumbnail extends StatefulWidget {
  final String filePath;
  const _ScreenshotThumbnail({required this.filePath});

  @override
  State<_ScreenshotThumbnail> createState() => _ScreenshotThumbnailState();
}

class _ScreenshotThumbnailState extends State<_ScreenshotThumbnail> {
  late final Future<String?> _urlFuture;

  @override
  void initState() {
    super.initState();
    _urlFuture = PaymentClaimsService.signedScreenshotUrl(widget.filePath);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _urlFuture,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
            width: 120, height: 120,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43))),
          );
        }
        final url = snap.data;
        if (url == null) {
          return Container(
            width: 120, height: 120,
            decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(8)),
            child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.broken_image_outlined, size: 28, color: Color(0xFF9CA3AF)),
              SizedBox(height: 4),
              Text('Image unavailable', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: Color(0xFF9CA3AF))),
            ]),
          );
        }
        return GestureDetector(
          onTap: () => _openFullscreen(ctx, url),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              url,
              width: 120, height: 120,
              fit: BoxFit.cover,
              errorBuilder: (_, e, __) => Container(
                width: 120, height: 120,
                decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(8)),
                child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.broken_image_outlined, size: 28, color: Color(0xFF9CA3AF)),
                  SizedBox(height: 4),
                  Text('Image unavailable', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: Color(0xFF9CA3AF))),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  void _openFullscreen(BuildContext context, String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(children: [
          InteractiveViewer(
            child: Image.network(url, fit: BoxFit.contain,
                errorBuilder: (_, e, __) => const Center(
                    child: Text('Image unavailable', style: TextStyle(color: Colors.white)))),
          ),
          Positioned(
            top: 12, right: 12,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ]),
      ),
    );
  }
}
