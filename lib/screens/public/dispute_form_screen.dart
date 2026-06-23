import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/render_log.dart';
import '../../widgets/dispute_card.dart';

// ── Palette ──────────────────────────────────────────────────────────────────
const _kGreen       = Color(0xFF1B7A43);
const _kBg          = Color(0xFFF4F6F8);
const _kCard        = Color(0xFFFFFFFF);
const _kBorder      = Color(0xFFE8EAED);
const _kDivider     = Color(0xFFF0F1F3);
const _kTextPrimary = Color(0xFF202124);
const _kTextMuted   = Color(0xFF5F6368);
const _kAmber       = Color(0xFFE8870E);
const _kAmberText   = Color(0xFF8A5A00);
const _kAmberBg     = Color(0xFFFFF7EC);
const _kAmberValue  = Color(0xFFC77700);
const _kGreenChipBg = Color(0xFFE7F4EC);
const _kNeutralChip = Color(0xFFF1F3F4);

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
      // E1/C174/B9: safe cast — never use `as String` on untrusted RPC payloads
      final loadErr = data['error']?.toString();
      if (loadErr != null) {
        setState(() { _error = loadErr; _loading = false; });
        return;
      }
      final rawItems = (data['items'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (rawItems.isEmpty) {
        setState(() { _error = 'invalid'; _loading = false; });
        return;
      }
      final shortCount = rawItems.where((i) => (i['kind']?.toString() ?? 'short') == 'short').length;
      final wrongCount = rawItems.where((i) => i['kind']?.toString() == 'wrong_item').length;
      setState(() {
        _supplierName = data['supplier_name']?.toString();
        _items = rawItems;
        _loading = false;
      });
      RenderLog.write('c170_dispute_form_items', '${rawItems.length}');
      RenderLog.write('c172_dispute_page_rendered',
          'supplier=${_supplierName ?? ''};item_count=${rawItems.length}');
      RenderLog.write('c172_qty_table_rendered', 'true');
      RenderLog.write('c172_redesign_done', 'true');
      RenderLog.write('c173_dispute_form_kinds', 'short_count=$shortCount;wrong_count=$wrongCount');
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
        final err = data['error']?.toString() ?? 'unknown'; // B9/C174: safe toString
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
          // Optimistic status flip: correct_coming→accepted_missing, out_of_stock→denied (backend contract)
          String newStatus;
          if (response == 'missing' || response == 'correct_coming') {
            newStatus = 'accepted_missing';
          } else {
            newStatus = 'denied';
          }
          _items[idx]['status'] = newStatus;
          _items[idx]['supplier_response'] = response;
        }
      });
      final resultStr = data['result']?.toString() ?? '';
      final kindStr = _items.firstWhere(
          (e) => e['dispute_id']?.toString() == disputeId,
          orElse: () => <String, dynamic>{})['kind']?.toString() ?? 'short';
      RenderLog.write('c170_dispute_submit', '$disputeId:$response');
      RenderLog.write('c172_item_responded', 'dispute_id=$disputeId;response=$response');
      RenderLog.write('c173_dispute_submit', 'dispute_id=$disputeId;kind=$kindStr;response=$response;result=$resultStr');
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting[disputeId] = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Submission failed. Please try again.')),
      );
      RenderLog.write('c170_dispute_submit_error', '$disputeId:exception');
    }
  }

  // E2/C174/B8: only show banner when every item has a real supplier response
  bool get _allResponded =>
      _items.isNotEmpty &&
      _items.every((item) {
        final status = item['status']?.toString() ?? '';
        return status == 'accepted_missing' || status == 'denied';
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: _loading
                ? const Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      CircularProgressIndicator(color: _kGreen, strokeWidth: 2.5),
                      SizedBox(height: 12),
                      Text('Loading…',
                          style: TextStyle(fontSize: 14, color: _kTextMuted)),
                    ]),
                  )
                : _error != null
                    ? _buildErrorState()
                    : _buildPage(),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFF1F3F4),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.link_off_rounded, size: 34, color: _kTextMuted),
          ),
          const SizedBox(height: 20),
          Text(
            _error == 'load_failed'
                ? 'Unable to load. Please try again.'
                : 'This link is no longer valid.',
            style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.w700, color: _kTextPrimary,
              height: 1.35,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Please contact mediBO.',
            style: TextStyle(fontSize: 14, color: _kTextMuted, height: 1.35),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          _footer(),
        ]),
      ),
    );
  }

  Widget _buildPage() {
    // C174/B8+B9 render-log instrumentation
    RenderLog.write('c174_form_load',
        'all_responded_predicate=accepted_missing||denied;error_cast=safe');
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 48),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _buildHeader(),
        const SizedBox(height: 16),
        const Text(
          'Delivery disputes — please confirm each item below',
          style: TextStyle(
            fontSize: 15, color: _kTextMuted, height: 1.35,
          ),
        ),
        const SizedBox(height: 8),

        // All-responded success banner
        if (_allResponded) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _kGreenChipBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFBBDDC8)),
            ),
            child: const Row(children: [
              Icon(Icons.check_circle_rounded, size: 18, color: _kGreen),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Thanks — all responses recorded.',
                  style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600,
                    color: _kGreen, height: 1.35,
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 8),
        ],

        for (int i = 0; i < _items.length; i++) ...[
          _buildItemCard(_items[i]),
          if (i < _items.length - 1) const SizedBox(height: 14),
        ],

        const SizedBox(height: 24),
        _footer(),
      ]),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _kGreen,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.local_shipping_outlined, color: Colors.white, size: 26),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'mediBO · Delivery Dispute',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.70),
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _supplierName ?? '',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _buildItemCard(Map<String, dynamic> item) {
    final disputeId   = item['dispute_id']?.toString() ?? '';
    final kind        = item['kind']?.toString() ?? 'short';
    final status      = item['status']?.toString() ?? '';
    final isSubmitting = _submitting[disputeId] == true;
    final submittedResp = _submitted[disputeId];
    final canRespond  =
        (status == 'reminder_sent' || status == 'shop_logged') &&
            submittedResp == null;

    RenderLog.write('c178_form_load',
        'dispute_id=$disputeId;kind=$kind;status=$status');

    return DisputeCard(
      dispute: item,
      isProcessing: isSubmitting,
      onRespondMissing: (canRespond && kind == 'short')
          ? () => _submit(disputeId, 'missing')
          : null,
      onRespondSupplied: (canRespond && kind == 'short')
          ? () => _submit(disputeId, 'denied')
          : null,
      onRespondCorrect: (canRespond && kind == 'wrong_item')
          ? () => _submit(disputeId, 'correct_coming')
          : null,
      onRespondOos: (canRespond && kind == 'wrong_item')
          ? () => _submit(disputeId, 'out_of_stock')
          : null,
    );
  }

  Widget _footer() => Center(
    child: Text(
      'mediBO · B2B Pharmacy Platform',
      style: const TextStyle(fontSize: 11, color: _kTextMuted),
    ),
  );
}
