import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/fulfill_realtime.dart' show kC416;
import '../../utils/render_log.dart';
import '../../widgets/fulfill_item_sheet.dart' show ProofThumbnail;
import '../admin/dispute/dispute_models.dart';

const _kGreen       = Color(0xFF1B7A43);
const _kText        = Color(0xFF111827);
const _kSub         = Color(0xFF6B7280);
const _kBorder      = Color(0xFFE5E7EB);
const _kCard        = Colors.white;
const _kRed         = Color(0xFFDC2626);
const _kAmberText   = Color(0xFFB8860B);
const _kAmberBg     = Color(0xFFFFF8E1);
const _kNeutralChip = Color(0xFFF1F3F4);
const _kGreenChipBg = Color(0xFFE7F4EC);

Color _hexColor(String? hex, Color fallback) {
  if (hex == null || hex.isEmpty) return fallback;
  final h = hex.startsWith('#') ? hex.substring(1) : hex;
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? fallback : Color(v);
}

String _packQty(num n, String? packType) {
  if (packType == null || packType.trim().isEmpty) return '$n';
  final unit = n == 1 ? packType.trim() : '${packType.trim()}s';
  return '$n $unit';
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
  List<DisputeItem> _disputes = [];
  bool _acting = false;
  String _supplierName = '';
  bool _closedExpanded = false;
  final Map<String, bool> _responding = {};
  RealtimeChannel? _rtChannel;
  Timer? _rtDebounce;

  String? get _actingSupplier => widget.viewAsSupplierName;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c348_ready', 'sup_disputes=v2');
    RenderLog.write('c189_realtime_subscribed', 'supplier_disputes_screen_init');
    _subscribeRealtime();
    _load();
  }

  @override
  void didUpdateWidget(SupplierDisputesScreen old) {
    super.didUpdateWidget(old);
    if (old.viewAsSupplierName != widget.viewAsSupplierName) _load();
  }

  @override
  void dispose() {
    _rtDebounce?.cancel();
    _rtChannel?.unsubscribe();
    _rtChannel = null;
    super.dispose();
  }

  void _subscribeRealtime() {
    try {
      _rtChannel = Supabase.instance.client
          .channel('supplier_disputes_189_${_actingSupplier ?? "self"}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'supplier_disputes',
            callback: (_) {
              _rtDebounce?.cancel();
              _rtDebounce = Timer(const Duration(milliseconds: 250), () {
                if (mounted) _load();
              });
            },
          )
          .subscribe((status, [_]) {
            if (status == RealtimeSubscribeStatus.subscribed) {
              RenderLog.write('c189_realtime_subscribed',
                  'supplier_disputes_channel_ok;acting=${_actingSupplier != null}');
            }
          });
    } catch (_) {}
  }

  Future<void> _load() async {
    if (!mounted) return;
    // #416: SILENT refetch — spinner only on first load. A realtime-driven
    // refetch (from the postgres_changes subscription above) must patch the
    // existing list in place, never flash a full-screen loader.
    if (_disputes.isEmpty) {
      setState(() { _loading = true; _error = null; });
    } else if (_error != null) {
      setState(() => _error = null);
    }
    try {
      final result = await fetchSupplierDisputesList(actingSupplier: _actingSupplier);
      if (!mounted) return;
      _acting = result.acting;
      _supplierName = result.supplier;
      RenderLog.write('c189_reminder_loaded',
          'supplier=$_supplierName;acting=$_acting;count=${result.items.length}');
      RenderLog.write(kC416, 'supplier_disputes_synced:count=${result.items.length}');
      setState(() { _disputes = result.items; _loading = false; });
    } on DisputeException catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.message; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().substring(0, e.toString().length.clamp(0, 120));
      });
    }
  }

  // Supplier button tap (actions)
  Future<void> _respondSupplier(DisputeItem item, DisputeAction action,
      {List<String> alsoIds = const []}) async {
    if (_responding[item.disputeId] == true) return;
    setState(() => _responding[item.disputeId] = true);
    RenderLog.write('c189_supplier_respond_called',
        'dispute=${item.disputeId};response=${action.code}');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action.label),
        content: Text(
          '${item.productName}\nConfirm: ${action.label}?',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kGreen),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      setState(() => _responding.remove(item.disputeId));
      return;
    }

    try {
      final res = await supplierRespondDisputeRpc(
        disputeId: item.disputeId,
        response: action.code,
        actingSupplier: _actingSupplier,
      );
      if (!mounted) return;
      RenderLog.write('c348_responded', 'code=${action.code}');
      final result = res['result']?.toString() ?? action.label;
      // C362 point-8: fan the SAME response to the OTHER lines of this aggregated product.
      final others = alsoIds.where((id) => id != item.disputeId).toList();
      for (final id in others) {
        try {
          await supplierRespondDisputeRpc(
              disputeId: id, response: action.code, actingSupplier: _actingSupplier);
        } catch (_) {}
      }
      if (others.isNotEmpty) {
        RenderLog.write('c362_disp_group', 'supplier_fanout=${others.length}');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Recorded: $result')));
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) _load();
      });
    } on DisputeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().substring(0, e.toString().length.clamp(0, 80)))));
    } finally {
      if (mounted) setState(() => _responding.remove(item.disputeId));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
    if (_error != null) {
      final isNoSupplier = _error == 'no_supplier';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(isNoSupplier ? Icons.store_outlined : Icons.wifi_off_rounded,
                size: 48, color: _kSub),
            const SizedBox(height: 12),
            Text(isNoSupplier
                ? 'No supplier account found.'
                : 'Unable to load disputes.',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kSub)),
            if (!isNoSupplier) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(fontSize: 12, color: _kSub),
                  textAlign: TextAlign.center),
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
            ],
          ]),
        ),
      );
    }
    if (_disputes.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle_outline_rounded, size: 48, color: _kGreen),
          const SizedBox(height: 12),
          const Text('No disputes for this supplier.',
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

    // C362 point-8: ITEM-WISE — aggregate by product (one row per product; disputed qty
    // summed). Active if ANY line active; keep the active/closed grouping for the supplier.
    final aggregated = aggregateDisputesByProduct(_disputes);
    final activeItems = aggregated.where((a) => a.active).toList();
    final closedItems = aggregated.where((a) => !a.active).toList();
    RenderLog.write('c362_disp_group', 'where=supplier;items=${aggregated.length}');
    RenderLog.write('c191_reminder_no_admin_buttons', 'admin_buttons_removed=true;items=${_disputes.length}');

    return RefreshIndicator(
      onRefresh: _load,
      color: _kGreen,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              // Acting-as banner
              if (_acting) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFBBF24)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.admin_panel_settings_outlined,
                        size: 16, color: Color(0xFF92400E)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Viewing as $_supplierName (admin)',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: Color(0xFF92400E)),
                      ),
                    ),
                  ]),
                ),
              ],

              // Active section
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
                  child: _buildItemCard(item),
                )),

              // Closed section
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
                              child: _buildItemCard(item),
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

  Widget _buildItemCard(AggregatedDispute agg) {
    // C362 point-8: item-wise — representative drives labels/actions; qty summed; the row
    // is Active if ANY underlying line is active.
    final item = agg.representative;
    final isActive   = agg.active;
    final hasImage   = (item.imageUrl ?? '').isNotEmpty;
    final isResponding = _responding[item.disputeId] == true;

    // Backend-owned (supplier_my_disputes): active_colors, kind_label/kind_colors —
    // verbatim, drive the badge and kind tag below. label is populated by
    // construction, so there is no client-side Active/Inactive fallback.
    final activeColors = agg.activeColors;
    final activeLabel = activeColors?['label'] ?? '';
    final activeBg = _hexColor(activeColors?['bg'], const Color(0xFFF3F4F6));
    final activeFg = _hexColor(activeColors?['fg'], _kSub);
    final kindTagText = item.kindLabel;
    final kindTagBg = _hexColor(item.kindColors?['bg'], const Color(0xFFF1F5F9));
    final kindTagFg = _hexColor(item.kindColors?['fg'], const Color(0xFF475569));

    RenderLog.write('c348_card', 'kind=${item.kind}');

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

        // (a) Header row: image + info
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: hasImage
                ? Image.network(item.imageUrl!, width: 60, height: 60,
                    fit: BoxFit.cover,
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
                            color: isActive ? _kText : _kSub, height: 1.3),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    // B1b: wrong_product_name
                    if ((item.wrongProductName ?? '').isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text('They say we sent: ${item.wrongProductName}',
                          style: const TextStyle(fontSize: 12, color: _kRed),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                    if (kindTagText.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                              color: kindTagBg, borderRadius: BorderRadius.circular(5)),
                          child: Text(kindTagText,
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                                  color: kindTagFg)),
                        ),
                      ),
                    ],
                  ]),
                ),
                const SizedBox(width: 6),
                // Backend-owned (supplier_my_disputes): active_colors, verbatim —
                // replaces the verbose "Awaiting supplier response" item_status_label pill.
                Builder(builder: (_) {
                  RenderLog.write('c362_badge', 'where=supplier,active=$isActive');
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: activeBg,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(activeLabel,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: activeFg)),
                  );
                }),
              ]),
              if ((item.disputeCode ?? '').isNotEmpty) ...[
                const SizedBox(height: 3),
                Builder(builder: (_) {
                  RenderLog.write('c317_dispute_id_shown', item.disputeCode!);
                  return Text(
                    item.disputeCode!,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF9CA3AF),
                      letterSpacing: 0.3,
                    ),
                  );
                }),
              ],
              if ((item.category ?? '').isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(item.category!,
                    style: const TextStyle(fontSize: 12, color: _kSub),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
              if ((item.company ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(item.company!,
                    style: const TextStyle(fontSize: 12, color: _kSub),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ]),
          ),
        ]),

        // (c) Quantities table + "In dispute: N units"
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

        // Proof photo thumbnail
        if ((item.proofUrl ?? '').isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Text('Proof photo:',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: _kSub)),
            const SizedBox(width: 10),
            ProofThumbnail(proofUrl: item.proofUrl!, size: 72),
          ]),
        ],

        // (d) item_status_label badge — hidden while awaiting (meaningless to supplier)
        if (!item.isAwaitingSupplier) ...[
          const SizedBox(height: 10),
          Builder(builder: (_) {
            RenderLog.write('c191_reminder_awaiting_hidden', 'false;dispute=${item.disputeId};status=${item.statusCode}');
            return const SizedBox.shrink(); // pill is already in header row
          }),
        ] else ...[
          Builder(builder: (_) {
            RenderLog.write('c191_reminder_awaiting_hidden', 'true;dispute=${item.disputeId};status=${item.statusCode}');
            return const SizedBox.shrink();
          }),
        ],

        // Return-note chip — backend-owned (supplier_my_disputes' return_note_chip), verbatim.
        if (item.returnNoteChip != null) ...[
          const SizedBox(height: 8),
          Builder(builder: (_) {
            final chip = item.returnNoteChip!;
            RenderLog.write('c348_return_chip', 'open=${chip.isOpen}');
            return Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _hexColor(chip.bg, _kNeutralChip),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  chip.labelCard,
                  style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600,
                    color: _hexColor(chip.fg, _kSub),
                  ),
                ),
              ),
            );
          }),
        ],

        // Supplier action buttons (item.actions only). C362 point-8: a response fans out to
        // every underlying order-line of this aggregated product.
        if (item.actions.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildSupplierButtons(item, isResponding, agg.allActiveDisputeIds),
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
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
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
            color: isAmber ? _kAmberText : (isHeader ? _kSub : _kText),
          ),
        ),
      ),
    );
  }

  Widget _vertDivider() =>
      const VerticalDivider(width: 1, color: Color(0xFFE5E7EB), thickness: 1);

  // Supplier buttons from item.actions
  Widget _buildSupplierButtons(DisputeItem item, bool isResponding, List<String> groupIds) {
    RenderLog.write('c189_supplier_buttons_rendered',
        'dispute=${item.disputeId};count=${item.actions.length}');
    RenderLog.write('c348_actions', 'n=${item.actions.length}');
    const spinner = SizedBox(width: 14, height: 14,
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2));
    if (item.actions.length == 1) {
      final action = item.actions.first;
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: isResponding ? null : () => _respondSupplier(item, action, alsoIds: groupIds),
          style: FilledButton.styleFrom(
            backgroundColor: _kGreen,
            disabledBackgroundColor: _kGreen.withValues(alpha: 0.4),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(vertical: 11),
          ),
          child: isResponding ? spinner : Text(action.label,
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
              onPressed: isResponding ? null : () => _respondSupplier(item, action, alsoIds: groupIds),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD97706),
                disabledBackgroundColor: const Color(0xFFFDE68A),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
              child: isResponding ? spinner : Text(action.label,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          );
        } else {
          return OutlinedButton(
            onPressed: isResponding ? null : () => _respondSupplier(item, action, alsoIds: groupIds),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kText,
              side: const BorderSide(color: Color(0xFFE5E7EB)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            child: Text(action.label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          );
        }
      }).toList(),
    );
  }

}
