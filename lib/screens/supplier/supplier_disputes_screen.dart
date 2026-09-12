import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/live_feed.dart';

import '../../services/fulfill_realtime.dart' show kC416;
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../widgets/fulfill_item_sheet.dart' show ProofThumbnail;
import '../admin/dispute/dispute_models.dart';

// CHANGE #671 gap 51: this screen carried its own ten-colour palette and its
// own copy of the hex parser. Both are gone — every colour is a `Ds` token, so
// ui_design_set() recolours the supplier dispute list with no deploy, and a
// backend-supplied "#RRGGBB" (active_colors / kind_colors / the return-note
// chip) is read by Ds.hex, the same parser the token layer itself uses.

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
  LiveFeedHandle? _rtChannel;
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
      // CHANGE #643: LiveFeed decides live-vs-poll from realtime_plan().
      LiveFeed.instance
          .watch(
            channelPrefix: 'supplier_disputes_189_${_actingSupplier ?? "self"}',
            tables: const ['supplier_disputes'],
            onChange: (_) {
              _rtDebounce?.cancel();
              _rtDebounce = Timer(const Duration(milliseconds: 250), () {
                if (mounted) _load();
              });
            },
          )
          .then((h) {
        if (!mounted) {
          h.dispose();
          return;
        }
        _rtChannel?.unsubscribe();
        _rtChannel = h;
        RenderLog.write('c189_realtime_subscribed',
            'supplier_disputes_channel_ok;acting=${_actingSupplier != null}');
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
          cf('supplier_disputes.confirm_body',
              {'product': item.productName, 'action': action.label}),
          style: Ds.t.body,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(c('supplier_disputes.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(c('supplier_disputes.confirm')),
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
        SnackBar(content: Text(
            cf('supplier_disputes.snack_recorded', {'result': result}))));
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
      return Center(
          child: CircularProgressIndicator(color: Ds.c.brand, strokeWidth: 2));
    }
    if (_error != null) {
      final isNoSupplier = _error == 'no_supplier';
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(isNoSupplier ? Icons.store_outlined : Icons.wifi_off_rounded,
                size: 48, color: Ds.c.textSecondary),
            SizedBox(height: Ds.space.x12),
            Text(isNoSupplier
                ? c('supplier_disputes.no_supplier')
                : c('supplier_disputes.load_failed'),
                style: Ds.t.subtitle.copyWith(color: Ds.c.textSecondary)),
            if (!isNoSupplier) ...[
              SizedBox(height: Ds.space.x8),
              Text(_error!, style: Ds.t.caption, textAlign: TextAlign.center),
              SizedBox(height: Ds.space.x16),
              FilledButton.icon(
                onPressed: _load,
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: Text(c('supplier_disputes.retry')),
              ),
            ],
          ]),
        ),
      );
    }
    if (_disputes.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle_outline_rounded, size: 48, color: Ds.c.brand),
          SizedBox(height: Ds.space.x12),
          Text(c('supplier_disputes.empty'),
              style: Ds.t.subtitle.copyWith(color: Ds.c.textSecondary)),
          SizedBox(height: Ds.space.x16),
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(c('supplier_disputes.refresh')),
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
      color: Ds.c.brand,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
            children: [
              // Acting-as banner
              if (_acting) ...[
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x8),
                  margin: EdgeInsets.only(bottom: Ds.space.x12),
                  decoration: BoxDecoration(
                    color: Ds.c.warningSoft,
                    borderRadius: Ds.r.rButton,
                    border: Border.all(color: Ds.c.warning),
                  ),
                  child: Row(children: [
                    Icon(Icons.admin_panel_settings_outlined,
                        size: 16, color: Ds.c.warning),
                    SizedBox(width: Ds.space.x8),
                    Expanded(
                      child: Text(
                        cf('supplier_disputes.viewing_as', {'name': _supplierName}),
                        style: Ds.t.caption.copyWith(
                            fontWeight: FontWeight.w600, color: Ds.c.warning),
                      ),
                    ),
                  ]),
                ),
              ],

              // Active section
              _sectionLabel(c('supplier_disputes.section_active'),
                  activeItems.length, active: true),
              SizedBox(height: Ds.space.x8),
              if (activeItems.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
                  child: Text(c('supplier_disputes.no_active'),
                      style: Ds.t.caption),
                )
              else
                ...activeItems.map((item) => Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x8),
                  child: _buildItemCard(item),
                )),

              // Closed section
              if (closedItems.isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                GestureDetector(
                  onTap: () => setState(() => _closedExpanded = !_closedExpanded),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      cf(
                        _closedExpanded
                            ? 'supplier_disputes.hide_closed'
                            : 'supplier_disputes.show_closed',
                        {'count': '${closedItems.length}'},
                      ),
                      style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600),
                    ),
                    SizedBox(width: Ds.space.x4),
                    AnimatedRotation(
                      turns: _closedExpanded ? 0.5 : 0.0,
                      duration: Ds.motion.sheet,
                      curve: Curves.easeInOutCubic,
                      child: Icon(Icons.keyboard_arrow_down_rounded,
                          size: 16, color: Ds.c.textSecondary),
                    ),
                  ]),
                ),
                AnimatedSize(
                  duration: Ds.motion.sheet,
                  curve: Curves.easeInOutCubic,
                  clipBehavior: Clip.antiAlias,
                  child: _closedExpanded
                      ? Padding(
                          padding: EdgeInsets.only(top: Ds.space.x8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: closedItems.map((item) => Padding(
                              padding: EdgeInsets.only(bottom: Ds.space.x8),
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
          color: active ? Ds.c.brand : Ds.c.textSecondary,
          shape: BoxShape.circle,
        ),
      ),
      SizedBox(width: Ds.space.x4),
      Text(label,
          style: Ds.t.caption.copyWith(
              fontWeight: FontWeight.w700,
              color: active ? Ds.c.text : Ds.c.textSecondary)),
      SizedBox(width: Ds.space.x4),
      Text(cf('supplier_disputes.section_count', {'count': '$count'}),
          style: Ds.t.caption),
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
    final activeBg = Ds.hex(activeColors?['bg'], Ds.c.bg);
    final activeFg = Ds.hex(activeColors?['fg'], Ds.c.textSecondary);
    final kindTagText = item.kindLabel;
    final kindTagBg = Ds.hex(item.kindColors?['bg'], Ds.c.bg);
    final kindTagFg = Ds.hex(item.kindColors?['fg'], Ds.c.textSecondary);

    RenderLog.write('c348_card', 'kind=${item.kind}');

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // (a) Header row: image + info
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: Ds.r.rButton,
            child: hasImage
                ? Image.network(item.imageUrl!, width: 60, height: 60,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _imagePlaceholder())
                : _imagePlaceholder(),
          ),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(item.productName.isNotEmpty ? item.productName : '—',
                        style: Ds.t.body.copyWith(
                            fontWeight: FontWeight.w700,
                            color: isActive ? Ds.c.text : Ds.c.textSecondary),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    // B1b: wrong_product_name
                    if ((item.wrongProductName ?? '').isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(cf('supplier_disputes.wrong_product',
                              {'name': '${item.wrongProductName}'}),
                          style: Ds.t.caption.copyWith(color: Ds.c.danger),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                    if (kindTagText.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: Ds.space.x4, vertical: Ds.space.x4),
                          decoration: BoxDecoration(
                              color: kindTagBg, borderRadius: Ds.r.rChip),
                          child: Text(kindTagText,
                              style: Ds.t.caption.copyWith(
                                  fontWeight: FontWeight.w700, color: kindTagFg)),
                        ),
                      ),
                    ],
                  ]),
                ),
                SizedBox(width: Ds.space.x4),
                // Backend-owned (supplier_my_disputes): active_colors, verbatim —
                // replaces the verbose "Awaiting supplier response" item_status_label pill.
                Builder(builder: (_) {
                  RenderLog.write('c362_badge', 'where=supplier,active=$isActive');
                  return Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x8, vertical: Ds.space.x4),
                    decoration: BoxDecoration(
                      color: activeBg,
                      borderRadius: Ds.r.rChip,
                    ),
                    child: Text(activeLabel,
                        style: Ds.t.caption.copyWith(
                            fontWeight: FontWeight.w700, color: activeFg)),
                  );
                }),
              ]),
              if ((item.disputeCode ?? '').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Builder(builder: (_) {
                  RenderLog.write('c317_dispute_id_shown', item.disputeCode!);
                  return Text(
                    item.disputeCode!,
                    style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                    ),
                  );
                }),
              ],
              if ((item.category ?? '').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(item.category!,
                    style: Ds.t.caption,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
              if ((item.company ?? '').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(item.company!,
                    style: Ds.t.caption,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ]),
          ),
        ]),

        // (c) Quantities table + "In dispute: N units"
        SizedBox(height: Ds.space.x12),
        _buildQtyTable(agg.orderedQty, agg.receivedQty, agg.disputedQty, item.packType),
        if (agg.disputedQty > 0) ...[
          SizedBox(height: Ds.space.x4),
          Text(
              cf(
                agg.lines.length > 1
                    ? 'supplier_disputes.in_dispute_multi'
                    : 'supplier_disputes.in_dispute',
                {
                  'units': '${agg.disputedQty.toInt()}',
                  'orders': '${agg.lines.length}',
                },
              ),
              style: Ds.t.caption.copyWith(
                  fontWeight: FontWeight.w600, color: Ds.c.warning)),
        ],

        // Proof photo thumbnail
        if ((item.proofUrl ?? '').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Row(children: [
            Text(c('supplier_disputes.proof_photo'),
                style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600)),
            SizedBox(width: Ds.space.x8),
            ProofThumbnail(proofUrl: item.proofUrl!, size: 72),
          ]),
        ],

        // (d) item_status_label badge — hidden while awaiting (meaningless to supplier)
        if (!item.isAwaitingSupplier) ...[
          SizedBox(height: Ds.space.x8),
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
          SizedBox(height: Ds.space.x8),
          Builder(builder: (_) {
            final chip = item.returnNoteChip!;
            RenderLog.write('c348_return_chip', 'open=${chip.isOpen}');
            return Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x8, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                  color: Ds.hex(chip.bg, Ds.c.bg),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  chip.labelCard,
                  style: Ds.t.caption.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Ds.hex(chip.fg, Ds.c.textSecondary),
                  ),
                ),
              ),
            );
          }),
        ],

        // Supplier action buttons (item.actions only). C362 point-8: a response fans out to
        // every underlying order-line of this aggregated product.
        if (item.actions.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          _buildSupplierButtons(item, isResponding, agg.allActiveDisputeIds),
        ],
      ]),
    );
  }

  Widget _imagePlaceholder() => Container(
    width: 60, height: 60,
    decoration: BoxDecoration(
      color: Ds.c.bg,
      borderRadius: Ds.r.rButton,
    ),
    child: Icon(Icons.medication_outlined, size: 28, color: Ds.c.divider),
  );

  Widget _buildQtyTable(num ordered, num received, num short, String? packType) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Ds.c.divider),
        borderRadius: Ds.r.rButton,
      ),
      child: Column(children: [
        IntrinsicHeight(
          child: Row(children: [
            _qtyCell(c('supplier_disputes.qty_ordered'), isHeader: true, isAmber: false),
            _vertDivider(),
            _qtyCell(c('supplier_disputes.qty_received'), isHeader: true, isAmber: false),
            _vertDivider(),
            _qtyCell(c('supplier_disputes.qty_missing'), isHeader: true, isAmber: true),
          ]),
        ),
        Divider(height: 1, color: Ds.c.divider),
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
        padding: EdgeInsets.symmetric(
            vertical: Ds.space.x8, horizontal: Ds.space.x4),
        color: isAmber && !isHeader ? Ds.c.warningSoft : null,
        child: Text(text, textAlign: TextAlign.center,
          style: Ds.t.caption.copyWith(
            fontWeight: (isHeader || isBold) ? FontWeight.w700 : FontWeight.w400,
            color: isAmber
                ? Ds.c.warning
                : (isHeader ? Ds.c.textSecondary : Ds.c.text),
          ),
        ),
      ),
    );
  }

  Widget _vertDivider() =>
      VerticalDivider(width: 1, color: Ds.c.divider, thickness: 1);

  // Supplier buttons from item.actions
  Widget _buildSupplierButtons(DisputeItem item, bool isResponding, List<String> groupIds) {
    RenderLog.write('c189_supplier_buttons_rendered',
        'dispute=${item.disputeId};count=${item.actions.length}');
    RenderLog.write('c348_actions', 'n=${item.actions.length}');
    final spinner = SizedBox(width: 14, height: 14,
        child: CircularProgressIndicator(color: Ds.c.surface, strokeWidth: 2));
    if (item.actions.length == 1) {
      final action = item.actions.first;
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: isResponding ? null : () => _respondSupplier(item, action, alsoIds: groupIds),
          style: FilledButton.styleFrom(
            backgroundColor: Ds.c.brand,
            disabledBackgroundColor: Ds.c.brand.withValues(alpha: 0.4),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
          ),
          child: isResponding ? spinner : Text(action.label,
              style: Ds.t.caption.copyWith(
                  fontWeight: FontWeight.w700, color: Ds.c.surface)),
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
            padding: EdgeInsets.only(bottom: Ds.space.x4),
            child: FilledButton(
              onPressed: isResponding ? null : () => _respondSupplier(item, action, alsoIds: groupIds),
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.warning,
                disabledBackgroundColor: Ds.c.warningSoft,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
              ),
              child: isResponding ? spinner : Text(action.label,
                  style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w700, color: Ds.c.surface)),
            ),
          );
        } else {
          return OutlinedButton(
            onPressed: isResponding ? null : () => _respondSupplier(item, action, alsoIds: groupIds),
            style: OutlinedButton.styleFrom(
              foregroundColor: Ds.c.text,
              side: BorderSide(color: Ds.c.divider),
              shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
            ),
            child: Text(action.label,
                style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600)),
          );
        }
      }).toList(),
    );
  }

}
