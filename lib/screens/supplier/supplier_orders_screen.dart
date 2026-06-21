import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';
import '../../widgets/order_item_card.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

class SupplierOrdersScreen extends StatefulWidget {
  final String? viewAsSupplierId;
  const SupplierOrdersScreen({super.key, this.viewAsSupplierId});

  @override
  State<SupplierOrdersScreen> createState() => _SupplierOrdersScreenState();
}

class _SupplierOrdersScreenState extends State<SupplierOrdersScreen> {
  List<Map<String, dynamic>> _orders = [];
  bool _loading = false;
  bool _firstLoad = true;
  String? _expandedOrderId;
  RealtimeChannel? _rt;

  @override
  void initState() {
    super.initState();
    _fetch(source: 'init');
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _rt?.unsubscribe();
    super.dispose();
  }

  void _subscribeRealtime() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _rt = Supabase.instance.client
        .channel('sup_orders_rt_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'supplier_orders',
          callback: (_) => _fetch(source: 'realtime', silent: true),
        )
        .subscribe();
  }

  Future<void> _fetch({String source = 'manual', bool silent = false}) async {
    if (!mounted) return;
    if (!silent) setState(() => _loading = true);
    try {
      final sid = widget.viewAsSupplierId;
      // Pass p_supplier_id when acting-as (admin View As Supplier flow).
      // When null, the RPC resolves via current_supplier_profile().
      final params = sid != null
          ? <String, dynamic>{'p_supplier_id': sid}
          : <String, dynamic>{};
      final rows = await Supabase.instance.client
          .rpc('supplier_my_orders', params: params);
      if (!mounted) return;

      final list = (rows as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // On first load, auto-expand the newest (first) order.
      // On subsequent fetches, keep current expansion unless a new order arrived at top.
      String? newExpanded = _expandedOrderId;
      if (_firstLoad) {
        newExpanded = list.isNotEmpty ? (list.first['order_id'] as String?) : null;
      } else if (list.isNotEmpty) {
        final topId = list.first['order_id'] as String?;
        final existingIds = _orders.map((o) => o['order_id'] as String?).toSet();
        if (topId != null && !existingIds.contains(topId)) {
          newExpanded = topId;
        }
      }

      setState(() {
        _orders = list;
        _expandedOrderId = newExpanded;
        _firstLoad = false;
        _loading = false;
      });

      RenderLog.write('supplier_orders_rows', list.length);
      RenderLog.write('supplier_orders_src', source);
      if (list.isNotEmpty) {
        RenderLog.write('supplier_orders_first_no', list.first['order_no']?.toString() ?? '?');
      }
      if (newExpanded != null) RenderLog.write('supplier_orders_expanded', 'yes');
    } catch (e) {
      final msg = e.toString();
      RenderLog.write('supplier_orders_error', msg.length > 80 ? msg.substring(0, 80) : msg);
      if (mounted) setState(() { _loading = false; });
    }
  }

  void _toggleOrder(String orderId) {
    setState(() {
      _expandedOrderId = _expandedOrderId == orderId ? null : orderId;
    });
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('supplier_orders_screen_built', 1);

    // LayoutBuilder wraps the whole build so supplier_orders_vp_w is always stamped.
    return LayoutBuilder(builder: (context, constraints) {
      RenderLog.write('supplier_orders_vp_w', constraints.maxWidth.toInt());

      if (_loading && _firstLoad) {
        return const Center(
          child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
        );
      }

      if (_orders.isEmpty && !_loading) {
        return Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.receipt_long_outlined, size: 56, color: Color(0xFFD1D5DB)),
            const SizedBox(height: 12),
            const Text('No orders yet.',
                style: TextStyle(fontSize: 15, color: Color(0xFF6B7280))),
          ]),
        );
      }

      return ListView.builder(
        padding: EdgeInsets.all(constraints.maxWidth >= 900 ? 24 : 12),
        itemCount: _orders.length,
        itemBuilder: (context, i) {
          final order = _orders[i];
          final orderId = order['order_id'] as String? ?? '';
          final isOpen = _expandedOrderId == orderId;
          return _OrderCard(
            order: order,
            isOpen: isOpen,
            onToggle: () => _toggleOrder(orderId),
          );
        },
      );
    });
  }
}

// ── Order card (collapsible) ──────────────────────────────────────────────────

class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final bool isOpen;
  final VoidCallback onToggle;

  const _OrderCard({required this.order, required this.isOpen, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    // order_no is integer in DB
    final orderNo    = order['order_no']?.toString() ?? '';
    final totalAmount = (order['total_amount'] as num?)?.toDouble();
    final itemCount  = (order['item_count'] as num?)?.toInt() ?? 0;
    final createdAt  = order['created_at'] != null
        ? DateTime.tryParse(order['created_at'] as String)?.toLocal()
        : null;
    final items = (order['items'] as List<dynamic>? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final status = order['status'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          InkWell(
            borderRadius: isOpen
                ? const BorderRadius.vertical(top: Radius.circular(12))
                : BorderRadius.circular(12),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        orderNo.isNotEmpty ? 'Order $orderNo' : 'Order',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827),
                        ),
                      ),
                      if (createdAt != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          _formatDate(createdAt),
                          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                        ),
                      ],
                    ],
                  ),
                ),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (totalAmount != null && totalAmount > 0) ...[
                    Text(
                      '₹${totalAmount % 1 == 0 ? totalAmount.toInt() : totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (itemCount > 0) ...[
                    Text(
                      '$itemCount item${itemCount == 1 ? '' : 's'}',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (status.isNotEmpty) ...[
                    _StatusBadge(status: status),
                    const SizedBox(width: 8),
                  ],
                  Icon(
                    isOpen
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: const Color(0xFF6B7280),
                    size: 22,
                  ),
                ]),
              ]),
            ),
          ),

          // ── Expanded body ────────────────────────────────────────────────────
          if (isOpen) ...[
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: items.isEmpty
                  ? const Text('No items.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)))
                  : Column(
                      children: items
                          .map((item) => OrderItemCard(item: item))
                          .toList(),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    var h = dt.hour % 12;
    if (h == 0) h = 12;
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]}, $h:$m $ampm';
  }
}

// ── Status badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg, fg;
    switch (status.toLowerCase()) {
      case 'pending':   bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E); break;
      case 'accepted':  bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46); break;
      case 'rejected':  bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B); break;
      case 'completed': bg = const Color(0xFFEFF6FF); fg = const Color(0xFF1E40AF); break;
      default:          bg = const Color(0xFFF3F4F6); fg = const Color(0xFF6B7280);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        status,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

