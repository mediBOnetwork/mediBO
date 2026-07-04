// [S1] Supplier portal — disputes tab.
// Loads supplier_my_disputes RPC; renders DisputeCard list; responds via supplier_respond_dispute.

import 'package:flutter/material.dart';
import '../screens/admin/dispute/dispute_models.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';
import '../widgets/dispute_card.dart';

const _kGreen = Color(0xFF1B7A43);
const _kSub   = Color(0xFF6B7280);

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
      String msg = 'Recorded';
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
      return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
    if (_error != null) {
      final noSup = _error == 'no_supplier';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(noSup ? Icons.store_outlined : Icons.wifi_off_rounded, size: 48, color: _kSub),
            const SizedBox(height: 12),
            Text(
              noSup ? 'No supplier account found.' : 'Unable to load disputes.',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kSub),
            ),
            if (!noSup) ...[
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
          const Text('No disputes 🎉',
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
      color: _kGreen,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              // View-As banner
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
                      child: Text('Viewing as $_supplierName (admin)',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                              color: Color(0xFF92400E))),
                    ),
                  ]),
                ),
              ],

              // Item-wise rows (active first); Active/Inactive badge per row.
              ...rows.map((agg) {
                final busy = agg.allActiveDisputeIds.any((id) => _responding[id] == true);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
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
