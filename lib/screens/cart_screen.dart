import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/cart_model.dart';
import '../models/product.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/animations.dart';

class CartScreen extends StatelessWidget {
  final VoidCallback? onOrderPlaced;
  const CartScreen({super.key, this.onOrderPlaced});

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);

    if (cart.lines.isEmpty) {
      return const _EmptyCart();
    }

    final wide = MediaQuery.of(context).size.width >= 760;
    final banner = cart.hasSampleItems ? _SampleBanner(cart: cart) : null;

    if (wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (banner != null) banner,
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: _ItemList(cart: cart, scrollable: true),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: _OrderSummary(
                            cart: cart, onOrderPlaced: onOrderPlaced),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Narrow: items + summary scroll together; Place Order pinned at bottom.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (banner != null) banner,
        Expanded(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                _ItemList(cart: cart, scrollable: false),
                _SummaryCard(cart: cart),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ),
        _PlaceOrderBar(cart: cart, onOrderPlaced: onOrderPlaced),
      ],
    );
  }
}

// ─── Sample banner ────────────────────────────────────────────────────────────

class _SampleBanner extends StatelessWidget {
  final CartModel cart;
  const _SampleBanner({required this.cart});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xFFFFF7ED),
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, color: Color(0xFFEA580C), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Sample products added. Auto-removed in ${cart.sampleCountdown}s.',
              style: const TextStyle(fontSize: 13, color: Color(0xFF9A3412)),
            ),
          ),
          TextButton(
            onPressed: cart.clearSampleItems,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFEA580C),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Dismiss',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ─── Item list wrapper ────────────────────────────────────────────────────────

class _ItemList extends StatelessWidget {
  final CartModel cart;
  final bool scrollable;
  const _ItemList({required this.cart, required this.scrollable});

  @override
  Widget build(BuildContext context) {
    final lines = cart.lines;
    if (scrollable) {
      return ListView.builder(
        physics: platformScrollPhysics(),
        itemCount: lines.length,
        itemBuilder: (_, i) => _CartItemCard(line: lines[i], cart: cart),
      );
    }
    // Non-scrollable: render as Column inside parent SingleChildScrollView
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final line in lines) _CartItemCard(line: line, cart: cart),
      ],
    );
  }
}

// ─── Cart item card ───────────────────────────────────────────────────────────

class _CartItemCard extends StatelessWidget {
  final CartLine line;
  final CartModel cart;
  const _CartItemCard({required this.line, required this.cart});

  @override
  Widget build(BuildContext context) {
    final p = line.product;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Product image / fallback — 64×64
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 64,
              height: 64,
              child: p.imageUrl.isNotEmpty
                  ? Image.network(
                      p.imageUrl,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      loadingBuilder: (_, child, progress) =>
                          progress == null ? child : _imgFallback(p),
                      errorBuilder: (_, _, _) => _imgFallback(p),
                    )
                  : _imgFallback(p),
            ),
          ),
          const SizedBox(width: 12),

          // Content — takes all remaining width
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Product name + optional sample badge
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        p.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                    if (line.isSample) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7ED),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: const Color(0xFFFED7AA)),
                        ),
                        child: const Text('sample',
                            style: TextStyle(
                                fontSize: 10, color: Color(0xFFEA580C))),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  p.manufacturer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w500),
                ),
                if (p.packSize.isNotEmpty)
                  Text(
                    p.packSize,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF9CA3AF)),
                  ),
                const SizedBox(height: 10),

                // Bottom row: stepper | price | delete
                Row(
                  children: [
                    _CartStepper(
                      qty: line.quantity,
                      onDecrement: () => cart.decrement(p),
                      onIncrement: () => cart.increment(p),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        rupees(line.lineTotal),
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => cart.remove(p),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.delete_outline,
                            size: 20, color: Color(0xFF9CA3AF)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _imgFallback(Product p) {
    final style = categoryStyle(p.therapeuticClass);
    return Container(
      color: style.bg,
      alignment: Alignment.center,
      child: Icon(style.icon, size: 28, color: style.fg.withValues(alpha: 0.5)),
    );
  }
}

// ─── Compact cart stepper ─────────────────────────────────────────────────────

class _CartStepper extends StatelessWidget {
  final int qty;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  const _CartStepper({
    required this.qty,
    required this.onDecrement,
    required this.onIncrement,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Minus
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onDecrement,
              child: const SizedBox(
                width: 32,
                height: 32,
                child: Center(
                  child: Icon(Icons.remove, size: 16, color: Color(0xFF374151)),
                ),
              ),
            ),
          ),
          // Divider
          Container(width: 1, height: 32, color: const Color(0xFFE5E7EB)),
          // Quantity
          SizedBox(
            width: 38,
            height: 32,
            child: Center(
              child: Text(
                '$qty',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: Color(0xFF111827),
                ),
              ),
            ),
          ),
          // Divider
          Container(width: 1, height: 32, color: const Color(0xFFE5E7EB)),
          // Plus
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onIncrement,
              child: const SizedBox(
                width: 32,
                height: 32,
                child: Center(
                  child: Icon(Icons.add, size: 16, color: Color(0xFF374151)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Order summary card — rows only (narrow layout) ───────────────────────────

class _SummaryCard extends StatelessWidget {
  final CartModel cart;
  const _SummaryCard({required this.cart});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Order summary',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          _row('Items', '${cart.distinctItems} SKUs · ${cart.totalUnits} packs'),
          _row('Subtotal', rupees(cart.subtotal)),
          _row('GST (12%)', rupees(cart.totalGst)),
          const Divider(height: 20),
          _row('Grand total', rupees(cart.grandTotal), bold: true),
          const SizedBox(height: 6),
          Text(
            'Net 30 credit terms · Free delivery above ₹5,000',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
      fontSize: bold ? 15 : 13,
      color: bold ? const Color(0xFF111827) : const Color(0xFF374151),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(value, style: style),
        ],
      ),
    );
  }
}

// ─── Fixed bottom Place Order bar (narrow layout) ─────────────────────────────

class _PlaceOrderBar extends StatelessWidget {
  final CartModel cart;
  final VoidCallback? onOrderPlaced;
  const _PlaceOrderBar({required this.cart, this.onOrderPlaced});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () => _checkout(context),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF16A34A),
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            elevation: 0,
          ),
          icon: const Icon(Icons.local_shipping_outlined, size: 18),
          label: Text(
            'Place Order · ${rupees(cart.grandTotal)}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  void _checkout(BuildContext context) {
    final cart = AppState.of(context);
    final order = cart.checkout();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text('Order ${order.number} placed · ${rupees(order.grandTotal)}'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    onOrderPlaced?.call();
  }
}

// ─── Order summary with button (wide layout sidebar) ─────────────────────────

class _OrderSummary extends StatelessWidget {
  final CartModel cart;
  final VoidCallback? onOrderPlaced;
  const _OrderSummary({required this.cart, this.onOrderPlaced});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Order summary', style: theme.textTheme.titleMedium),
          const SizedBox(height: 14),
          _row('Items',
              '${cart.distinctItems} SKUs · ${cart.totalUnits} packs'),
          _row('Subtotal', rupees(cart.subtotal)),
          _row('GST (12%)', rupees(cart.totalGst)),
          const Divider(height: 24),
          _row('Grand total', rupees(cart.grandTotal), bold: true),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              final order = cart.checkout();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      'Order ${order.number} placed · ${rupees(order.grandTotal)}'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
              onOrderPlaced?.call();
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            icon: const Icon(Icons.local_shipping_outlined, size: 18),
            label: const Text('Place purchase order',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 10),
          Text(
            'Net 30 credit terms · Free delivery above ₹5,000',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
      fontSize: bold ? 15 : 13,
      color: bold ? const Color(0xFF111827) : const Color(0xFF374151),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(value, style: style),
        ],
      ),
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────────

class _EmptyCart extends StatelessWidget {
  const _EmptyCart();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.shopping_cart_outlined,
              size: 80, color: Theme.of(context).hintColor),
          const SizedBox(height: 16),
          const Text(
            'Your cart is empty',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Color(0xFF374151)),
          ),
          const SizedBox(height: 6),
          Text(
            'Add products from the catalog to start an order.',
            style: TextStyle(
                fontSize: 13, color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }
}
