import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/render_log.dart';

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
    final disputeId      = item['dispute_id']?.toString() ?? '';
    final kind           = item['kind']?.toString() ?? 'short';
    final isWrongItem    = kind == 'wrong_item';
    final productName    = item['product_name']?.toString() ?? '—';
    final wrongProductName = item['wrong_product_name']?.toString();
    final imageUrl       = item['image_url']?.toString();
    final ordered        = (item['ordered'] as num?)?.toInt() ?? 0;
    final received       = (item['received'] as num?)?.toInt() ?? 0;
    final short          = (item['short'] as num?)?.toInt() ?? 0;
    final status         = item['status']?.toString() ?? '';
    final supplierResponse = item['supplier_response']?.toString();
    final isSubmitting   = _submitting[disputeId] == true;
    final submittedResp  = _submitted[disputeId];
    final canRespond     = (status == 'reminder_sent' || status == 'shop_logged') && submittedResp == null;
    final isResponded    = submittedResp != null ||
        status == 'accepted_missing' || status == 'denied';

    // For wrong_item drive chip text off supplier_response; for short drive off status
    final respondedLabel = isWrongItem
        ? (submittedResp ?? supplierResponse)
        : (submittedResp ?? (status == 'accepted_missing' ? 'missing' : status == 'denied' ? 'denied' : null));

    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F101828),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: isWrongItem
            ? _buildWrongItemCardBody(
                disputeId: disputeId,
                productName: productName,
                wrongProductName: wrongProductName,
                imageUrl: imageUrl,
                isSubmitting: isSubmitting,
                canRespond: canRespond,
                isResponded: isResponded,
                respondedLabel: respondedLabel,
              )
            : _buildShortCardBody(
                disputeId: disputeId,
                productName: productName,
                imageUrl: imageUrl,
                ordered: ordered,
                received: received,
                short: short,
                isSubmitting: isSubmitting,
                canRespond: canRespond,
                isResponded: isResponded,
                respondedLabel: respondedLabel,
              ),
      ),
    );
  }

  Widget _buildShortCardBody({
    required String disputeId,
    required String productName,
    required String? imageUrl,
    required int ordered,
    required int received,
    required int short,
    required bool isSubmitting,
    required bool canRespond,
    required bool isResponded,
    required String? respondedLabel,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _productThumb(imageUrl),
        const SizedBox(width: 14),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(productName,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kTextPrimary, height: 1.35),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ),
      ]),
      const SizedBox(height: 14),
      _buildQtyTable(ordered, received, short),
      if (isResponded && respondedLabel != null) ...[
        const SizedBox(height: 14),
        _buildRespondedChip(respondedLabel, isWrongItem: false),
      ] else if (canRespond) ...[
        const SizedBox(height: 14),
        _buildPromptNote(),
        const SizedBox(height: 12),
        _buildShortActionButtons(disputeId, isSubmitting),
      ] else if (!isResponded && disputeId.isNotEmpty) ...[
        const SizedBox(height: 12),
        _buildStatusChip(disputeId.isNotEmpty ? 'Pending supplier notification' : ''),
      ],
    ]);
  }

  Widget _buildWrongItemCardBody({
    required String disputeId,
    required String productName,
    required String? wrongProductName,
    required String? imageUrl,
    required bool isSubmitting,
    required bool canRespond,
    required bool isResponded,
    required String? respondedLabel,
  }) {
    final sentText = (wrongProductName != null && wrongProductName.isNotEmpty)
        ? wrongProductName
        : 'a different / unexpected item';
    RenderLog.write('c173_wrong_card_rendered', 'true');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _productThumb(imageUrl),
        const SizedBox(width: 14),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(productName,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kTextPrimary, height: 1.35),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ),
      ]),
      const SizedBox(height: 14),
      // ── Wrong-item mini-table ──
      Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFB),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(children: [
              Expanded(child: Text('Ordered', style: const TextStyle(fontSize: 14, color: _kTextMuted, height: 1.3))),
              Expanded(child: Text(productName,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kTextPrimary, height: 1.3),
                  maxLines: 2, overflow: TextOverflow.ellipsis)),
            ]),
          ),
          const Divider(height: 1, thickness: 1, color: Color(0xFFF0F1F3), indent: 12, endIndent: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Row(children: [
              const Expanded(child: Text('They sent',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFFC77700), height: 1.3))),
              Expanded(child: Text(sentText,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFC77700), height: 1.3),
                  maxLines: 2, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        ]),
      ),
      if (isResponded && respondedLabel != null) ...[
        const SizedBox(height: 14),
        _buildRespondedChip(respondedLabel, isWrongItem: true),
      ] else if (canRespond) ...[
        const SizedBox(height: 14),
        _buildWrongItemPromptNote(),
        const SizedBox(height: 12),
        _buildWrongItemActionButtons(disputeId, isSubmitting),
      ] else ...[
        const SizedBox(height: 12),
        _buildStatusChip('Pending supplier notification'),
      ],
    ]);
  }

  Widget _buildQtyTable(int ordered, int received, int short) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(children: [
        _qtyRow('Ordered', '$ordered', false, isFirst: true),
        Divider(height: 1, thickness: 1, color: _kDivider, indent: 12, endIndent: 12),
        _qtyRow('Received', '$received', false),
        Divider(height: 1, thickness: 1, color: _kDivider, indent: 12, endIndent: 12),
        _qtyRow('Missing', '$short', true, isLast: true),
      ]),
    );
  }

  Widget _qtyRow(String label, String value, bool isMissing,
      {bool isFirst = false, bool isLast = false}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, isFirst ? 10 : 8, 12, isLast ? 10 : 8),
      child: Row(children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: isMissing ? _kAmberValue : _kTextMuted,
              fontWeight: isMissing ? FontWeight.w600 : FontWeight.w400,
              height: 1.3,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: isMissing ? FontWeight.w800 : FontWeight.w600,
            color: isMissing ? _kAmberValue : _kTextPrimary,
            height: 1.3,
          ),
        ),
      ]),
    );
  }

  Widget _buildPromptNote() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _kAmberBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.help_outline_rounded, size: 16, color: _kAmber),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'Did the missing quantity actually go undelivered?',
            style: TextStyle(
              fontSize: 14,
              color: _kAmberText,
              fontWeight: FontWeight.w500,
              height: 1.35,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildShortActionButtons(String disputeId, bool isSubmitting) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 52,
        child: FilledButton.icon(
          onPressed: isSubmitting ? null : () => _submit(disputeId, 'missing'),
          style: FilledButton.styleFrom(
            backgroundColor: _kAmber,
            disabledBackgroundColor: const Color(0xFFFDE68A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          icon: isSubmitting
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Icon(Icons.check_rounded, size: 18, color: Colors.white),
          label: const Text('Yes, it was short / missing',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 52,
        child: OutlinedButton.icon(
          onPressed: isSubmitting ? null : () => _submit(disputeId, 'denied'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _kTextPrimary,
            side: const BorderSide(color: Color(0xFFDADCE0), width: 1),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            backgroundColor: _kCard,
          ),
          icon: const Icon(Icons.close_rounded, size: 18),
          label: const Text('No, I supplied it',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
      ),
      const SizedBox(height: 8),
      const Text('Your response is recorded and shared with mediBO.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: _kTextMuted, height: 1.35)),
    ]);
  }

  Widget _buildWrongItemPromptNote() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _kAmberBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.swap_horiz_rounded, size: 16, color: _kAmber),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'Wrong item delivered — can you send the correct one?',
            style: TextStyle(fontSize: 14, color: _kAmberText, fontWeight: FontWeight.w500, height: 1.35),
          ),
        ),
      ]),
    );
  }

  Widget _buildWrongItemActionButtons(String disputeId, bool isSubmitting) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 52,
        child: FilledButton.icon(
          onPressed: isSubmitting ? null : () => _submit(disputeId, 'correct_coming'),
          style: FilledButton.styleFrom(
            backgroundColor: _kGreen,
            disabledBackgroundColor: _kGreen.withValues(alpha: 0.4),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          icon: isSubmitting
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Icon(Icons.local_shipping_outlined, size: 18, color: Colors.white),
          label: const Text('Yes, sending the correct item',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 52,
        child: OutlinedButton.icon(
          onPressed: isSubmitting ? null : () => _submit(disputeId, 'out_of_stock'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _kTextPrimary,
            side: const BorderSide(color: Color(0xFFDADCE0), width: 1),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            backgroundColor: _kCard,
          ),
          icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
          label: const Text('Out of stock',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
      ),
      const SizedBox(height: 8),
      const Text('Your response is recorded and shared with mediBO.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: _kTextMuted, height: 1.35)),
    ]);
  }

  Widget _buildRespondedChip(String response, {required bool isWrongItem}) {
    if (isWrongItem) {
      final isCorrectComing = response == 'correct_coming';
      RenderLog.write('c176_supplier_chip',
          'kind=wrong_item;status=${isCorrectComing ? "accepted_missing" : "denied"};response=$response');
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: isCorrectComing ? _kGreenChipBg : _kNeutralChip,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(
            isCorrectComing ? Icons.local_shipping_outlined : Icons.info_outline_rounded,
            size: 16,
            color: isCorrectComing ? _kGreen : _kTextMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isCorrectComing
                  ? 'Sending correct item'
                  : 'Out of stock — mediBO will re-source',
              style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600,
                color: isCorrectComing ? _kGreen : _kTextMuted, height: 1.35,
              ),
            ),
          ),
        ]),
      );
    }
    final isMissing = response == 'missing';
    RenderLog.write('c176_supplier_chip', 'kind=short;status=${isMissing ? "accepted_missing" : "denied"};response=$response');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: isMissing ? _kGreenChipBg : _kNeutralChip,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(
          isMissing ? Icons.check_circle_outline_rounded : Icons.info_outline_rounded,
          size: 16,
          color: isMissing ? _kGreen : _kTextMuted,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            isMissing
                ? 'Confirmed missing'
                : 'Reported as supplied — under review',
            style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600,
              color: isMissing ? _kGreen : _kTextMuted, height: 1.35,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildStatusChip(String status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _kNeutralChip, borderRadius: BorderRadius.circular(8)),
      child: Text(
        status.replaceAll('_', ' '),
        style: const TextStyle(
          fontSize: 12, fontWeight: FontWeight.w500, color: _kTextMuted),
      ),
    );
  }

  Widget _productThumb(String? imageUrl) {
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          imageUrl, width: 56, height: 56, fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _thumbPlaceholder(),
        ),
      );
    }
    return _thumbPlaceholder();
  }

  Widget _thumbPlaceholder() => Container(
    width: 56, height: 56,
    decoration: BoxDecoration(
      color: const Color(0xFFF1F3F4),
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Icon(Icons.medication_outlined, size: 26, color: _kTextMuted),
  );

  Widget _footer() => Center(
    child: Text(
      'mediBO · B2B Pharmacy Platform',
      style: const TextStyle(fontSize: 11, color: _kTextMuted),
    ),
  );
}
