// [S1] Supplier portal — disputes tab.
// Loads supplier_my_disputes RPC; renders DisputeCard list; responds via supplier_respond_dispute.

import 'package:flutter/material.dart';
import '../design_tokens.dart';
import '../screens/admin/dispute/dispute_models.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';
import '../widgets/dispute_card.dart';

class SupplierDisputesPage extends StatefulWidget {
  // View-As support: supply non-null to act as that supplier name.
  final String? viewAsSupplierName;
  // Badge callback: called with count of active+actionable disputes after each load.
  final ValueChanged<int>? onActiveCount;

  const SupplierDisputesPage({
    super.key,
    this.viewAsSupplierName,
    this.onActiveCount,
  });

  @override
  State<SupplierDisputesPage> createState() => _SupplierDisputesPageState();
}

class _SupplierDisputesPageState extends State<SupplierDisputesPage> {
  bool _loading = true;
  String? _error;
  List<DisputeItem> _disputes = [];
  String _supplierName = '';
  bool _acting = false;
  final Map<String, bool> _responding = {};

  @override
  void initState() {
    super.initState();
    // c350_ready: emitted from real initState of SupplierDisputesPage
    RenderLog.write('c350_ready', 'page=s1');
    _load();
  }

  @override
  void didUpdateWidget(SupplierDisputesPage old) {
    super.didUpdateWidget(old);
    if (old.viewAsSupplierName != widget.viewAsSupplierName) _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final result = await fetchSupplierDisputesList(
          actingSupplier: widget.viewAsSupplierName);
      if (!mounted) return;
      _acting = result.acting;
      _supplierName = result.supplier;
      final active = result.items
          .where((d) => d.isActive && d.actions.isNotEmpty)
          .length;
      widget.onActiveCount?.call(active);
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

  // C363-F: item-wise response — a product row aggregates several order-line disputes, so
  // one action fans out to ALL active underlying dispute ids (mirrors DisputeFormScreen).
  Future<void> _respondAgg(AggregatedDispute agg, String code) async {
    final ids = agg.allActiveDisputeIds;
    if (ids.isEmpty || ids.any((id) => _responding[id] == true)) return;
    setState(() { for (final id in ids) { _responding[id] = true; } });
    try {
      String msg = c('supplier_disputes_page.recorded');
      for (final id in ids) {
        final res = await supplierRespondDisputeRpc(
          disputeId: id,
          response: code,
          actingSupplier: widget.viewAsSupplierName,
        );
        msg = res['result']?.toString() ?? msg;
      }
      if (!mounted) return;
      RenderLog.write('c350_responded', 'code=$code;n=${ids.length}');
      showToast(context, msg);
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) _load();
    } on DisputeException catch (e) {
      if (!mounted) return;
      showToast(context, e.message);
      if (mounted) _load();
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString().substring(0, e.toString().length.clamp(0, 80)));
    } finally {
      if (mounted) setState(() { for (final id in ids) { _responding.remove(id); } });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Center(
          child: CircularProgressIndicator(color: Ds.c.brand, strokeWidth: 2));
    }
    if (_error != null) {
      final noSup = _error == 'no_supplier';
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(noSup ? Icons.store_outlined : Icons.wifi_off_rounded,
                size: 48, color: Ds.c.textSecondary),
            SizedBox(height: Ds.space.x12),
            Text(
              noSup
                  ? c('supplier_disputes_page.no_supplier')
                  : c('supplier_disputes_page.load_failed'),
              style: Ds.t.subtitle.copyWith(color: Ds.c.textSecondary),
            ),
            if (!noSup) ...[
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
                label: Text(c('supplier_disputes_page.retry')),
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
          Text(c('supplier_disputes_page.empty'),
              style: Ds.t.subtitle.copyWith(color: Ds.c.textSecondary)),
          SizedBox(height: Ds.space.x16),
          TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(c('supplier_disputes_page.refresh')),
          ),
        ]),
      );
    }

    // C363-F: ITEM-WISE — one row per product (summed disputed qty), NO Active/Closed
    // sections; each row's Active(red)/Inactive(green) badge conveys status. Active first.
    final aggregated = aggregateDisputesByProduct(_disputes);
    final rows = [
      ...aggregated.where((a) => a.active),
      ...aggregated.where((a) => !a.active),
    ];
    RenderLog.write('c363_disp_group', 'where=supplier;items=${rows.length}');

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
              // View-As banner
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
                      child: Text(cf('supplier_disputes_page.viewing_as_admin', {'a': _supplierName}),
                          style: Ds.t.caption.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Ds.c.warning)),
                    ),
                  ]),
                ),
              ],

              // Item-wise rows (active first); Active/Inactive badge per row.
              ...rows.map((agg) {
                final busy = agg.allActiveDisputeIds.any((id) => _responding[id] == true);
                return Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x8),
                  child: DisputeCard(
                    item: agg.representative,
                    agg: agg,
                    onRespond: agg.active ? (_, code) => _respondAgg(agg, code) : null,
                    isResponding: busy,
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}
