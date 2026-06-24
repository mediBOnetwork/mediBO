import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';

const _kGreen       = Color(0xFF1B7A43);
const _kText        = Color(0xFF111827);
const _kSub         = Color(0xFF6B7280);
const _kBorder      = Color(0xFFE5E7EB);
const _kCard        = Colors.white;
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

class SupplierDisputesScreen extends StatefulWidget {
  final String? viewAsSupplierName;
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
  final Map<String, bool> _responding = {};
  bool _closedExpanded = false;

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
      final activeCount = raw.where(_isActive).length;
      final closedCount = raw.length - activeCount;
      final hasCategory = raw.any((i) {
        final c = i['category']?.toString() ?? '';
        return c.isNotEmpty;
      });
      final hasCompany = raw.any((i) {
        final c = i['company']?.toString() ?? '';
        return c.isNotEmpty;
      });
      RenderLog.write('c175_portal_load',
          'acting=${_actingSupplier != null};count=${raw.length}');
      RenderLog.write('c185_supplier_card',
          'change:185,surface:portal,card_layout:true,has_image_slot:true,'
          'has_category:$hasCategory,has_company:$hasCompany,'
          'missing_amber:true,'
          'active_count:$activeCount,'
          'closed_count:$closedCount');
      setState(() { _disputes = raw; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().substring(0, e.toString().length.clamp(0, 120));
      setState(() { _loading = false; _error = msg; });
      RenderLog.write('c175_portal_error', 'code=$msg');
    }
  }

  Future<void> _respond(String disputeId, String kind, String response) async {
    if (_responding[disputeId] == true) return;
    setState(() => _responding[disputeId] = true);
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
          // silent reload
        } else if (errCode == 'bad_response') {
          msg = "That option isn't valid for this dispute";
        } else if (errCode == 'no_supplier') {
          msg = 'Session expired — please sign in again';
        } else {
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
      // Optimistic update
      setState(() {
        final idx = _disputes.indexWhere((e) => e['dispute_id']?.toString() == disputeId);
        if (idx >= 0) {
          final newStatus = (response == 'missing' || response == 'correct_coming')
              ? 'accepted_missing' : 'denied';
          _disputes[idx] = Map<String, dynamic>.from(_disputes[idx])
            ..['status'] = newStatus
            ..['response'] = response
            ..['active'] = true;
        }
        _responding.remove(disputeId);
      });
      RenderLog.write('c175_portal_respond',
          'dispute_id=$disputeId;kind=$kind;response=$response;result=ok');
      await _load();
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
      return const Center(
          child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
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

    final activeItems = _disputes.where(_isActive).toList();
    final closedItems = _disputes.where((i) => !_isActive(i)).toList();

    return RefreshIndicator(
      onRefresh: _load,
      color: _kGreen,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              // ── Active section ──────────────────────────────────────────
              _sectionLabel('Active', activeItems.length, active: true),
              const SizedBox(height: 8),
              if (activeItems.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No active disputes.',
                      style: TextStyle(fontSize: 13, color: _kSub)),
                )
              else
                ...activeItems.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _buildItemCard(item, isActive: true),
                )),

              // ── Closed section ──────────────────────────────────────────
              if (closedItems.isNotEmpty) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => setState(() => _closedExpanded = !_closedExpanded),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      _closedExpanded
                          ? 'Hide closed (${closedItems.length})'
                          : 'Show closed (${closedItems.length})',
                      style: const TextStyle(fontSize: 13, color: _kSub,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _closedExpanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeInOutCubic,
                      child: const Icon(Icons.keyboard_arrow_down_rounded,
                          size: 16, color: _kSub),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String label, int count, {required bool active}) {
    return Row(children: [
      Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
          color: active ? _kGreen : _kSub,
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 6),
      Text(label,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
              color: active ? _kText : _kSub)),
      const SizedBox(width: 4),
      Text('($count)',
          style: const TextStyle(fontSize: 12, color: _kSub)),
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
    final isResponding = _responding[disputeId] == true;
    final canRespond = isActive && (status == 'reminder_sent' || status == 'shop_logged');

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
                          color: isActive ? _kText : _kSub,
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
                    style: const TextStyle(fontSize: 12, color: _kSub),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
              // Line 3: company
              if (company != null && company.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(company,
                    style: const TextStyle(fontSize: 12, color: _kSub),
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
        if (canRespond) ...[
          const SizedBox(height: 12),
          _buildResponseButtons(disputeId, kind, isResponding),
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
          color: isActive ? _kGreen : _kSub,
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
            _qtyCell('Ordered', isHeader: true, isAmber: false),
            _vertDivider(),
            _qtyCell('Received', isHeader: true, isAmber: false),
            _vertDivider(),
            _qtyCell('Missing', isHeader: true, isAmber: true),
          ]),
        ),
        Divider(height: 1, color: _kBorder),
        // Value row
        IntrinsicHeight(
          child: Row(children: [
            _qtyCell(_packQty(ordered, packType), isHeader: false, isAmber: false),
            _vertDivider(),
            _qtyCell(_packQty(received, packType), isHeader: false, isAmber: false),
            _vertDivider(),
            _qtyCell(_packQty(short, packType), isHeader: false, isAmber: true, isBold: true),
          ]),
        ),
      ]),
    );
  }

  Widget _qtyCell(String text, {required bool isHeader, required bool isAmber,
      bool isBold = false}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        color: isAmber && !isHeader ? _kAmberBg : null,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: isHeader ? 11 : 13,
            fontWeight: (isHeader || isBold) ? FontWeight.w700 : FontWeight.w400,
            color: isAmber ? _kAmberText : (isHeader ? _kSub : _kText),
          ),
        ),
      ),
    );
  }

  Widget _vertDivider() => VerticalDivider(width: 1, color: _kBorder, thickness: 1);

  Widget _buildResponseButtons(String disputeId, String kind, bool isResponding) {
    final spinner = const SizedBox(width: 14, height: 14,
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2));
    if (kind == 'wrong_item') {
      return Column(children: [
        SizedBox(width: double.infinity,
          child: FilledButton(
            onPressed: isResponding ? null
                : () => _respond(disputeId, kind, 'correct_coming'),
            style: FilledButton.styleFrom(
              backgroundColor: _kGreen,
              disabledBackgroundColor: _kGreen.withValues(alpha: 0.4),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            child: isResponding ? spinner
                : const Text('Sending the correct item',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: Colors.white)),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(width: double.infinity,
          child: OutlinedButton(
            onPressed: isResponding ? null
                : () => _respond(disputeId, kind, 'out_of_stock'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kText,
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
            onPressed: isResponding ? null
                : () => _respond(disputeId, kind, 'missing'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD97706),
              disabledBackgroundColor: const Color(0xFFFDE68A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            child: isResponding ? spinner
                : const Text('Yes, it was short / missing',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: Colors.white)),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(width: double.infinity,
          child: OutlinedButton(
            onPressed: isResponding ? null
                : () => _respond(disputeId, kind, 'denied'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kText,
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
      label = status; bg = _kNeutralChip; fg = _kSub;
    }
    return _chip(label, bg, fg);
  }

  Widget _closedChip(String status) => status == 'cancelled'
      ? _chip('Cancelled', _kNeutralChip, _kSub)
      : _chip('Resolved', _kGreenChipBg, _kGreen);

  Widget _chip(String label, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
    child: Text(label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
  );
}
