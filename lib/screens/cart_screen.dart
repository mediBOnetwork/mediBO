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
                        child: _ItemList(cart: cart),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: _OrderSummaryPanel(
                          cart: cart,
                          onOrderPlaced: onOrderPlaced,
                        ),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (banner != null) banner,
        Expanded(child: _ItemList(cart: cart)),
        _CheckoutBar(cart: cart, onOrderPlaced: onOrderPlaced),
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

// ─── Item list ────────────────────────────────────────────────────────────────

class _ItemList extends StatelessWidget {
  final CartModel cart;
  const _ItemList({required this.cart});

  @override
  Widget build(BuildContext context) {
    final lines = cart.lines;
    return ListView.builder(
      physics: platformScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: lines.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              '${cart.distinctItems} item${cart.distinctItems == 1 ? '' : 's'} in your cart',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF374151),
              ),
            ),
          );
        }
        return _CartItemCard(line: lines[i - 1], cart: cart);
      },
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
    final discountPct =
        p.mrp > 0 ? ((p.mrp - p.b2bPrice) / p.mrp * 100).round() : 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Top: image + name + remove ──
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ProductImage(product: p),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 2),
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
                                height: 1.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () => cart.remove(p),
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: const Color(0xFFD1D5DB)),
                                color: const Color(0xFFF9FAFB),
                              ),
                              child: const Center(
                                child: Icon(Icons.close,
                                    size: 13, color: Color(0xFF6B7280)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        p.manufacturer,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                      if (line.isSample) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF7ED),
                            borderRadius: BorderRadius.circular(4),
                            border:
                                Border.all(color: const Color(0xFFFED7AA)),
                          ),
                          child: const Text('sample',
                              style: TextStyle(
                                  fontSize: 10, color: Color(0xFFEA580C))),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1, thickness: 1, color: Color(0xFFF3F4F6)),

          // ── Bottom: pricing + qty selector ──
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // MRP + discount %
                if (p.mrp > 0 && discountPct > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Text(
                          'MRP ${rupees(p.mrp)}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF9CA3AF),
                            decoration: TextDecoration.lineThrough,
                            decorationColor: Color(0xFF9CA3AF),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '$discountPct% OFF',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF16A34A),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Sale price + /pack
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      rupees(p.b2bPrice),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(width: 5),
                    const Text(
                      '/pack',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Pack size pill + qty dropdown
                Row(
                  children: [
                    if (p.packSize.isNotEmpty)
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3F4F6),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            p.packSize,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF6B7280),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      )
                    else
                      const SizedBox(),
                    const Spacer(),
                    _QtyDropdown(
                      qty: line.quantity,
                      onChanged: (v) => cart.setQuantity(p, v),
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
}

// ─── Product image with category-icon fallback ────────────────────────────────

class _ProductImage extends StatelessWidget {
  final Product product;
  const _ProductImage({required this.product});

  @override
  Widget build(BuildContext context) {
    final style = categoryStyle(product.therapeuticClass);
    final Widget fallback = Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Icon(style.icon, size: 36,
          color: style.fg.withValues(alpha: 0.6)),
    );

    if (product.imageUrl.isEmpty) return fallback;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 80,
        height: 80,
        color: const Color(0xFFF9FAFB),
        child: Image.network(
          product.imageUrl,
          width: 80,
          height: 80,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          cacheWidth: 160,
          cacheHeight: 160,
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : fallback,
          errorBuilder: (_, __, ___) => fallback,
        ),
      ),
    );
  }
}

// ─── Quantity dropdown pill ───────────────────────────────────────────────────

class _QtyDropdown extends StatelessWidget {
  final int qty;
  final ValueChanged<int> onChanged;
  const _QtyDropdown({required this.qty, required this.onChanged});

  static const _blue = Color(0xFF1D4ED8);

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      initialValue: qty,
      onSelected: onChanged,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.white,
      elevation: 8,
      offset: const Offset(0, -8),
      constraints: const BoxConstraints(minWidth: 100),
      itemBuilder: (_) => [
        for (int i = 1; i <= 12; i++)
          PopupMenuItem<int>(
            value: i,
            height: 40,
            child: Text(
              'Qty: $i',
              style: TextStyle(
                fontSize: 13,
                fontWeight: i == qty ? FontWeight.w700 : FontWeight.w400,
                color: i == qty ? _blue : const Color(0xFF111827),
              ),
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: _blue,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Qty: $qty',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_down,
                color: Colors.white, size: 16),
          ],
        ),
      ),
    );
  }
}

// ─── Fixed checkout bar (narrow layout) ──────────────────────────────────────

class _CheckoutBar extends StatelessWidget {
  final CartModel cart;
  final VoidCallback? onOrderPlaced;
  const _CheckoutBar({required this.cart, this.onOrderPlaced});

  static const _navy = Color(0xFF1E3A5F);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Total + "View bill" link
          GestureDetector(
            onTap: () => _showBill(context),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  rupees(cart.grandTotal),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                  ),
                ),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'View bill',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF1D4ED8),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(width: 2),
                    Icon(Icons.keyboard_arrow_up,
                        size: 14, color: Color(0xFF1D4ED8)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          // "Add delivery details" button
          Expanded(
            child: GestureDetector(
              onTap: () => _checkout(context),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 15),
                decoration: BoxDecoration(
                  color: _navy,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Add delivery details',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showBill(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      backgroundColor: Colors.white,
      builder: (_) => _BillSheet(cart: cart),
    );
  }

  void _checkout(BuildContext context) {
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

// ─── Bill bottom sheet ────────────────────────────────────────────────────────

class _BillSheet extends StatelessWidget {
  final CartModel cart;
  const _BillSheet({required this.cart});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD1D5DB),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Bill details',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111827)),
          ),
          const SizedBox(height: 16),
          _billRow('Subtotal', rupees(cart.subtotal)),
          _billRow('GST (12%)', rupees(cart.totalGst)),
          const Divider(height: 24),
          _billRow('Grand total', rupees(cart.grandTotal), bold: true),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDF4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFBBF7D0)),
            ),
            child: Row(
              children: const [
                Icon(Icons.local_shipping_outlined,
                    size: 16, color: Color(0xFF16A34A)),
                SizedBox(width: 8),
                Text(
                  'Free delivery on this order',
                  style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF15803D),
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Net 30 credit terms apply',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
          ),
        ],
      ),
    );
  }

  Widget _billRow(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                fontSize: bold ? 15 : 13,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                color: bold
                    ? const Color(0xFF111827)
                    : const Color(0xFF374151),
              )),
          Text(value,
              style: TextStyle(
                fontSize: bold ? 15 : 13,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                color: bold
                    ? const Color(0xFF111827)
                    : const Color(0xFF374151),
              )),
        ],
      ),
    );
  }
}

// ─── Order summary sidebar (wide layout) ─────────────────────────────────────

class _OrderSummaryPanel extends StatelessWidget {
  final CartModel cart;
  final VoidCallback? onOrderPlaced;
  const _OrderSummaryPanel({required this.cart, this.onOrderPlaced});

  static const _navy = Color(0xFF1E3A5F);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Bill details',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111827)),
          ),
          const SizedBox(height: 16),
          _row('Items',
              '${cart.distinctItems} SKU${cart.distinctItems == 1 ? '' : 's'} · ${cart.totalUnits} packs'),
          _row('Subtotal', rupees(cart.subtotal)),
          _row('GST (12%)', rupees(cart.totalGst)),
          const Divider(height: 24),
          _row('Grand total', rupees(cart.grandTotal), bold: true),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () {
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
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 15),
              decoration: BoxDecoration(
                color: _navy,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Add delivery details',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDF4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFBBF7D0)),
            ),
            child: Row(
              children: const [
                Icon(Icons.local_shipping_outlined,
                    size: 15, color: Color(0xFF16A34A)),
                SizedBox(width: 7),
                Text(
                  'Free delivery on this order',
                  style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF15803D),
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Net 30 credit terms apply',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                fontSize: bold ? 15 : 13,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                color: bold
                    ? const Color(0xFF111827)
                    : const Color(0xFF374151),
              )),
          Text(value,
              style: TextStyle(
                fontSize: bold ? 15 : 13,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                color: bold
                    ? const Color(0xFF111827)
                    : const Color(0xFF374151),
              )),
        ],
      ),
    );
  }
}

// ─── Empty cart ───────────────────────────────────────────────────────────────

class _EmptyCart extends StatelessWidget {
  const _EmptyCart();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(48),
            ),
            child: const Icon(Icons.shopping_cart_outlined,
                size: 48, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 20),
          const Text(
            'Your cart is empty',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827)),
          ),
          const SizedBox(height: 8),
          const Text(
            'Add products from the catalog to start an order.',
            style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }
}
