import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';

const _kGreen  = Color(0xFF1B7A43);
const _kText   = Color(0xFF111827);
const _kSub    = Color(0xFF6B7280);
const _kBorder = Color(0xFFE5E7EB);
const _kCard   = Colors.white;

class SupplierDisputesScreen extends StatefulWidget {
  final String? viewAsSupplierId;
  const SupplierDisputesScreen({super.key, this.viewAsSupplierId});

  @override
  State<SupplierDisputesScreen> createState() => _SupplierDisputesScreenState();
}

class _SupplierDisputesScreenState extends State<SupplierDisputesScreen> {
  bool _loading = true;
  String? _error; // C174/B14: real error state shown with retry
  List<Map<String, dynamic>> _disputes = [];
  final Set<String> _responding = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; }); // C174/B14: clear error on each load
    try {
      final sid = widget.viewAsSupplierId;
      final params = sid != null ? <String, dynamic>{'p_supplier_id': sid} : <String, dynamic>{};
      final res = await Supabase.instance.client
          .rpc('supplier_my_disputes', params: params) as Map;
      if (!mounted) return;
      final raw = (res['disputes'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      RenderLog.write('c135_supplier_dispute_view', 'true');
      setState(() { _disputes = raw; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      // C174/B14: surface real error state so user can distinguish from empty list
      final msg = e.toString().substring(0, e.toString().length.clamp(0, 120));
      setState(() { _loading = false; _error = msg; });
      RenderLog.write('c174_portal_error', 'code=$msg');
    }
  }

  Future<void> _respond(String disputeId, String response) async {
    if (_responding.contains(disputeId)) return;
    setState(() => _responding.add(disputeId));
    try {
      final res = await Supabase.instance.client.rpc('supplier_respond_dispute',
          params: {'p_dispute_id': disputeId, 'p_response': response});
      if (!mounted) return;
      final data = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      final errCode = data['error']?.toString();
      if (errCode != null) {
        // C174/B12: structured error codes
        if (errCode == 'already_responded') {
          await _load(); // silent reload — row was stale
        } else if (errCode == 'bad_response') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("That option isn't valid for this dispute")),
          );
        } else {
          // not_your_dispute | invalid | unknown
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('This dispute is no longer available')),
          );
          await _load();
        }
        // C174/B7: remove responding flag after _load completes (or after error)
        if (mounted) setState(() => _responding.remove(disputeId));
        RenderLog.write('c174_portal_respond',
            'responding_cleared_after_load=true;error_code_parsed=true');
        return;
      }
      // Success path: C174/B7 — reload first, THEN clear responding flag
      await _load();
      if (!mounted) return;
      setState(() => _responding.remove(disputeId)); // B7: after _load, not before
      RenderLog.write('c174_portal_respond',
          'responding_cleared_after_load=true;error_code_parsed=true');
    } catch (e) {
      if (!mounted) return;
      setState(() => _responding.remove(disputeId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().substring(0, e.toString().length.clamp(0, 80)))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c174_portal_load', 'has_error_state=${_error != null}');
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
    // C174/B14: show real error state — never show "No reminders" when a load failed
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off_rounded, size: 48, color: _kSub),
            const SizedBox(height: 12),
            const Text('Unable to load disputes.',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kSub)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _load,
              style: FilledButton.styleFrom(backgroundColor: _kGreen,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Retry'),
            ),
          ]),
        ),
      );
    }
    if (_disputes.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle_outline_rounded, size: 48, color: _kGreen),
          const SizedBox(height: 12),
          const Text('No reminders or disputes.',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kSub)),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Refresh'),
          ),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: _kGreen,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        itemCount: _disputes.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _buildCard(_disputes[i]),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> d) {
    final disputeId  = d['dispute_id']?.toString() ?? '';
    final product    = d['product_name']?.toString() ?? '—';
    final imageUrl   = d['image_url']?.toString();
    final ordered    = (d['ordered'] as num?)?.toInt() ?? 0;
    final received   = (d['received'] as num?)?.toInt() ?? 0;
    final short      = (d['short'] as num?)?.toInt() ?? 0;
    final status     = d['status']?.toString() ?? '';
    final response   = d['response']?.toString();
    final isResponding = _responding.contains(disputeId);
    final canRespond = status == 'reminder_sent';

    Color statusBg, statusFg;
    String statusLabel;
    switch (status) {
      case 'reminder_sent':
        statusBg = const Color(0xFFFEF3C7); statusFg = const Color(0xFF92400E);
        statusLabel = 'Awaiting your response';
      case 'accepted_missing':
        statusBg = const Color(0xFFD1FAE5); statusFg = const Color(0xFF065F46);
        statusLabel = 'You accepted (stock coming)';
      case 'denied':
        statusBg = const Color(0xFFFEE2E2); statusFg = const Color(0xFF991B1B);
        statusLabel = 'You denied';
      case 'resolved':
        statusBg = const Color(0xFFEFF6FF); statusFg = const Color(0xFF1E40AF);
        statusLabel = 'Resolved';
      default:
        statusBg = const Color(0xFFF3F4F6); statusFg = _kSub;
        statusLabel = status;
    }

    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Product row ──────────────────────────────────────────────────────
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (imageUrl != null && imageUrl.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(imageUrl, width: 44, height: 44, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _placeholderBox()),
              )
            else
              _placeholderBox(),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(product,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text('Ordered $ordered · Received $received · Missing $short',
                    style: const TextStyle(fontSize: 12, color: _kSub)),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: statusBg, borderRadius: BorderRadius.circular(20)),
              child: Text(statusLabel,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: statusFg)),
            ),
          ]),

          // ── Responded outcome (non-reminder) ────────────────────────────────
          if (!canRespond && response != null && response.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: _kBorder),
            const SizedBox(height: 8),
            Text(
              response == 'missing'
                  ? 'Your response: The quantity was indeed missing — stock will be sent.'
                  : 'Your response: You delivered the correct quantity.',
              style: const TextStyle(fontSize: 12, color: _kSub),
            ),
          ],

          // ── Response buttons (reminder_sent only) ───────────────────────────
          if (canRespond) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: _kBorder),
            const SizedBox(height: 10),
            Text(
              'mediBO has flagged $short item${short == 1 ? '' : 's'} missing from your delivery. '
              'Please physically verify in your records, then respond:',
              style: const TextStyle(fontSize: 13, color: _kText),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: isResponding ? null : () => _respond(disputeId, 'missing'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD97706),
                  disabledBackgroundColor: const Color(0xFFFDE68A),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: isResponding
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Yes — the quantity is missing (our error)',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: isResponding ? null : () => _respond(disputeId, 'denied'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kText,
                  side: const BorderSide(color: _kBorder),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('No — we delivered the correct quantity',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _placeholderBox() => Container(
    width: 44, height: 44,
    decoration: BoxDecoration(
      color: const Color(0xFFF3F4F6),
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Icon(Icons.medication_outlined, size: 22, color: Color(0xFFD1D5DB)),
  );
}
