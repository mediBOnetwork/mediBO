import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/render_log.dart';

const _kGreen      = Color(0xFF1B7A43);
const _kText       = Color(0xFF111827);
const _kSub        = Color(0xFF6B7280);
const _kBg         = Color(0xFFF5F6F8);
const _kCard       = Color(0xFFFFFFFF);
const _kBorder     = Color(0xFFE5E7EB);
const _kDeniedFg   = Color(0xFFC2410C);

class DisputeFormScreen extends StatefulWidget {
  final String token;
  const DisputeFormScreen({super.key, required this.token});

  @override
  State<DisputeFormScreen> createState() => _DisputeFormScreenState();
}

class _DisputeFormScreenState extends State<DisputeFormScreen> {
  bool _loading = true;
  String? _error;
  String? _supplierName;
  List<Map<String, dynamic>> _items = [];
  final Map<String, bool> _submitting = {};
  final Map<String, String> _submitted = {};

  @override
  void initState() {
    super.initState();
    RenderLog.write('c170_dispute_route', 'true');
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final result = await Supabase.instance.client
          .rpc('get_dispute_form', params: {'p_token': widget.token});
      if (!mounted) return;
      final data = Map<String, dynamic>.from(result as Map);
      if (data['error'] != null) {
        setState(() { _error = data['error'] as String; _loading = false; });
        return;
      }
      final rawItems = (data['items'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (rawItems.isEmpty) {
        setState(() { _error = 'invalid'; _loading = false; });
        return;
      }
      setState(() {
        _supplierName = data['supplier_name']?.toString();
        _items = rawItems;
        _loading = false;
      });
      RenderLog.write('c170_dispute_form_items', '${rawItems.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'load_failed'; _loading = false; });
    }
  }

  Future<void> _submit(String disputeId, String response) async {
    if (_submitting[disputeId] == true) return;
    setState(() => _submitting[disputeId] = true);
    try {
      final result = await Supabase.instance.client.rpc(
        'submit_dispute_response',
        params: {
          'p_token': widget.token,
          'p_dispute_id': disputeId,
          'p_response': response,
        },
      );
      if (!mounted) return;
      final data = result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
      if (data['error'] != null) {
        final err = data['error'] as String;
        setState(() => _submitting[disputeId] = false);
        if (err == 'already_responded') {
          await _load();
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)),
        );
        RenderLog.write('c170_dispute_submit_error', '$disputeId:$err');
        return;
      }
      setState(() {
        _submitted[disputeId] = response;
        _submitting[disputeId] = false;
        final idx = _items.indexWhere((e) => e['dispute_id']?.toString() == disputeId);
        if (idx >= 0) {
          _items[idx]['status'] = response == 'missing' ? 'accepted_missing' : 'denied';
          _items[idx]['supplier_response'] = response;
        }
      });
      RenderLog.write('c170_dispute_submit', '$disputeId:$response');
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting[disputeId] = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Submission failed. Please try again.')),
      );
      RenderLog.write('c170_dispute_submit_error', '$disputeId:exception');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2.5))
                : _error != null
                    ? _buildError()
                    : _buildPage(),
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(20)),
            child: const Icon(Icons.link_off_outlined, size: 36, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 20),
          Text(
            _error == 'load_failed'
                ? 'Unable to load. Please try again.'
                : 'This link is no longer valid.',
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF374151)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text('Please contact mediBO for assistance.',
              style: TextStyle(fontSize: 14, color: _kSub), textAlign: TextAlign.center),
          const SizedBox(height: 32),
          _mediboFooter(),
        ]),
      ),
    );
  }

  Widget _buildPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 48),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Brand header ──
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: _kGreen, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.local_shipping_outlined, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('mediBO · Delivery Dispute',
                    style: TextStyle(color: Colors.white, fontSize: 11,
                        fontWeight: FontWeight.w500, letterSpacing: 0.5)),
                const SizedBox(height: 3),
                Text(_supplierName ?? '',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        const Text(
          'Items reported short — please confirm each',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: _kSub),
        ),
        const SizedBox(height: 16),

        for (final item in _items) ...[
          _buildItemCard(item),
          const SizedBox(height: 12),
        ],

        const SizedBox(height: 8),
        _mediboFooter(),
      ]),
    );
  }

  Widget _buildItemCard(Map<String, dynamic> item) {
    final disputeId    = item['dispute_id']?.toString() ?? '';
    final productName  = item['product_name']?.toString() ?? '—';
    final imageUrl     = item['image_url']?.toString();
    final ordered      = (item['ordered'] as num?)?.toInt() ?? 0;
    final received     = (item['received'] as num?)?.toInt() ?? 0;
    final short        = (item['short'] as num?)?.toInt() ?? 0;
    final status       = item['status']?.toString() ?? '';
    final isSubmitting = _submitting[disputeId] == true;
    final submittedResponse = _submitted[disputeId];
    final canRespond   = status == 'reminder_sent' && submittedResponse == null;

    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (imageUrl != null && imageUrl.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(imageUrl, width: 56, height: 56, fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => _placeholderImage()),
              )
            else
              _placeholderImage(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(productName,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
                const SizedBox(height: 8),
                _labelRow('Ordered', '$ordered'),
                const SizedBox(height: 3),
                _labelRow('Received', '$received'),
                const SizedBox(height: 3),
                _labelRow('Short', '$short',
                    valueStyle: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: _kDeniedFg)),
              ]),
            ),
          ]),

          if (canRespond) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFCD34D)),
              ),
              child: const Row(children: [
                Icon(Icons.help_outline_rounded, size: 16, color: Color(0xFFD97706)),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Did the missing quantity actually go undelivered?',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: Color(0xFF92400E))),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity, height: 44,
              child: FilledButton.icon(
                onPressed: isSubmitting ? null : () => _submit(disputeId, 'missing'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD97706),
                  disabledBackgroundColor: const Color(0xFFFDE68A),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: isSubmitting
                    ? const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.check_rounded, size: 16, color: Colors.white),
                label: const Text('Yes, it was short / missing',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity, height: 44,
              child: OutlinedButton.icon(
                onPressed: isSubmitting ? null : () => _submit(disputeId, 'denied'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kText,
                  side: const BorderSide(color: _kBorder, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.close_rounded, size: 16),
                label: const Text('No, I supplied it',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: const Text('Your response is recorded and shared with mediBO.',
                  style: TextStyle(fontSize: 12, color: _kSub)),
            ),
          ] else if (submittedResponse != null) ...[
            const SizedBox(height: 12),
            _responseChip(submittedResponse),
            const SizedBox(height: 4),
            Text(
              submittedResponse == 'missing'
                  ? "Thanks — we'll arrange the missing stock."
                  : 'Recorded. Our team will review with proof.',
              style: const TextStyle(fontSize: 12, color: _kSub),
            ),
          ] else if (status == 'accepted_missing') ...[
            const SizedBox(height: 12),
            _responseChip('missing'),
          ] else if (status == 'denied') ...[
            const SizedBox(height: 12),
            _responseChip('denied'),
          ] else if (status.isNotEmpty && status != 'reminder_sent') ...[
            const SizedBox(height: 12),
            _statusBadge(status),
          ],
        ]),
      ),
    );
  }

  Widget _responseChip(String response) {
    final isMissing = response == 'missing';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isMissing ? const Color(0xFFECFDF5) : const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isMissing ? 'Accepted — short/missing' : 'Denied — supplied correctly',
        style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w600,
          color: isMissing ? _kGreen : const Color(0xFFC2410C),
        ),
      ),
    );
  }

  Widget _statusBadge(String status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(6)),
      child: Text(status.replaceAll('_', ' '),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: _kSub)),
    );
  }

  Widget _placeholderImage() => Container(
    width: 56, height: 56,
    decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(8)),
    child: const Icon(Icons.medication_outlined, size: 26, color: Color(0xFF9CA3AF)),
  );

  Widget _labelRow(String label, String value, {TextStyle? valueStyle}) {
    return Row(children: [
      SizedBox(width: 68,
          child: Text(label, style: const TextStyle(fontSize: 13, color: _kSub))),
      Text(value,
          style: valueStyle ??
              const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kText)),
    ]);
  }

  Widget _mediboFooter() => Center(
    child: Text('mediBO · Powered by mediBO B2B Pharmacy',
        style: const TextStyle(fontSize: 11, color: _kSub)),
  );
}
