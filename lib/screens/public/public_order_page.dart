import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/ist_date.dart';
import '../../utils/render_log.dart';
import '../../widgets/order_item_card.dart';

const _kGreen       = Color(0xFF1B7A43);
const _kBg          = Color(0xFFF5F6F8);
const _kCard        = Color(0xFFFFFFFF);
const _kBorder      = Color(0xFFE5E7EB);
const _kTextPrimary = Color(0xFF111827);
const _kTextMuted   = Color(0xFF6B7280);

class PublicOrderPage extends StatefulWidget {
  final String token;
  const PublicOrderPage({super.key, required this.token});

  @override
  State<PublicOrderPage> createState() => _PublicOrderPageState();
}

class _PublicOrderPageState extends State<PublicOrderPage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _order;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await Supabase.instance.client
          .rpc('get_supplier_order_by_token', params: {'p_token': widget.token}) as List;
      if (rows.isEmpty) {
        setState(() { _loading = false; _error = 'Order not found.'; });
        return;
      }
      final data = Map<String, dynamic>.from(rows.first as Map);
      final rawItems = data['items'];
      final parsedItems = rawItems is List
          ? rawItems.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : <Map<String, dynamic>>[];
      setState(() {
        _order = data;
        _items = parsedItems;
        _loading = false;
      });
      RenderLog.write('c188_order_page_loaded', 'true');
      RenderLog.write('c189_order_page_shared_card', 'true');
      RenderLog.write('c189_order_page_items', parsedItems.length);
    } catch (e) {
      setState(() { _loading = false; _error = 'Failed to load order: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kGreen,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text('mediBO Order',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _kGreen))
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 15)))
              : _buildContent(),
    );
  }

  Widget _buildContent() {
    final order = _order!;
    final supplierName = order['supplier_name'] as String? ?? '—';
    final orderNo      = order['order_no']?.toString() ?? '—';
    final status       = (order['status']       as String? ?? '').toLowerCase();
    final createdAt    = order['created_at']    as String?;
    final dateStr = createdAt != null ? _formatDate(createdAt) : '—';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              _headerCard(supplierName, orderNo, status, dateStr),
              const SizedBox(height: 16),
              const Text('Items', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kTextPrimary)),
              const SizedBox(height: 8),
              if (_items.isEmpty)
                const Text('No items.', style: TextStyle(color: _kTextMuted))
              else
                ..._items.map((item) => OrderItemCard(item: item)),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerCard(String supplier, String orderNo, String status, String date) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(supplier,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _kTextPrimary))),
          _statusChip(status),
        ]),
        const SizedBox(height: 6),
        Text('Order #$orderNo', style: const TextStyle(fontSize: 13, color: _kTextMuted)),
        const SizedBox(height: 4),
        Text(date, style: const TextStyle(fontSize: 13, color: _kTextMuted)),
      ]),
    );
  }

  Widget _statusChip(String status) {
    Color bg; Color fg;
    if (status == 'confirmed' || status == 'delivered' || status == 'accepted') {
      bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46);
    } else if (status == 'cancelled' || status == 'rejected') {
      bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B);
    } else {
      bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(status.isEmpty ? 'pending' : status,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  String _formatDate(String iso) {
    try {
      final dt = istFromDb(iso);
      return '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}';
    } catch (_) {
      return iso;
    }
  }
}
