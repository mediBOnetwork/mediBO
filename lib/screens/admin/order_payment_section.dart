// CHANGE #212 — per-order expandable payment section inside Customer Order card
import 'package:flutter/material.dart';
import '../../services/payment_claims_service.dart';
import '../../utils/render_log.dart';

class OrderPaymentSection extends StatefulWidget {
  final String orderId;
  final String? orderStatus;

  const OrderPaymentSection({
    super.key,
    required this.orderId,
    this.orderStatus,
  });

  @override
  State<OrderPaymentSection> createState() => _OrderPaymentSectionState();
}

class _OrderPaymentSectionState extends State<OrderPaymentSection> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  // Action state
  String? _actingOnClaim; // claimId currently being actioned
  String? _rejectReason;
  final _rejectCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _rejectCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await PaymentClaimsService.orderPayment(widget.orderId);
      if (!mounted) return;
      final shortId = widget.orderId.length >= 8 ? widget.orderId.substring(0, 8) : widget.orderId;
      final claims = data['claims'] as List? ?? [];
      RenderLog.write('c212_payment_loaded_$shortId', 1);
      RenderLog.write('c212_claims_${claims.length}', 1);
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _verify(String claimId) async {
    setState(() => _actingOnClaim = claimId);
    try {
      await PaymentClaimsService.verifyAndAccept(claimId, widget.orderId);
      RenderLog.write('c212_claim_verified', 1);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Verify failed: $e'), backgroundColor: const Color(0xFFDC2626)),
      );
    } finally {
      if (mounted) setState(() => _actingOnClaim = null);
    }
  }

  Future<void> _reject(String claimId) async {
    final reason = _rejectCtrl.text.trim();
    if (reason.isEmpty) return;
    setState(() => _actingOnClaim = claimId);
    try {
      await PaymentClaimsService.rejectClaim(claimId, reason, orderId: widget.orderId);
      RenderLog.write('c267_reject_with_order', 'claim_id=$claimId,order_id=${widget.orderId}');
      RenderLog.write('c212_claim_rejected', 1);
      _rejectCtrl.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reject failed: $e'), backgroundColor: const Color(0xFFDC2626)),
      );
    } finally {
      if (mounted) setState(() => _actingOnClaim = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c212_card_payment_built', 1);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Payment', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else if (_error != null)
            Text('Error loading payment: $_error', style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626)))
          else
            _buildContent(),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final data = _data!;
    final advanceExpected = data['advance_expected_pct'] as num?;
    final orderTotal = data['order_total'] as num?;
    final claims = List<Map<String, dynamic>>.from(data['claims'] as List? ?? []);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (advanceExpected != null && orderTotal != null) ...[
          _infoRow('Advance required', '${advanceExpected.toStringAsFixed(0)}% of ₹${orderTotal.toStringAsFixed(2)}'),
          const SizedBox(height: 4),
        ],
        if (claims.isEmpty)
          const Text('No payment claim submitted yet.', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)))
        else
          ...claims.map((c) => _buildClaimCard(c)),
      ],
    );
  }

  Widget _buildClaimCard(Map<String, dynamic> claim) {
    final claimId = claim['id'] as String? ?? '';
    final status = claim['status'] as String? ?? '';
    final ocrAmt = claim['ocr_amount'] as num?;
    final claimedAmt = claim['claimed_amount'] as num?;
    final utr = claim['utr'] as String?;
    final screenshotPath = claim['screenshot_path'] as String?;
    final appAmt = claim['app_amount'] as num?;
    final amountMatch = claim['amount_match'] as bool?;
    final isActing = _actingOnClaim == claimId;

    final statusColor = _statusColor(status);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.$1,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(status.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: statusColor.$2)),
              ),
              const Spacer(),
              if (claimId.length >= 8)
                Text('#${claimId.substring(0, 8)}', style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
            ],
          ),
          const SizedBox(height: 8),
          if (ocrAmt != null) _infoRow('OCR amount', '₹${ocrAmt.toStringAsFixed(2)}'),
          if (claimedAmt != null) _infoRow('Claimed', '₹${claimedAmt.toStringAsFixed(2)}'),
          if (appAmt != null)
            _infoRow(
              'App expected',
              '₹${appAmt.toStringAsFixed(2)}${amountMatch == true ? '  ✓ match' : amountMatch == false ? '  ✗ mismatch' : ''}',
              valueColor: amountMatch == true ? const Color(0xFF065F46) : amountMatch == false ? const Color(0xFF991B1B) : null,
            ),
          if (utr != null && utr.isNotEmpty) _infoRow('UTR', utr),
          if (screenshotPath != null && screenshotPath.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SignedScreenshot(filePath: screenshotPath),
          ],
          if (status == 'claimed') ...[
            const SizedBox(height: 12),
            if (isActing)
              const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
            else ...[
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _verify(claimId),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1B7A43),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: const Text('Verify & Accept', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _rejectCtrl,
                decoration: InputDecoration(
                  hintText: 'Rejection reason (required)',
                  hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                ),
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => _reject(claimId),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFDC2626),
                    side: const BorderSide(color: Color(0xFFDC2626)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('Reject', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ] else if (status == 'verified')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(20)),
                child: const Text('Paid • Verified', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF065F46))),
              ),
            ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          Flexible(child: Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: valueColor ?? const Color(0xFF111827)))),
        ],
      ),
    );
  }

  (Color, Color) _statusColor(String status) {
    return switch (status) {
      'claimed'   => (const Color(0xFFFEF3C7), const Color(0xFF92400E)),
      'verified'  => (const Color(0xFFD1FAE5), const Color(0xFF065F46)),
      'rejected'  => (const Color(0xFFFEE2E2), const Color(0xFF991B1B)),
      'duplicate' => (const Color(0xFFEFF6FF), const Color(0xFF1E40AF)),
      _           => (const Color(0xFFF3F4F6), const Color(0xFF374151)),
    };
  }
}

class _SignedScreenshot extends StatefulWidget {
  final String filePath;
  const _SignedScreenshot({required this.filePath});

  @override
  State<_SignedScreenshot> createState() => _SignedScreenshotState();
}

class _SignedScreenshotState extends State<_SignedScreenshot> {
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
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox(width: 80, height: 60,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final url = snap.data;
        if (url == null) return const SizedBox.shrink();
        RenderLog.write('c225_signed_url_fix', 1);
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.network(
            url,
            width: 120, height: 90, fit: BoxFit.cover,
            errorBuilder: (_, e, __) => const SizedBox(width: 80, height: 60,
                child: Icon(Icons.broken_image_outlined, color: Color(0xFF9CA3AF))),
          ),
        );
      },
    );
  }
}
