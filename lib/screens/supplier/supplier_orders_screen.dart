import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const _kWideBreakpoint = 900.0;

const Map<String, List<Color>> _kClassColors = {
  'CARDIAC':            [Color(0xFFFAECE7), Color(0xFF993C1D)],
  'NEURO CNS':          [Color(0xFFEEEDFE), Color(0xFF534AB7)],
  'GASTRO INTESTINAL':  [Color(0xFFE1F5EE), Color(0xFF0F6E56)],
  'ANTI INFECTIVES':    [Color(0xFFE6F1FB), Color(0xFF0C447C)],
  'PAIN ANALGESICS':    [Color(0xFFFAECE7), Color(0xFF993C1D)],
  'DERMA':              [Color(0xFFFBEAF0), Color(0xFF993556)],
  'GYNAECOLOGICAL':     [Color(0xFFFBEAF0), Color(0xFF993556)],
  'RESPIRATORY':        [Color(0xFFE1F5EE), Color(0xFF0F6E56)],
};
const _kDefaultClassBg = Color(0xFFF1EFE8);
const _kDefaultClassFg = Color(0xFF2C2C2A);

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
  String? _expandedOrderId; // which order card is open
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
      final params = sid != null
          ? <String, dynamic>{'p_supplier_id': sid}
          : <String, dynamic>{};
      final rows = await Supabase.instance.client
          .rpc('supplier_my_orders', params: params);
      if (!mounted) return;

      final list = (rows as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // Preserve expansion; if new order arrived at top, expand it
      String? newExpanded = _expandedOrderId;
      if (_firstLoad) {
        newExpanded = list.isNotEmpty ? (list.first['order_id'] as String?) : null;
      } else if (list.isNotEmpty) {
        final topId = list.first['order_id'] as String?;
        final existingIds = _orders.map((o) => o['order_id'] as String?).toSet();
        if (topId != null && !existingIds.contains(topId)) {
          // Brand-new order arrived — expand it
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
      if (newExpanded != null) RenderLog.write('supplier_orders_expanded', newExpanded);
    } catch (e) {
      RenderLog.write('supplier_orders_error', e.toString().length > 80
          ? e.toString().substring(0, 80) : e.toString());
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

    return LayoutBuilder(builder: (context, outerConstraints) {
      RenderLog.write('supplier_orders_vp_w', outerConstraints.maxWidth.toInt());
      return ListView.builder(
        padding: EdgeInsets.all(outerConstraints.maxWidth >= 900 ? 24 : 12),
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
    final orderNo     = order['order_no']     as String? ?? '';
    final totalAmount = (order['total_amount'] as num?)?.toDouble();
    final itemCount   = (order['item_count']  as num?)?.toInt() ?? 0;
    final createdAt   = order['created_at'] != null
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
          // ── Header (always visible) ──────────────────────────────────────
          InkWell(
            borderRadius: isOpen
                ? const BorderRadius.vertical(top: Radius.circular(12))
                : BorderRadius.circular(12),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(children: [
                // Order number + date
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
                // Right side: amount + item count + status + chevron
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (totalAmount != null && totalAmount > 0) ...[
                    Text(
                      '₹${totalAmount % 1 == 0 ? totalAmount.toInt() : totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827),
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

          // ── Expanded body: item list ─────────────────────────────────────
          if (isOpen) ...[
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: items.isEmpty
                  ? const Text('No items.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)))
                  : Column(
                      children: items
                          .map((item) => _OrderItemCard(item: item))
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
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
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

// ── Order item card (inquiry-style) ──────────────────────────────────────────

class _OrderItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  const _OrderItemCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final productName = (item['product_name'] as String? ?? '').trim();
    final tc          = (item['therapeutic_class'] as String? ?? '').trim().toUpperCase();
    final company     = (item['company'] as String? ?? '').trim();
    final imageUrl    = item['image_url'] as String?;
    final qty         = (item['quantity'] as num?)?.toInt() ?? 0;

    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth >= _kWideBreakpoint;
      return isWide
          ? _buildWide(productName, tc, company, imageUrl, qty)
          : _buildNarrow(productName, tc, company, imageUrl, qty);
    });
  }

  Widget _buildWide(String name, String tc, String company, String? imageUrl, int qty) {
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildImageTile(imageUrl, 72),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF111827),
                    ),
                  ),
                  if (tc.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    _buildClassPill(tc),
                  ],
                  if (company.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      company,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 18),
            _buildQtyPill(qty),
          ],
        ),
      ),
    );
  }

  Widget _buildNarrow(String name, String tc, String company, String? imageUrl, int qty) {
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
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildImageTile(imageUrl, 88),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF111827),
                          height: 1.3,
                        ),
                      ),
                      if (tc.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _buildClassPill(tc),
                      ],
                      if (company.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          company,
                          style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildQtyPill(qty),
          ],
        ),
      ),
    );
  }

  Widget _buildQtyPill(int qty) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Text(
        'Qty $qty',
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF1E40AF),
        ),
      ),
    );
  }

  Widget _buildImageTile(String? imageUrl, double size) {
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          imageUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _pillIconBox(size),
        ),
      );
    }
    return _pillIconBox(size);
  }

  Widget _pillIconBox(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6F8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.medication_outlined, size: 28, color: Color(0xFFD1D5DB)),
    );
  }

  Widget _buildClassPill(String tc) {
    final colors = _kClassColors[tc];
    final bg = colors != null ? colors[0] : _kDefaultClassBg;
    final fg = colors != null ? colors[1] : _kDefaultClassFg;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        tc,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}
