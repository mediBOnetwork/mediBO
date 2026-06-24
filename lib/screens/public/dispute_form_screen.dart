import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/render_log.dart';

// ── Palette ──────────────────────────────────────────────────────────────────
const _kGreen       = Color(0xFF1B7A43);
const _kBg          = Color(0xFFF4F6F8);
const _kCard        = Color(0xFFFFFFFF);
const _kBorder      = Color(0xFFE8EAED);
const _kTextPrimary = Color(0xFF202124);
const _kTextMuted   = Color(0xFF5F6368);
const _kRed         = Color(0xFFDC2626);
const _kGreenChipBg = Color(0xFFE7F4EC);
const _kNeutralChip = Color(0xFFF1F3F4);
const _kAmberText   = Color(0xFFB8860B);
const _kAmberBg     = Color(0xFFFFF8E1);

// ── Helpers ───────────────────────────────────────────────────────────────────
String _packQty(num n, String? packType) {
  if (packType == null || packType.trim().isEmpty) return '$n';
  final unit = n == 1 ? packType.trim() : '${packType.trim()}s';
  return '$n $unit';
}

num _toNum(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v;
  return num.tryParse(v.toString()) ?? 0;
}

bool _isActive(Map<String, dynamic> item) {
  if (item.containsKey('active')) return item['active'] == true;
  final s = item['status']?.toString() ?? '';
  return s != 'resolved' && s != 'cancelled';
}

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
  bool _closedExpanded = false;

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
      setState(() {
        _supplierName = data['supplier_name']?.toString();
        _items = rawItems;
        _loading = false;
      });
      final activeCount = rawItems.where(_isActive).length;
      final closedCount = rawItems.length - activeCount;
      final hasCategory = rawItems.any((i) {
        final c = i['category']?.toString() ?? '';
        return c.isNotEmpty;
      });
      final hasCompany = rawItems.any((i) {
        final c = i['company']?.toString() ?? '';
        return c.isNotEmpty;
      });
      RenderLog.write('c170_dispute_form_items', '${rawItems.length}');
      RenderLog.write('c172_dispute_page_rendered',
          'supplier=${_supplierName ?? ''};item_count=${rawItems.length}');
      RenderLog.write('c185_supplier_card',
          'change:185,surface:link,card_layout:true,has_image_slot:true,'
          'has_category:$hasCategory,has_company:$hasCompany,'
          'missing_amber:true,'
          'active_count:$activeCount,'
          'closed_count:$closedCount');
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
        final err = data['error']?.toString() ?? 'unknown';
        setState(() => _submitting[disputeId] = false);
        if (err == 'already_responded') { await _load(); return; }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $err'), backgroundColor: _kRed),
        );
        return;
      }
      setState(() {
        _submitting[disputeId] = false;
        final idx = _items.indexWhere((e) => e['dispute_id']?.toString() == disputeId);
        if (idx >= 0) {
          final newStatus = (response == 'missing' || response == 'correct_coming')
              ? 'accepted_missing' : 'denied';
          _items[idx] = Map<String, dynamic>.from(_items[idx])
            ..['status'] = newStatus
            ..['supplier_response'] = response
            ..['active'] = true;
        }
      });
      RenderLog.write('c185_dispute_submit', 'dispute_id=$disputeId;response=$response');
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting[disputeId] = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Submission failed. Please try again.')),
      );
    }
  }

  bool get _allActiveResponded {
    final active = _items.where(_isActive).toList();
    if (active.isEmpty) return false;
    return active.every((item) {
      final s = item['status']?.toString() ?? '';
      return s == 'accepted_missing' || s == 'denied';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: _loading
                ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(color: _kGreen, strokeWidth: 2.5),
                    SizedBox(height: 12),
                    Text('Loading…', style: TextStyle(fontSize: 14, color: _kTextMuted)),
                  ]))
                : _error != null ? _buildErrorState() : _buildPage(),
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
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                color: _kTextPrimary, height: 1.35),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text('Please contact mediBO.',
              style: TextStyle(fontSize: 14, color: _kTextMuted, height: 1.35),
              textAlign: TextAlign.center),
          const SizedBox(height: 32),
          _footer(),
        ]),
      ),
    );
  }

  Widget _buildPage() {
    final activeItems = _items.where(_isActive).toList();
    final closedItems = _items.where((i) => !_isActive(i)).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 48),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _buildHeader(),
        const SizedBox(height: 16),
        const Text('Delivery disputes — please confirm each item below',
            style: TextStyle(fontSize: 15, color: _kTextMuted, height: 1.35)),
        const SizedBox(height: 12),

        if (_allActiveResponded) ...[
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
              Expanded(child: Text('Thanks — all responses recorded.',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                      color: _kGreen, height: 1.35))),
            ]),
          ),
          const SizedBox(height: 12),
        ],

        // ── Active section ────────────────────────────────────────────────
        _buildSectionLabel('Active', activeItems.length, active: true),
        const SizedBox(height: 8),
        if (activeItems.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('No active disputes.',
                style: TextStyle(fontSize: 13, color: _kTextMuted)),
          )
        else
          ...activeItems.map((item) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _buildItemCard(item, isActive: true),
          )),

        // ── Closed section ────────────────────────────────────────────────
        if (closedItems.isNotEmpty) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => setState(() => _closedExpanded = !_closedExpanded),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(
                _closedExpanded
                    ? 'Hide closed (${closedItems.length})'
                    : 'Show closed (${closedItems.length})',
                style: const TextStyle(fontSize: 13, color: _kTextMuted,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _closedExpanded ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic,
                child: const Icon(Icons.keyboard_arrow_down_rounded,
                    size: 16, color: _kTextMuted),
              ),
            ]),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOutCubic,
            clipBehavior: Clip.antiAlias,
            child: _closedExpanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: closedItems.map((item) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _buildItemCard(item, isActive: false),
                      )).toList(),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],

        const SizedBox(height: 24),
        _footer(),
      ]),
    );
  }

  Widget _buildSectionLabel(String label, int count, {required bool active}) {
    return Row(children: [
      Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
          color: active ? _kGreen : _kTextMuted,
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 6),
      Text(label,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
              color: active ? _kTextPrimary : _kTextMuted)),
      const SizedBox(width: 4),
      Text('($count)',
          style: const TextStyle(fontSize: 12, color: _kTextMuted)),
    ]);
  }

  Widget _buildItemCard(Map<String, dynamic> item, {required bool isActive}) {
    final disputeId = item['dispute_id']?.toString() ?? '';
    final kind      = item['kind']?.toString() ?? 'short';
    final isWrong   = kind == 'wrong_item';
    final product   = item['product_name']?.toString() ?? '—';
    final wrongProd = item['wrong_product_name']?.toString();
    final packType  = item['pack_type']?.toString();
    final category  = item['category']?.toString();
    final company   = item['company']?.toString();
    final imageUrl  = item['image_url']?.toString();
    final ordered   = _toNum(item['ordered']);
    final received  = _toNum(item['received']);
    final short     = isWrong ? ordered : _toNum(item['short']);
    final status    = item['status']?.toString() ?? '';
    final isSubmitting = _submitting[disputeId] == true;
    final actionable = isActive && (status == 'reminder_sent' || status == 'shop_logged');

    final hasImage = imageUrl != null && imageUrl.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // ── (1) Header row: image + info ─────────────────────────────────
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Image
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: hasImage
                ? Image.network(
                    imageUrl!,
                    width: 60, height: 60,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _imagePlaceholder(),
                  )
                : _imagePlaceholder(),
          ),
          const SizedBox(width: 10),

          // Info column
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Line 1: name + active/closed pill
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Text(product,
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700,
                          color: isActive ? _kTextPrimary : _kTextMuted,
                          height: 1.3),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 6),
                _statusPill(isActive),
              ]),
              // Line 2: category
              if (category != null && category.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(category,
                    style: const TextStyle(fontSize: 12, color: _kTextMuted),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
              // Line 3: company
              if (company != null && company.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(company,
                    style: const TextStyle(fontSize: 12, color: _kTextMuted),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
              // Line 4: wrong item note
              if (isWrong) ...[
                const SizedBox(height: 3),
                Text('Wrong: sent ${(wrongProd != null && wrongProd.isNotEmpty) ? wrongProd : '—'}',
                    style: const TextStyle(fontSize: 12, color: _kRed),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ]),
          ),
        ]),

        // ── (2) Qty table ─────────────────────────────────────────────────
        const SizedBox(height: 12),
        _buildQtyTable(ordered, received, short, packType),

        // ── (3) Action area ───────────────────────────────────────────────
        if (actionable) ...[
          const SizedBox(height: 12),
          _buildResponseButtons(disputeId, kind, isSubmitting),
        ] else if (isActive) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: _activeChip(status, kind),
          ),
        ] else ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: _closedChip(status),
          ),
        ],
      ]),
    );
  }

  Widget _imagePlaceholder() => Container(
    width: 60, height: 60,
    decoration: BoxDecoration(
      color: const Color(0xFFF1F3F4),
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Icon(Icons.medication_outlined, size: 28, color: Color(0xFFBDBDBD)),
  );

  Widget _statusPill(bool isActive) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: isActive ? _kGreenChipBg : _kNeutralChip,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isActive ? 'Active' : 'Closed',
        style: TextStyle(
          fontSize: 11, fontWeight: FontWeight.w600,
          color: isActive ? _kGreen : _kTextMuted,
        ),
      ),
    );
  }

  Widget _buildQtyTable(num ordered, num received, num short, String? packType) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
        // Header row
        IntrinsicHeight(
          child: Row(children: [
            _qtyCell('Ordered', flex: 1, isHeader: true, isAmber: false),
            _vertDivider(),
            _qtyCell('Received', flex: 1, isHeader: true, isAmber: false),
            _vertDivider(),
            _qtyCell('Missing', flex: 1, isHeader: true, isAmber: true),
          ]),
        ),
        Divider(height: 1, color: _kBorder),
        // Value row
        IntrinsicHeight(
          child: Row(children: [
            _qtyCell(_packQty(ordered, packType), flex: 1, isHeader: false, isAmber: false),
            _vertDivider(),
            _qtyCell(_packQty(received, packType), flex: 1, isHeader: false, isAmber: false),
            _vertDivider(),
            _qtyCell(_packQty(short, packType), flex: 1, isHeader: false, isAmber: true, isBold: true),
          ]),
        ),
      ]),
    );
  }

  Widget _qtyCell(String text, {required int flex, required bool isHeader,
      required bool isAmber, bool isBold = false}) {
    return Expanded(
      flex: flex,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        color: isAmber && !isHeader ? _kAmberBg : null,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: isHeader ? 11 : 13,
            fontWeight: (isHeader || isBold) ? FontWeight.w700 : FontWeight.w400,
            color: isAmber ? _kAmberText : (isHeader ? _kTextMuted : _kTextPrimary),
          ),
        ),
      ),
    );
  }

  Widget _vertDivider() => VerticalDivider(width: 1, color: _kBorder, thickness: 1);

  Widget _buildResponseButtons(String disputeId, String kind, bool isSubmitting) {
    final spinner = const SizedBox(width: 14, height: 14,
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2));
    if (kind == 'wrong_item') {
      return Column(children: [
        SizedBox(width: double.infinity,
          child: FilledButton(
            onPressed: isSubmitting ? null : () => _submit(disputeId, 'correct_coming'),
            style: FilledButton.styleFrom(
              backgroundColor: _kGreen,
              disabledBackgroundColor: _kGreen.withValues(alpha: 0.4),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            child: isSubmitting ? spinner
                : const Text('Sending the correct item',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: Colors.white)),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(width: double.infinity,
          child: OutlinedButton(
            onPressed: isSubmitting ? null : () => _submit(disputeId, 'out_of_stock'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kTextPrimary,
              side: const BorderSide(color: _kBorder),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            child: const Text('Out of stock',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
      ]);
    } else {
      return Column(children: [
        SizedBox(width: double.infinity,
          child: FilledButton(
            onPressed: isSubmitting ? null : () => _submit(disputeId, 'missing'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD97706),
              disabledBackgroundColor: const Color(0xFFFDE68A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            child: isSubmitting ? spinner
                : const Text('Yes, it was short / missing',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: Colors.white)),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(width: double.infinity,
          child: OutlinedButton(
            onPressed: isSubmitting ? null : () => _submit(disputeId, 'denied'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kTextPrimary,
              side: const BorderSide(color: _kBorder),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            child: const Text('No, I supplied it',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
      ]);
    }
  }

  Widget _activeChip(String status, String kind) {
    final isWrong = kind == 'wrong_item';
    String label; Color bg; Color fg;
    if (status == 'accepted_missing') {
      if (isWrong) { label = 'Exchange awaited'; bg = _kGreenChipBg; fg = _kGreen; }
      else { label = 'Being re-sourced'; bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E); }
    } else if (status == 'denied') {
      if (isWrong) { label = 'Being re-sourced'; bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E); }
      else { label = 'Needs admin decision'; bg = const Color(0xFFFEE2E2); fg = _kRed; }
    } else {
      label = status; bg = _kNeutralChip; fg = _kTextMuted;
    }
    return _chip(label, bg, fg);
  }

  Widget _closedChip(String status) => status == 'cancelled'
      ? _chip('Cancelled', _kNeutralChip, _kTextMuted)
      : _chip('Resolved', _kGreenChipBg, _kGreen);

  Widget _chip(String label, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
    child: Text(label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
  );

  Widget _buildHeader() => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(color: _kGreen, borderRadius: BorderRadius.circular(16)),
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
          Text('mediBO · Delivery Dispute',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.70),
                  fontSize: 11, fontWeight: FontWeight.w500,
                  letterSpacing: 0.5, height: 1.3)),
          const SizedBox(height: 4),
          Text(_supplierName ?? '',
              style: const TextStyle(color: Colors.white, fontSize: 21,
                  fontWeight: FontWeight.w800, height: 1.2),
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ]),
      ),
    ]),
  );

  Widget _footer() => const Center(
    child: Text('mediBO · B2B Pharmacy Platform',
        style: TextStyle(fontSize: 11, color: _kTextMuted)),
  );
}
