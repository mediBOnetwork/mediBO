import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';

const _kGreen  = Color(0xFF1B7A43);
const _kText   = Color(0xFF111827);
const _kSub    = Color(0xFF6B7280);
const _kBorder = Color(0xFFE5E7EB);
const _kCard   = Colors.white;

class SupplierDisputesScreen extends StatefulWidget {
  // null  → real supplier login (RPC resolves by identity)
  // set   → admin acting as this supplier (passed as p_acting_supplier)
  final String? viewAsSupplierName;

  // kept for compatibility — no longer used in RPC calls
  final String? viewAsSupplierId;

  const SupplierDisputesScreen({
    super.key,
    this.viewAsSupplierId,
    this.viewAsSupplierName,
  });

  @override
  State<SupplierDisputesScreen> createState() => _SupplierDisputesScreenState();
}

class _SupplierDisputesScreenState extends State<SupplierDisputesScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _disputes = [];
  final Set<String> _responding = {};

  // null → real supplier; non-null → admin acting as this supplier
  String? get _actingSupplier => widget.viewAsSupplierName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SupplierDisputesScreen old) {
    super.didUpdateWidget(old);
    if (old.viewAsSupplierName != widget.viewAsSupplierName) _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final params = <String, dynamic>{};
      if (_actingSupplier != null) params['p_acting_supplier'] = _actingSupplier;
      final res = await Supabase.instance.client
          .rpc('supplier_my_disputes', params: params) as Map;
      if (!mounted) return;
      final loadErr = res['error']?.toString();
      if (loadErr != null) {
        setState(() { _loading = false; _error = loadErr; });
        RenderLog.write('c175_portal_error', 'code=$loadErr');
        return;
      }
      final raw = (res['disputes'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final shortCount = raw.where((d) => d['kind']?.toString() == 'short').length;
      final wrongCount = raw.where((d) => d['kind']?.toString() == 'wrong_item').length;
      RenderLog.write('c175_portal_load',
          'acting=${_actingSupplier != null};count=${raw.length}');
      RenderLog.write('c175_card_kinds', 'short=$shortCount;wrong=$wrongCount');
      setState(() { _disputes = raw; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().substring(0, e.toString().length.clamp(0, 120));
      setState(() { _loading = false; _error = msg; });
      RenderLog.write('c175_portal_error', 'code=$msg');
    }
  }

  Future<void> _respond(String disputeId, String kind, String response) async {
    if (_responding.contains(disputeId)) return;
    setState(() => _responding.add(disputeId));
    try {
      final params = <String, dynamic>{
        'p_dispute_id': disputeId,
        'p_response': response,
      };
      if (_actingSupplier != null) params['p_acting_supplier'] = _actingSupplier;
      final res = await Supabase.instance.client
          .rpc('supplier_respond_dispute', params: params);
      if (!mounted) return;
      final data = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      final errCode = data['error']?.toString();
      if (errCode != null) {
        String? msg;
        if (errCode == 'already_responded') {
          // silent reload — row was stale
        } else if (errCode == 'bad_response') {
          msg = "That option isn't valid for this dispute";
        } else if (errCode == 'no_supplier') {
          msg = 'Session expired — please sign in again';
        } else {
          // not_your_dispute | invalid | unknown
          msg = 'This dispute is no longer available';
        }
        await _load();
        if (!mounted) return;
        if (msg != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        }
        setState(() => _responding.remove(disputeId));
        RenderLog.write('c175_portal_respond',
            'dispute_id=$disputeId;kind=$kind;response=$response;result=error:$errCode');
        return;
      }
      // Success: reload then clear flag
      await _load();
      if (!mounted) return;
      setState(() => _responding.remove(disputeId));
      RenderLog.write('c175_portal_respond',
          'dispute_id=$disputeId;kind=$kind;response=$response;result=ok');
    } catch (e) {
      if (!mounted) return;
      setState(() => _responding.remove(disputeId));
      final msg = e.toString().substring(0, e.toString().length.clamp(0, 80));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
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
              style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
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
    final kind = d['kind']?.toString() ?? 'short';
    if (kind == 'wrong_item') return _buildWrongItemCard(d);
    return _buildShortCard(d);
  }

  // ── SHORT card ─────────────────────────────────────────────────────────────

  Widget _buildShortCard(Map<String, dynamic> d) {
    final disputeId   = d['dispute_id']?.toString() ?? '';
    final product     = d['product_name']?.toString() ?? '—';
    final imageUrl    = d['image_url']?.toString();
    final ordered     = (d['ordered'] as num?)?.toInt() ?? 0;
    final received    = (d['received'] as num?)?.toInt() ?? 0;
    final short       = (d['short'] as num?)?.toInt() ?? 0;
    final status      = d['status']?.toString() ?? '';
    final response    = d['response']?.toString();
    final isResponding = _responding.contains(disputeId);
    final canRespond  = status == 'reminder_sent';

    return _cardShell(
      imageUrl: imageUrl,
      product: product,
      kindChip: _chip('Short', const Color(0xFFFEF3C7), const Color(0xFF92400E)),
      statusChip: _statusChipForStatus(status),
      body: Text('Ordered $ordered · Received $received · Short $short',
          style: const TextStyle(fontSize: 13, color: _kSub)),
      actionArea: canRespond
          ? _shortButtons(disputeId, short, isResponding)
          : _readOnlyChip(_shortOutcomeLabel(status, response)),
    );
  }

  Widget _shortButtons(String disputeId, int short, bool isResponding) {
    return Column(children: [
      const SizedBox(height: 12),
      const Divider(height: 1, color: _kBorder),
      const SizedBox(height: 10),
      Text(
        'mediBO has flagged $short item${short == 1 ? '' : 's'} missing from your delivery. '
        'Please verify and respond:',
        style: const TextStyle(fontSize: 13, color: _kText),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: isResponding ? null
              : () => _respond(disputeId, 'short', 'missing'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFD97706),
            disabledBackgroundColor: const Color(0xFFFDE68A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: isResponding
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('Yes, it was short / missing',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: isResponding ? null
              : () => _respond(disputeId, 'short', 'denied'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _kText,
            side: const BorderSide(color: _kBorder),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: const Text("No, I supplied it",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ),
    ]);
  }

  String _shortOutcomeLabel(String status, String? response) {
    if (status == 'accepted_missing') return 'Confirmed missing';
    if (status == 'denied') return 'Reported as supplied';
    if (status == 'resolved') return 'Resolved';
    return status;
  }

  // ── WRONG-ITEM card ────────────────────────────────────────────────────────

  Widget _buildWrongItemCard(Map<String, dynamic> d) {
    final disputeId    = d['dispute_id']?.toString() ?? '';
    final product      = d['product_name']?.toString() ?? '—';
    final imageUrl     = d['image_url']?.toString();
    final wrongProduct = d['wrong_product_name']?.toString() ?? 'a different item';
    final status       = d['status']?.toString() ?? '';
    final response     = d['response']?.toString();
    final isResponding = _responding.contains(disputeId);
    final canRespond   = status == 'reminder_sent';

    return _cardShell(
      imageUrl: imageUrl,
      product: product,
      kindChip: _chip('Wrong item', const Color(0xFFEDE9FE), const Color(0xFF5B21B6)),
      statusChip: _statusChipForStatus(status),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _miniRow('Ordered:', product),
        const SizedBox(height: 4),
        _miniRow('They sent:', wrongProduct),
      ]),
      actionArea: canRespond
          ? _wrongItemButtons(disputeId, isResponding)
          : _readOnlyChip(_wrongItemOutcomeLabel(status, response)),
    );
  }

  Widget _wrongItemButtons(String disputeId, bool isResponding) {
    return Column(children: [
      const SizedBox(height: 12),
      const Divider(height: 1, color: _kBorder),
      const SizedBox(height: 10),
      const Text(
        'mediBO has flagged a wrong item in this delivery. Please respond:',
        style: TextStyle(fontSize: 13, color: _kText),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: isResponding ? null
              : () => _respond(disputeId, 'wrong_item', 'correct_coming'),
          style: FilledButton.styleFrom(
            backgroundColor: _kGreen,
            disabledBackgroundColor: const Color(0xFFD1FAE5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: isResponding
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('Yes, sending the correct item',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: isResponding ? null
              : () => _respond(disputeId, 'wrong_item', 'out_of_stock'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _kText,
            side: const BorderSide(color: _kBorder),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: const Text('Out of stock',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ),
    ]);
  }

  String _wrongItemOutcomeLabel(String status, String? response) {
    // drive off `response` for wrong_item (backend maps correct_coming→accepted_missing)
    if (response == 'correct_coming') return 'Sending correct item';
    if (response == 'out_of_stock') return 'Out of stock — re-sourcing';
    if (status == 'resolved') return 'Resolved';
    if (status == 'accepted_missing') return 'Sending correct item';
    if (status == 'denied') return 'Out of stock — re-sourcing';
    return status;
  }

  // ── Shared helpers ─────────────────────────────────────────────────────────

  Widget _cardShell({
    required String? imageUrl,
    required String product,
    required Widget kindChip,
    required Widget statusChip,
    required Widget body,
    required Widget actionArea,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Product row ────────────────────────────────────────────────────
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
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700, color: _kText),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [kindChip, statusChip]),
              ]),
            ),
          ]),
          const SizedBox(height: 10),
          body,
          actionArea,
        ]),
      ),
    );
  }

  Widget _chip(String label, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
    child: Text(label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
  );

  Widget _statusChipForStatus(String status) {
    Color bg; Color fg; String label;
    switch (status) {
      case 'reminder_sent':
        bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E);
        label = 'Awaiting your response';
      case 'accepted_missing':
        bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46);
        label = 'Accepted';
      case 'denied':
        bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B);
        label = 'Denied';
      case 'resolved':
        bg = const Color(0xFFEFF6FF); fg = const Color(0xFF1E40AF);
        label = 'Resolved';
      default:
        bg = const Color(0xFFF3F4F6); fg = _kSub;
        label = status;
    }
    return _chip(label, bg, fg);
  }

  Widget _readOnlyChip(String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kSub)),
      ),
    );
  }

  Widget _miniRow(String label, String value) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 80,
        child: Text(label,
            style: const TextStyle(fontSize: 12, color: _kSub, fontWeight: FontWeight.w500)),
      ),
      Expanded(
        child: Text(value,
            style: const TextStyle(fontSize: 12, color: _kText, fontWeight: FontWeight.w600),
            maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    ],
  );

  Widget _placeholderBox() => Container(
    width: 44, height: 44,
    decoration: BoxDecoration(
      color: const Color(0xFFF3F4F6),
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Icon(Icons.medication_outlined, size: 22, color: Color(0xFFD1D5DB)),
  );
}
