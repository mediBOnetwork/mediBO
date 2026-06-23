import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';
import '../../widgets/dispute_card.dart';

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
    final disputeId   = d['dispute_id']?.toString() ?? '';
    final kind        = d['kind']?.toString() ?? 'short';
    final status      = d['status']?.toString() ?? '';
    final isResponding = _responding.contains(disputeId);
    // Portal: supplier can only respond when reminder has been explicitly sent
    final canRespond  = status == 'reminder_sent' || status == 'shop_logged';

    RenderLog.write('c178_supplier_respond',
        'dispute_id=$disputeId;kind=$kind;status=$status;rendering=true');

    return DisputeCard(
      dispute: d,
      isProcessing: isResponding,
      onRespondMissing: (canRespond && kind == 'short')
          ? () => _respond(disputeId, kind, 'missing')
          : null,
      onRespondSupplied: (canRespond && kind == 'short')
          ? () => _respond(disputeId, kind, 'denied')
          : null,
      onRespondCorrect: (canRespond && kind == 'wrong_item')
          ? () => _respond(disputeId, kind, 'correct_coming')
          : null,
      onRespondOos: (canRespond && kind == 'wrong_item')
          ? () => _respond(disputeId, kind, 'out_of_stock')
          : null,
    );
  }
}
