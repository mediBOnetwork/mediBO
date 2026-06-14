import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';
import '../../utils/toast.dart';

class SupplierOrdersScreen extends StatefulWidget {
  final String? viewAsSupplierId;
  const SupplierOrdersScreen({super.key, this.viewAsSupplierId});

  @override
  State<SupplierOrdersScreen> createState() => _SupplierOrdersScreenState();
}

class _SupplierOrdersScreenState extends State<SupplierOrdersScreen> {
  List<Map<String, dynamic>> _orders = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
    try {
      final viewAsSupplierId = widget.viewAsSupplierId;
      final query = Supabase.instance.client
          .from('supplier_orders')
          .select();
      final res = await (viewAsSupplierId != null
          ? query.eq('supplier_id', viewAsSupplierId)
          : query)
          .order('created_at', ascending: false) as List;
      if (mounted) {
        setState(() {
          _orders = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
        });
        RenderLog.write('supplier_orders_rows', _orders.length);
      }
    } catch (e) {
      RenderLog.write('supplier_orders_error', e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _updateStatus(String orderId, String status) async {
    try {
      await Supabase.instance.client
          .from('supplier_orders')
          .update({'status': status})
          .eq('id', orderId);
      if (mounted) showToast(context, 'Order $status');
      await _fetch();
    } catch (e) {
      if (mounted) showToast(context, 'Failed: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43)));
    }

    if (_orders.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.receipt_long_outlined, size: 56, color: Color(0xFFD1D5DB)),
          const SizedBox(height: 12),
          const Text('No orders yet.', style: TextStyle(fontSize: 15, color: Color(0xFF6B7280))),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _fetch,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF1B7A43),
              side: const BorderSide(color: Color(0xFF1B7A43)),
            ),
          ),
        ]),
      );
    }

    return RefreshIndicator(
      color: const Color(0xFF1B7A43),
      onRefresh: _fetch,
      child: ListView(
        padding: EdgeInsets.all(isDesktop ? 24 : 12),
        children: [
          Row(children: [
            Text('${_orders.length} order${_orders.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _fetch,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
              style: TextButton.styleFrom(foregroundColor: const Color(0xFF1B7A43)),
            ),
          ]),
          const SizedBox(height: 8),
          ..._orders.map((order) => _OrderCard(
            order: order,
            onUpdateStatus: _updateStatus,
          )),
        ],
      ),
    );
  }
}

// ── Order card ────────────────────────────────────────────────────────────────

class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final Future<void> Function(String orderId, String status) onUpdateStatus;

  const _OrderCard({required this.order, required this.onUpdateStatus});

  @override
  Widget build(BuildContext context) {
    final id          = order['id']           as String? ?? '';
    final status      = order['status']       as String? ?? 'pending';
    final totalAmount = (order['total_amount'] as num?)?.toDouble();
    final description = order['description']  as String?;
    final createdAt   = order['created_at'] != null
        ? DateTime.tryParse(order['created_at'] as String)?.toLocal()
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [BoxShadow(
          color: Color(0x08000000), blurRadius: 4, offset: Offset(0, 2),
        )],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('Order #${id.length > 8 ? id.substring(0, 8) : id}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
            ),
          ),
          _statusBadge(status),
        ]),
        if (createdAt != null) ...[
          const SizedBox(height: 4),
          Text(_formatDate(createdAt),
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
        ],
        if (description != null && description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(description,
            style: const TextStyle(fontSize: 13, color: Color(0xFF374151)),
          ),
        ],
        if (totalAmount != null) ...[
          const SizedBox(height: 8),
          Text('Total: ₹${totalAmount.toStringAsFixed(2)}',
            style: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827),
            ),
          ),
        ],
        if (status == 'pending') ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => onUpdateStatus(id, 'accepted'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF065F46),
                  side: const BorderSide(color: Color(0xFF6EE7B7)),
                ),
                child: const Text('Accept'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: () => onUpdateStatus(id, 'rejected'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF991B1B),
                  side: const BorderSide(color: Color(0xFFFCA5A5)),
                ),
                child: const Text('Reject'),
              ),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _statusBadge(String status) {
    Color bg, fg;
    switch (status) {
      case 'pending':   bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E); break;
      case 'accepted':  bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46); break;
      case 'rejected':  bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B); break;
      case 'completed': bg = const Color(0xFFEFF6FF); fg = const Color(0xFF1E40AF); break;
      default:          bg = const Color(0xFFF3F4F6); fg = const Color(0xFF6B7280);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}  '
           '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }
}
