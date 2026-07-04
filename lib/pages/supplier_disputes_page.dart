// [S1] Supplier portal — disputes tab.
// Loads supplier_my_disputes RPC; renders DisputeCard list; responds via supplier_respond_dispute.

import 'package:flutter/material.dart';
import '../screens/admin/dispute/dispute_models.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';
import '../widgets/dispute_card.dart';

const _kGreen = Color(0xFF1B7A43);
const _kSub   = Color(0xFF6B7280);
const _kText  = Color(0xFF111827);

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
  bool _closedExpanded = false;
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

  Future<void> _respond(String disputeId, String code) async {
    if (_responding[disputeId] == true) return;
    setState(() => _responding[disputeId] = true);
    try {
      final res = await supplierRespondDisputeRpc(
        disputeId: disputeId,
        response: code,
        actingSupplier: widget.viewAsSupplierName,
      );
      if (!mounted) return;
      // c350_responded: emitted from _respond handler on success
      RenderLog.write('c350_responded', 'code=$code');
      final msg = res['result']?.toString() ?? 'Recorded';
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
      if (mounted) setState(() => _responding.remove(disputeId));
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

    final active = _disputes.where((d) => d.isActive).toList();
    final closed = _disputes.where((d) => !d.isActive).toList();

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

              // Active section
              _sectionLabel('Active', active.length, isActive: true),
              const SizedBox(height: 8),
              if (active.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No active disputes.',
                      style: TextStyle(fontSize: 13, color: _kSub)),
                )
              else
                ...active.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DisputeCard(
                    item: item,
                    onRespond: _respond,
                    isResponding: _responding[item.disputeId] == true,
                  ),
                )),

              // Closed section (collapsible)
              if (closed.isNotEmpty) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => setState(() => _closedExpanded = !_closedExpanded),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      _closedExpanded
                          ? 'Hide closed (${closed.length})'
                          : 'Show closed (${closed.length})',
                      style: const TextStyle(fontSize: 13, color: _kSub,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _closedExpanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeInOutCubic,
                      child: const Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: _kSub),
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
                            children: closed.map((item) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: DisputeCard(item: item), // read-only
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

  Widget _sectionLabel(String title, int count, {required bool isActive}) {
    return Row(children: [
      Text(title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFFFEE2E2) : const Color(0xFFF1F3F4),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text('$count',
            style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700,
              color: isActive ? const Color(0xFFDC2626) : _kSub,
            )),
      ),
    ]);
  }
}
