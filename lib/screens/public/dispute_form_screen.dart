import 'package:flutter/material.dart';
import '../../utils/render_log.dart';
import '../../widgets/fulfill_item_sheet.dart' show ProofThumbnail;
import '../admin/dispute/dispute_models.dart';

// ── Palette ───────────────────────────────────────────────────────────────────
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

String _packQty(num n, String? packType) {
  if (packType == null || packType.trim().isEmpty) return '$n';
  final unit = n == 1 ? packType.trim() : '${packType.trim()}s';
  return '$n $unit';
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
  String _supplierName = '';
  List<DisputeItem> _items = [];
  final Map<String, bool> _submitting = {};
  bool _closedExpanded = false;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c348_token_ready', 'token_page=v2');
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final result = await fetchDisputeForm(widget.token);
      if (!mounted) return;
      RenderLog.write('c190_link_loaded',
          'supplier=${result.supplierName};count=${result.items.length}');
      setState(() {
        _supplierName = result.supplierName;
        _items = result.items;
        _loading = false;
      });
    } on DisputeException catch (e) {
      if (!mounted) return;
      if (e.message == 'invalid') {
        RenderLog.write('c190_link_invalid_shown', 'token_invalid');
      }
      setState(() { _error = e.message; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'load_failed'; _loading = false; });
    }
  }

  Future<void> _submitAction(DisputeItem item, DisputeAction action,
      {List<String> alsoIds = const []}) async {
    if (_submitting[item.disputeId] == true) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action.label),
        content: Text(
          '${item.productName}\nConfirm: ${action.label}?',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kGreen),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _submitting[item.disputeId] = true);
    RenderLog.write('c190_link_submit_called',
        'dispute=${item.disputeId};response=${action.code}');

    try {
      await submitDisputeResponse(
        token: widget.token,
        disputeId: item.disputeId,
        response: action.code,
      );
      // C362 point-8: fan the SAME response to the OTHER lines of this aggregated product.
      for (final id in alsoIds.where((x) => x != item.disputeId)) {
        try {
          await submitDisputeResponse(
              token: widget.token, disputeId: id, response: action.code);
        } catch (_) {}
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thanks — response recorded.')));
      await _load();
    } on DisputeException catch (e) {
      if (!mounted) return;
      if (e.message == 'already_responded') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Already answered — refreshing.')));
        await _load();
      } else if (e.message == 'invalid') {
        setState(() { _error = 'invalid'; _loading = false; });
        RenderLog.write('c190_link_invalid_shown', 'token_invalid_on_submit');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error: ${e.message}'),
              backgroundColor: _kRed));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Submission failed. Please try again.')));
    } finally {
      if (mounted) setState(() => _submitting.remove(item.disputeId));
    }
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
    final isInvalid = _error == 'invalid';
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
            isInvalid
                ? 'This dispute link is invalid or has expired.'
                : 'Unable to load. Please try again.',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                color: _kTextPrimary, height: 1.35),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            isInvalid
                ? 'Please contact mediBO.'
                : 'Check your connection and try again.',
            style: const TextStyle(fontSize: 14, color: _kTextMuted, height: 1.35),
            textAlign: TextAlign.center,
          ),
          if (!isInvalid) ...[
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _load,
              style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Retry'),
            ),
          ],
          const SizedBox(height: 32),
          _footer(),
        ]),
      ),
    );
  }

  Widget _buildPage() {
    // C362 point-8: ITEM-WISE — aggregate by product (summed disputed qty; Active if any).
    final aggregated = aggregateDisputesByProduct(_items);
    final activeItems = aggregated.where((a) => a.active).toList();
    final closedItems = aggregated.where((a) => !a.active).toList();
    RenderLog.write('c362_disp_group', 'where=token;items=${aggregated.length}');

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 48),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _buildHeader(),
        const SizedBox(height: 16),
        const Text('Please confirm the short items below.',
            style: TextStyle(fontSize: 15, color: _kTextMuted, height: 1.35)),
        const SizedBox(height: 12),

        // ── Active section ─────────────────────────────────────────────────
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
            child: _buildItemCard(item),
          )),

        // ── Closed section ─────────────────────────────────────────────────
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
                        child: _buildItemCard(item),
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

  Widget _buildItemCard(AggregatedDispute agg) {
    // C362 point-8: item-wise — representative drives labels/actions; qty summed; the row
    // is Active if ANY underlying line is active.
    final item = agg.representative;
    final isActive   = agg.active;
    final isWrong    = item.kind == 'wrong_item';
    final hasFewWrong = item.kind == 'few_wrong';
    final hasImage   = (item.imageUrl ?? '').isNotEmpty;
    final isSubmitting = _submitting[item.disputeId] == true;

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

        // (a) Header row
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: hasImage
                ? Image.network(item.imageUrl!, width: 60, height: 60, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _imagePlaceholder())
                : _imagePlaceholder(),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(item.productName.isNotEmpty ? item.productName : '—',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700,
                            color: isActive ? _kTextPrimary : _kTextMuted, height: 1.3),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    // (a) wrong product name
                    if ((isWrong || hasFewWrong) && (item.wrongProductName ?? '').isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text('They say we sent: ${item.wrongProductName}',
                          style: const TextStyle(fontSize: 12, color: _kRed),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ]),
                ),
                const SizedBox(width: 6),
                // C362 point-8: Active = RED / Inactive = GREEN badge — replaces the verbose
                // "Awaiting supplier response" item_status_label pill.
                Builder(builder: (_) {
                  RenderLog.write('c362_badge', 'where=supplier,active=$isActive');
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isActive
                          ? const Color(0xFFFEE2E2)
                          : const Color(0xFFD1FAE5),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(isActive ? 'Active' : 'Inactive',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isActive
                                ? const Color(0xFF991B1B)
                                : const Color(0xFF065F46))),
                  );
                }),
              ]),
              // (b) meta
              if ((item.disputeCode ?? '').isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  item.disputeCode!,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF9CA3AF),
                    letterSpacing: 0.3,
                  ),
                ),
              ],
              if ((item.category ?? '').isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(item.category!,
                    style: const TextStyle(fontSize: 12, color: _kTextMuted),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
              if ((item.company ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(item.company!,
                    style: const TextStyle(fontSize: 12, color: _kTextMuted),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ]),
          ),
        ]),

        // (c) Quantities table
        const SizedBox(height: 12),
        _buildQtyTable(agg.orderedQty, agg.receivedQty, agg.disputedQty, item.packType),
        if (agg.disputedQty > 0) ...[
          const SizedBox(height: 6),
          Text(
              'In dispute: ${agg.disputedQty.toInt()} units'
              '${agg.lines.length > 1 ? ' (${agg.lines.length} orders)' : ''}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: _kAmberText)),
        ],

        // (d) item_status_label — pill already in header; log only
        Builder(builder: (_) {
          final hidden = item.isAwaitingSupplier;
          RenderLog.write('c191_link_awaiting_hidden', '${hidden ? 'true' : 'false'};dispute=${item.disputeId};status=${item.statusCode}');
          return const SizedBox.shrink();
        }),

        // Return-note chip
        if ((item.returnNoteStatus ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          Builder(builder: (_) {
            final isOpen = item.returnNoteStatus == 'open';
            return Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isOpen ? _kAmberBg : _kNeutralChip,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isOpen
                      ? 'Stock with buyer — pick up on next delivery'
                      : 'Return collected ✓',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: isOpen ? _kAmberText : _kTextMuted),
                ),
              ),
            );
          }),
        ],

        // (e2) Proof photo — c194
        if ((item.proofUrl ?? '').isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Text('Proof photo:',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _kTextMuted)),
            const SizedBox(width: 10),
            ProofThumbnail(proofUrl: item.proofUrl!, size: 72),
          ]),
        ],

        // (f) Action buttons — dynamic from item.actions; only shown when array non-empty
        if (item.actions.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildActionButtons(item, isSubmitting, agg.allActiveDisputeIds),
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

  Widget _buildQtyTable(num ordered, num received, num short, String? packType) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
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
        child: Text(text, textAlign: TextAlign.center,
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

  // Dynamic buttons from item.actions — no hardcoded codes or labels
  Widget _buildActionButtons(DisputeItem item, bool isSubmitting, List<String> groupIds) {
    RenderLog.write('c190_link_buttons_rendered',
        'dispute=${item.disputeId};count=${item.actions.length}');
    const spinner = SizedBox(width: 14, height: 14,
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2));

    if (item.actions.length == 1) {
      final action = item.actions.first;
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: isSubmitting ? null : () => _submitAction(item, action, alsoIds: groupIds),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFD97706),
            disabledBackgroundColor: const Color(0xFFFDE68A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(vertical: 11),
          ),
          child: isSubmitting ? spinner : Text(action.label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: item.actions.asMap().entries.map((e) {
        final idx = e.key;
        final action = e.value;
        final isPrimary = idx == 0;
        if (isPrimary) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: FilledButton(
              onPressed: isSubmitting ? null : () => _submitAction(item, action, alsoIds: groupIds),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD97706),
                disabledBackgroundColor: const Color(0xFFFDE68A),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
              child: isSubmitting ? spinner : Text(action.label,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          );
        }
        return OutlinedButton(
          onPressed: isSubmitting ? null : () => _submitAction(item, action, alsoIds: groupIds),
          style: OutlinedButton.styleFrom(
            foregroundColor: _kTextPrimary,
            side: const BorderSide(color: _kBorder),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(vertical: 11),
          ),
          child: Text(action.label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        );
      }).toList(),
    );
  }

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
          Text('Hi $_supplierName',
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
