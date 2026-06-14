import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../util.dart';
import '../utils/render_log.dart';
import '../widgets/animations.dart';

// ─── Data models ─────────────────────────────────────────────────────────────

class _DbOrder {
  final String id;
  final String number;  // payment_id (PO-YYMMDD-XXXX); falls back to '—'
  final DateTime placedAt;
  final List<_DbLine> lines;
  final double total;
  final String status; // DB value capitalized: Pending / Confirmed / etc.
  final bool placedByAdmin;

  _DbOrder({
    required this.id,
    required this.number,
    required this.placedAt,
    required this.lines,
    required this.total,
    required this.status,
    this.placedByAdmin = false,
  });

  factory _DbOrder.fromRow(Map<String, dynamic> row) {
    final id = row['id'] as String;
    final paymentId = (row['payment_id'] as String?) ?? '';
    final items = (row['items'] as List<dynamic>?) ?? [];
    final rawStatus = ((row['status'] as String?) ?? 'pending').trim();
    final status = rawStatus.isNotEmpty
        ? rawStatus[0].toUpperCase() + rawStatus.substring(1)
        : 'Pending';
    return _DbOrder(
      id: id,
      number: paymentId.isNotEmpty ? paymentId : '—',
      placedAt: DateTime.parse(row['created_at'] as String).toLocal(),
      lines: items
          .map((item) => _DbLine.fromJson(item as Map<String, dynamic>))
          .toList(),
      total: (row['total_amount'] as num?)?.toDouble() ?? 0.0,
      status: status,
      placedByAdmin: (row['placed_by_admin'] as bool?) ?? false,
    );
  }

  int get itemCount => lines.fold(0, (s, l) => s + l.quantity);
}

class _DbLine {
  final String name;
  final double price;
  final int quantity;
  final double lineTotal;

  const _DbLine({
    required this.name,
    required this.price,
    required this.quantity,
    required this.lineTotal,
  });

  factory _DbLine.fromJson(Map<String, dynamic> j) {
    final price = (j['price'] as num?)?.toDouble() ?? 0.0;
    final qty = (j['quantity'] as num?)?.toInt() ?? 1;
    return _DbLine(
      name: (j['product_name'] as String?) ?? '',
      price: price,
      quantity: qty,
      lineTotal: (j['line_total'] as num?)?.toDouble() ?? price * qty,
    );
  }
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class OrdersScreen extends StatefulWidget {
  // When set (View As Customer), fetch orders for this user_id instead of currentUser.
  final String? viewAsUserId;
  // Increment to force a re-fetch (used after write-as order placement).
  final int refreshSignal;
  const OrdersScreen({super.key, this.viewAsUserId, this.refreshSignal = 0});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<_DbOrder> _orders = [];
  bool _loading = true;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _fetch();
    _subscribeRealtime();
  }

  @override
  void didUpdateWidget(OrdersScreen old) {
    super.didUpdateWidget(old);
    if (widget.refreshSignal != old.refreshSignal ||
        widget.viewAsUserId != old.viewAsUserId) {
      _fetch();
    }
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      // viewAsUserId is set when super-admin is previewing a customer's orders.
      final uid = widget.viewAsUserId
          ?? Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final rows = await Supabase.instance.client
          .from('orders')
          .select()
          .eq('user_id', uid)
          .order('created_at', ascending: false);
      if (!mounted) return;
      final parsed = rows.map((r) => _DbOrder.fromRow(r)).toList();
      RenderLog.write('orders_fetched',
          'count:${parsed.length}${widget.viewAsUserId != null ? ':viewas' : ''}');
      setState(() {
        _orders = parsed;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _subscribeRealtime() {
    if (widget.viewAsUserId != null) return; // no realtime in view-as mode
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    _channel = Supabase.instance.client
        .channel('customer_orders_$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: uid,
          ),
          callback: (_) => _fetch(),
        )
        .subscribe();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined,
                size: 64, color: Theme.of(context).hintColor),
            const SizedBox(height: 12),
            const Text('No purchase orders yet'),
            const SizedBox(height: 4),
            Text('Placed orders will appear here.',
                style: TextStyle(color: Theme.of(context).hintColor)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        physics: platformScrollPhysics(),
        itemCount: _orders.length,
        itemBuilder: (context, i) => _OrderCard(order: _orders[i]),
      ),
    );
  }
}

// ─── Order card ───────────────────────────────────────────────────────────────

class _OrderCard extends StatelessWidget {
  final _DbOrder order;
  const _OrderCard({required this.order});

  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year}  '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.receipt_long,
              color: theme.colorScheme.onPrimaryContainer),
        ),
        // Primary label: human-readable PO number (payment_id)
        title: Text(order.number,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${_date(order.placedAt)} · ${order.itemCount} packs'),
            if (order.placedByAdmin) ...[
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('Placed by admin',
                    style: TextStyle(
                        fontSize: 10,
                        color: Color(0xFF92400E),
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(rupees(order.total),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            _StatusChip(status: order.status),
          ],
        ),
        children: [
          for (final line in order.lines)
            ListTile(
              dense: true,
              title: Text(line.name),
              subtitle: Text('${rupees(line.price)} × ${line.quantity}'),
              trailing: Text(rupees(line.lineTotal)),
            ),
        ],
      ),
    );
  }
}

// ─── Status chip ──────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final lower = status.toLowerCase();
    final color = switch (lower) {
      'accepted' || 'confirmed' => Colors.green,
      'cancelled' || 'rejected' => Colors.red,
      _ => Colors.orange, // pending, processing, etc.
    };
    final label = switch (lower) {
      'accepted' || 'confirmed' => 'Accepted',
      'cancelled' => 'Cancelled',
      'rejected' => 'Rejected',
      'pending' => 'Pending',
      _ => status[0].toUpperCase() + status.substring(1),
    };
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
