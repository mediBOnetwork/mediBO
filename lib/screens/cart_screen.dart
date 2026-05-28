import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_state.dart';
import '../models/cart_model.dart';
import '../models/product.dart';
import '../services/payment_service.dart';
import '../theme.dart';
import '../user_state.dart';
import '../util.dart';
import '../widgets/animations.dart';
import 'auth/login_screen.dart';

class CartScreen extends StatefulWidget {
  final VoidCallback? onOrderPlaced;
  const CartScreen({super.key, this.onOrderPlaced});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  bool _paymentInProgress = false;

  Future<void> _openPayment() async {
    if (_paymentInProgress) return;

    // TODO: RE-ENABLE LOGIN CHECK BEFORE LAUNCH
    // DISABLED FOR NOW - RE-ENABLE LATER
    // // Require login before payment
    // final auth = UserState.read(context);
    // if (!auth.isAuthenticated) {
    //   final goLogin = await showDialog<bool>(
    //     context: context,
    //     builder: (ctx) => AlertDialog(
    //       shape: RoundedRectangleBorder(
    //           borderRadius: BorderRadius.circular(16)),
    //       title: const Text('Login required',
    //           style: TextStyle(fontWeight: FontWeight.w700)),
    //       content: const Text(
    //         'Please log in to complete your purchase.',
    //         style: TextStyle(fontSize: 14),
    //       ),
    //       actions: [
    //         TextButton(
    //           onPressed: () => Navigator.pop(ctx, false),
    //           child: const Text('Cancel'),
    //         ),
    //         FilledButton(
    //           onPressed: () => Navigator.pop(ctx, true),
    //           style: FilledButton.styleFrom(
    //               backgroundColor: const Color(0xFF1B5E20)),
    //           child: const Text('Log In'),
    //         ),
    //       ],
    //     ),
    //   );
    //   if (goLogin != true || !mounted) return;
    //   await Navigator.push(
    //     context,
    //     MaterialPageRoute(builder: (_) => const LoginScreen()),
    //   );
    //   return; // User can retry payment after logging in
    // }

    setState(() => _paymentInProgress = true);
    final cart = AppState.of(context);
    final amount = cart.grandTotal;
    final profile = UserState.read(context).profile;

    try {
      final result = await PaymentService.initiatePayment(
        amount: amount,
        name: profile?.ownerName ?? '',
        email: '',
        phone: profile?.phone ?? '',
      );
      if (!mounted) return;

      final status = result['status'] ?? 'dismissed';

      if (status == 'success') {
        final order = cart.checkout();
        // Persist order to Supabase (fire-and-forget)
        _saveOrder(
          order: order,
          paymentId: result['payment_id'] ?? '',
          pharmacyName: profile?.pharmacyName ?? '',
          phone: profile?.phone ?? '',
          address: '${profile?.address ?? ''}, ${profile?.city ?? ''} ${profile?.pincode ?? ''}'.trim(),
        );
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => _PaymentSuccessDialog(
            paymentId: result['payment_id'] ?? '',
            orderNumber: order.number,
            amount: rupees(order.grandTotal),
            onDone: () {
              Navigator.of(context).pop();
              widget.onOrderPlaced?.call();
            },
          ),
        );
      } else if (status == 'failed') {
        showDialog(
          context: context,
          builder: (_) => _PaymentErrorDialog(
            message: result['description']?.isNotEmpty == true
                ? result['description']!
                : 'Payment could not be completed.',
            onRetry: () {
              Navigator.of(context).pop();
              _openPayment();
            },
            onCancel: () => Navigator.of(context).pop(),
          ),
        );
      }
      // 'dismissed' → user closed modal, no action needed
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Payment error: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _paymentInProgress = false);
    }
  }

  void _saveOrder({
    required Order order,
    required String paymentId,
    required String pharmacyName,
    required String phone,
    required String address,
  }) {
    final userId =
        Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    Supabase.instance.client.from('orders').insert({
      'user_id': userId,
      'pharmacy_name': pharmacyName,
      if (phone.isNotEmpty) 'phone': phone,
      if (address.isNotEmpty) 'address': address,
      'items': order.lines
          .map((l) => {
                'product_name': l.product.name,
                'quantity': l.quantity,
                'price': l.product.b2bPrice,
                'line_total': l.lineTotal,
              })
          .toList(),
      'total_amount': order.grandTotal,
      'payment_id': paymentId,
      'status': 'paid',
    }).then((_) {}).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);

    if (cart.lines.isEmpty) {
      return const _EmptyCart();
    }

    final banner = cart.hasSampleItems ? _SampleBanner(cart: cart) : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 600;

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
                              onMakePayment: _openPayment,
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
            _CheckoutBar(cart: cart, onMakePayment: _openPayment),
          ],
        );
      },
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
      cacheExtent: 400,
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
                    _CartStepper(
                      product: p,
                      quantity: line.quantity,
                      cart: cart,
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

// ─── Cart quantity stepper ────────────────────────────────────────────────────

class _CartStepper extends StatefulWidget {
  final Product product;
  final int quantity;
  final CartModel cart;
  const _CartStepper({
    required this.product,
    required this.quantity,
    required this.cart,
  });

  static String _unit(String packSize) {
    final s = packSize.toLowerCase();
    if (s.contains('strip')) return 'Strip';
    if (s.contains('bottle')) return 'Bottle';
    if (s.contains('vial')) return 'Vial';
    if (s.contains('tube')) return 'Tube';
    if (s.contains('sachet')) return 'Sachet';
    if (s.contains('box')) return 'Box';
    if (s.contains('ampoule') || s.contains('ampule')) return 'Ampoule';
    if (s.contains('pack')) return 'Pack';
    return 'Unit';
  }

  @override
  State<_CartStepper> createState() => _CartStepperState();
}

class _CartStepperState extends State<_CartStepper> {
  bool _increasing = true;

  @override
  void didUpdateWidget(_CartStepper old) {
    super.didUpdateWidget(old);
    if (widget.quantity != old.quantity) {
      _increasing = widget.quantity > old.quantity;
    }
  }

  @override
  Widget build(BuildContext context) {
    final unit = _CartStepper._unit(widget.product.packSize);
    final qty = widget.quantity;
    final increasing = _increasing;

    return SizedBox(
      width: 150,
      height: 40,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Minus button
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => widget.cart.decrement(widget.product),
                child: const SizedBox(
                  width: 40,
                  child: Center(
                    child: Text(
                      '−',
                      style: TextStyle(
                        color: Color(0xFF1a1a1a),
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Center: qty + unit with slide animation
            Expanded(
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRect(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: (child, anim) {
                          final isNew =
                              (child.key as ValueKey<int>).value == qty;
                          final begin = isNew
                              ? (increasing
                                  ? const Offset(0, -1)
                                  : const Offset(0, 1))
                              : (increasing
                                  ? const Offset(0, 1)
                                  : const Offset(0, -1));
                          return SlideTransition(
                            position: Tween<Offset>(
                                    begin: begin, end: Offset.zero)
                                .animate(anim),
                            child: child,
                          );
                        },
                        child: Text(
                          '$qty',
                          key: ValueKey<int>(qty),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1a1a1a),
                            fontSize: 14,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      unit,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF1a1a1a),
                        fontWeight: FontWeight.w600,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Plus button — green
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => widget.cart.increment(widget.product),
                child: Container(
                  width: 40,
                  decoration: const BoxDecoration(
                    color: Brand.green,
                    borderRadius: BorderRadius.only(
                      topRight: Radius.circular(7),
                      bottomRight: Radius.circular(7),
                    ),
                  ),
                  child: const Center(
                    child: Text(
                      '+',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Fixed checkout bar (narrow layout) ──────────────────────────────────────

class _CheckoutBar extends StatelessWidget {
  final CartModel cart;
  final VoidCallback onMakePayment;
  const _CheckoutBar({required this.cart, required this.onMakePayment});

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
          // Make Payment button
          Expanded(
            child: GestureDetector(
              onTap: onMakePayment,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 15),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B5E20),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.payment_rounded, color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Make Payment',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
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
  final VoidCallback onMakePayment;
  const _OrderSummaryPanel({required this.cart, required this.onMakePayment});

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
            onTap: onMakePayment,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 15),
              decoration: BoxDecoration(
                color: const Color(0xFF1B5E20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.payment_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Text(
                    'Make Payment',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
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

// ─── Payment dialogs ─────────────────────────────────────────────────────────

class _PaymentSuccessDialog extends StatelessWidget {
  final String paymentId;
  final String orderNumber;
  final String amount;
  final VoidCallback onDone;

  const _PaymentSuccessDialog({
    required this.paymentId,
    required this.orderNumber,
    required this.amount,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: Color(0xFFDCFCE7),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  color: Color(0xFF16A34A), size: 44),
            ),
            const SizedBox(height: 20),
            const Text(
              'Payment Successful!',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827)),
            ),
            const SizedBox(height: 8),
            Text(
              'Order #$orderNumber • $amount',
              style: const TextStyle(fontSize: 14, color: Color(0xFF374151)),
            ),
            if (paymentId.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Payment ID: $paymentId',
                style:
                    const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onDone,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1B5E20),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('View Orders',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentErrorDialog extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  const _PaymentErrorDialog({
    required this.message,
    required this.onRetry,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: Color(0xFFFEE2E2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.error_rounded,
                  color: Color(0xFFDC2626), size: 44),
            ),
            const SizedBox(height: 20),
            const Text(
              'Payment Failed',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827)),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, color: Color(0xFF6B7280), height: 1.4),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCancel,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: onRetry,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Retry',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ],
        ),
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
