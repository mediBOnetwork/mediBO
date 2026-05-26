import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/cart_model.dart';
import '../util.dart';
import '../widgets/animations.dart';

class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final orders = cart.orders;

    if (orders.isEmpty) {
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

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      physics: platformScrollPhysics(),
      itemCount: orders.length,
      itemBuilder: (context, i) => _OrderCard(order: orders[i]),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final Order order;
  const _OrderCard({required this.order});

  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

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
        title: Text(order.number,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${_date(order.placedAt)} · ${order.itemCount} packs'),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(rupees(order.grandTotal),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            _StatusChip(status: order.status),
          ],
        ),
        children: [
          for (final line in order.lines)
            ListTile(
              dense: true,
              title: Text(line.product.name),
              subtitle: Text('${rupees(line.product.b2bPrice)} × ${line.quantity}'),
              trailing: Text(rupees(line.lineTotal)),
            ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = status == 'Pending' ? Colors.orange : Colors.green;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(status,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
