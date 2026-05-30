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
  final String? externalSearchQuery;
  const CartScreen({super.key, this.onOrderPlaced, this.externalSearchQuery});

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
    final amount = cart.netPayable;
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
            amount: rupees(order.netPayable),
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
      'total_amount': order.netPayable,
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
                            child: _ItemList(
                              cart: cart,
                              externalSearchQuery:
                                  widget.externalSearchQuery,
                            ),
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
            Expanded(
              child: _ItemList(
                cart: cart,
                externalSearchQuery: widget.externalSearchQuery,
                showBreakdown: true,
              ),
            ),
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

class _ItemList extends StatefulWidget {
  final CartModel cart;
  final String? externalSearchQuery;
  final bool showBreakdown;
  const _ItemList({required this.cart, this.externalSearchQuery, this.showBreakdown = false});

  @override
  State<_ItemList> createState() => _ItemListState();
}

class _ItemListState extends State<_ItemList> {
  String get _effectiveQuery =>
      widget.externalSearchQuery ?? '';

  List<CartLine> get _filteredLines {
    final q = _effectiveQuery.trim().toLowerCase();
    if (q.isEmpty) return widget.cart.lines;
    return widget.cart.lines.where((l) {
      final name = l.product.name.toLowerCase();
      final generic = l.product.genericName.toLowerCase();
      final mfr = l.product.manufacturer.toLowerCase();
      return name.contains(q) || generic.contains(q) || mfr.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredLines;
    final searchActive = _effectiveQuery.trim().isNotEmpty;

    return ListView(
      physics: platformScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      cacheExtent: 400,
      children: [
        // ── No results message ──
        if (searchActive && filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.search_off,
                      size: 40, color: Color(0xFF9CA3AF)),
                  const SizedBox(height: 12),
                  Text(
                    'No ${_effectiveQuery.trim()} were added in cart',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF374151),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          for (final line in filtered)
            _CartItemCard(line: line, cart: widget.cart),
        // ── Billing breakdown (scrolls with products, narrow layout only) ──
        if (widget.showBreakdown && !searchActive) ...[
          const SizedBox(height: 4),
          _BillingBreakdownSection(cart: widget.cart),
        ],
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
    final discPct = cartDiscountPercent(cart.mrpTotal);
    final salePrice = p.mrp * (1 - discPct / 100);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── TOP ROW: image | name + pack size + manufacturer | remove ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ProductImage(product: p, size: 64),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: Color(0xFF111827),
                                height: 1.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: () => cart.remove(p),
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: const Color(0xFFD1D5DB)),
                                color: const Color(0xFFF9FAFB),
                              ),
                              child: const Center(
                                child: Icon(Icons.close,
                                    size: 11, color: Color(0xFF6B7280)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        p.packSize.isNotEmpty ? p.packSize : '—',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF374151),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        p.manufacturer,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                      if (line.isSample) ...[
                        const SizedBox(height: 3),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF7ED),
                            borderRadius: BorderRadius.circular(4),
                            border:
                                Border.all(color: const Color(0xFFFED7AA)),
                          ),
                          child: const Text('sample',
                              style: TextStyle(
                                  fontSize: 9, color: Color(0xFFEA580C))),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // ── BOTTOM ROW: MRP/price/GST (left) | qty selector (right) ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Left: struck MRP, sale price, GST badge
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (p.mrp > 0 && discPct > 0)
                      Text(
                        'MRP ${rupees(p.mrp)}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9CA3AF),
                          decoration: TextDecoration.lineThrough,
                          decorationColor: Color(0xFF9CA3AF),
                        ),
                      ),
                    if (discPct > 0) const SizedBox(height: 2),
                    Text(
                      rupees(salePrice),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                        height: 1.1,
                      ),
                    ),
                    if (p.gstPercent > 0) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF9C3),
                          borderRadius: BorderRadius.circular(4),
                          border:
                              Border.all(color: const Color(0xFFFDE047)),
                        ),
                        child: Text(
                          '${p.gstPercent.toStringAsFixed(0)}% GST (${rupees(salePrice * p.gstPercent / 100)} input credit)',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF854D0E),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const Spacer(),
                // Right: qty stepper (unchanged — 150×56, 3-zone)
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
    );
  }
}

// ─── Product image with category-icon fallback ────────────────────────────────

class _ProductImage extends StatelessWidget {
  final Product product;
  final double size;
  const _ProductImage({required this.product, this.size = 64});

  @override
  Widget build(BuildContext context) {
    final style = categoryStyle(product.therapeuticClass);
    final iconSize = size * 0.45;
    final radius = size * 0.125;
    final Widget fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Icon(style.icon, size: iconSize,
          color: style.fg.withValues(alpha: 0.6)),
    );

    if (product.imageUrl.isEmpty) return fallback;

    final cache = (size * 2).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        color: const Color(0xFFF9FAFB),
        child: Image.network(
          product.imageUrl,
          width: size,
          height: size,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          cacheWidth: cache,
          cacheHeight: cache,
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
      height: 56,
      child: Stack(
        children: [
          // Visual layer
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Minus visual
                  const SizedBox(
                    width: 44,
                    child: Center(
                      child: Text(
                        '−',
                        style: TextStyle(
                          color: Color(0xFF1a1a1a),
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          height: 1,
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
                                  fontSize: 15,
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
                  // Plus visual — green right side
                  Container(
                    width: 44,
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
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Invisible 3-zone tap overlay
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Zone 1: minus (44px)
                SizedBox(
                  width: 44,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.cart.decrement(widget.product),
                    ),
                  ),
                ),
                // Zone 2: center display (no action)
                const Expanded(child: SizedBox()),
                // Zone 3: plus (44px)
                SizedBox(
                  width: 44,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.cart.increment(widget.product),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Billing breakdown section (scrolls with products) ───────────────────────

class _BillingBreakdownSection extends StatelessWidget {
  final CartModel cart;
  const _BillingBreakdownSection({required this.cart});

  @override
  Widget build(BuildContext context) {
    final discPct = cartDiscountPercent(cart.mrpTotal);
    final discAmt = cart.mrpTotal * discPct / 100;
    final netTaxable = cart.mrpTotal - discAmt;
    final deliveryFee = cartDeliveryFee(cart.mrpTotal);
    final gstAmt = cart.netPayable - deliveryFee - netTaxable;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x06000000), blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Price Breakdown',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF6B7280),
                letterSpacing: 0.3),
          ),
          const SizedBox(height: 10),
          _bRow('Net Total', rupees(cart.mrpTotal)),
          const SizedBox(height: 6),
          _bRow(
            'Discount (${discPct.toStringAsFixed(0)}%)',
            '− ${rupees(discAmt)}',
            valueColor: const Color(0xFF16A34A),
          ),
          const SizedBox(height: 6),
          _bRow(
            'GST Input Credit',
            rupees(gstAmt),
            valueColor: const Color(0xFFD97706),
          ),
          const SizedBox(height: 6),
          _bRow(
            'Delivery Fee',
            deliveryFee > 0 ? rupees(deliveryFee) : 'FREE',
            valueColor: deliveryFee == 0 ? const Color(0xFF16A34A) : null,
          ),
        ],
      ),
    );
  }

  Widget _bRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFF374151))),
        Text(value,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: valueColor ?? const Color(0xFF374151))),
      ],
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Pinned Net Payable row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Net Payable Amount',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827),
                      ),
                    ),
                    Text(
                      rupees(cart.netPayable),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // View bill + Make Payment
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => _showBill(context),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
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
                              Icon(Icons.payment_rounded,
                                  color: Colors.white, size: 18),
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showBill(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final h = MediaQuery.of(ctx).size.height;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: h * 0.92),
          child: _GstBillView(cart: cart),
        );
      },
    );
  }
}

// ─── GST-categorized bill view ────────────────────────────────────────────────

class _GstBillView extends StatelessWidget {
  final CartModel cart;
  const _GstBillView({required this.cart});

  static const String _estimateNote =
      'Please note that all prices, quantities, taxes, shipping charges, and '
      'other details shown on the website are estimates only. We will send you '
      'the actual bill when we process your order, which will include the final '
      'amount along with other details such as batch number, expiry date, and '
      'any additional information. The final invoice will be considered the '
      'binding amount.';

  @override
  Widget build(BuildContext context) {
    final lines = cart.lines;

    // MRP total — single source of truth for discount tier (matches cart bar)
    final totalMrp = cart.mrpTotal;
    final discPct = cartDiscountPercent(totalMrp);

    // Group lines by GST rate, ascending
    final Map<int, List<CartLine>> groups = {};
    for (final l in lines) {
      groups.putIfAbsent(l.product.gstPercent.toInt(), () => []).add(l);
    }
    final sortedRates = groups.keys.toList()..sort();

    // Pre-compute each group's Final Payable for the summary section
    final Map<int, double> finalPayables = {};
    for (final rate in sortedRates) {
      final gLines = groups[rate]!;
      final net =
          gLines.fold(0.0, (s, l) => s + l.product.mrp * l.quantity);
      final disc = net * discPct / 100;
      final taxable = net - disc;
      finalPayables[rate] = taxable + taxable * rate / 100;
    }
    final deliveryFee = cartDeliveryFee(totalMrp);
    // Use the shared CartModel getter as the single source of truth
    final grandTotal = cart.netPayable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Fixed header ──
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Bill Details',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                color: const Color(0xFF6B7280),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        if (discPct > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '${discPct.toStringAsFixed(0)}% discount applied '
              '(cart MRP value ${rupees(totalMrp)})',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF16A34A),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),

        // ── Scrollable body ──
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // GST groups in ascending order
                for (final rate in sortedRates) ...[
                  _GstGroup(
                    rate: rate,
                    lines: groups[rate]!,
                    discPct: discPct,
                  ),
                  const SizedBox(height: 16),
                ],

                // Summary card
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x08000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header bar
                      Container(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                        decoration: const BoxDecoration(
                          color: Color(0xFFF9FAFB),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(11),
                            topRight: Radius.circular(11),
                          ),
                        ),
                        child: const Text(
                          'ORDER SUMMARY',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF6B7280),
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      const Divider(height: 1, color: Color(0xFFE5E7EB)),

                      // Per-GST-group rows
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                        child: Column(
                          children: [
                            for (final rate in sortedRates)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 7),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF0FDF4),
                                            borderRadius:
                                                BorderRadius.circular(4),
                                            border: Border.all(
                                                color:
                                                    const Color(0xFFBBF7D0)),
                                          ),
                                          child: Text(
                                            '$rate% GST',
                                            style: const TextStyle(
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF15803D),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const Text(
                                          'products',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF6B7280),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      rupees(finalPayables[rate]!),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF374151),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                            // Delivery Fee row
                            Padding(
                              padding: const EdgeInsets.only(bottom: 7),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.local_shipping_outlined,
                                          size: 13, color: Color(0xFF9CA3AF)),
                                      SizedBox(width: 6),
                                      Text(
                                        'Delivery Fee',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF6B7280),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    deliveryFee > 0
                                        ? rupees(deliveryFee)
                                        : 'FREE',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: deliveryFee == 0
                                          ? const Color(0xFF16A34A)
                                          : const Color(0xFF374151),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14),
                        child: Divider(height: 1, color: Color(0xFFE5E7EB)),
                      ),

                      // Net Payable Amount — prominent highlighted row
                      Container(
                        margin: const EdgeInsets.all(12),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFECFDF5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFBBF7D0)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'NET PAYABLE AMOUNT',
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF15803D),
                                    letterSpacing: 0.6,
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  'incl. GST + delivery',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Color(0xFF6EE7B7),
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              rupees(grandTotal),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF065F46),
                                height: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Estimate note box
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFD1D5DB)),
                  ),
                  child: const Text(
                    _estimateNote,
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6B7280),
                      height: 1.55,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── GST group card (table layout) ───────────────────────────────────────────

class _GstGroup extends StatelessWidget {
  final int rate;
  final List<CartLine> lines;
  final double discPct;
  const _GstGroup(
      {required this.rate, required this.lines, required this.discPct});

  static const double _mrpW = 62.0;
  static const double _qtyW = 30.0;
  static const double _amtW = 74.0;
  static const double _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final netAmount =
        lines.fold(0.0, (s, l) => s + l.product.mrp * l.quantity);
    final discountAmount = netAmount * discPct / 100;
    final netTaxable = netAmount - discountAmount;
    final gstAmount = netTaxable * rate / 100;
    final finalPayable = netTaxable + gstAmount;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Group header bar ──────────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: const BoxDecoration(
              color: Color(0xFFF0FDF4),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(11),
                topRight: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16A34A),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'GST $rate%',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${lines.length} product${lines.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // ── Column header row ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'PRODUCT',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF9CA3AF),
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                SizedBox(
                  width: _mrpW,
                  child: const Text(
                    'MRP',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF9CA3AF),
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: _qtyW,
                  child: const Text(
                    'QTY',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF9CA3AF),
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: _amtW,
                  child: const Text(
                    'AMOUNT',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF9CA3AF),
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Divider(height: 1, color: Color(0xFFE5E7EB)),
          ),

          // ── Product rows (zebra-striped, single-line names) ───────────
          for (int i = 0; i < lines.length; i++)
            Container(
              decoration: BoxDecoration(
                color: i.isEven ? const Color(0xFFF9FAFB) : Colors.white,
                border: i < lines.length - 1
                    ? const Border(
                        bottom: BorderSide(color: Color(0xFFF0F0F0)))
                    : null,
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      lines[i].product.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF111827),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _mrpW,
                    child: Text(
                      rupees(lines[i].product.mrp),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                  const SizedBox(width: _gap),
                  SizedBox(
                    width: _qtyW,
                    child: Text(
                      '${lines[i].quantity}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                  const SizedBox(width: _gap),
                  SizedBox(
                    width: _amtW,
                    child: Text(
                      rupees(lines[i].product.mrp * lines[i].quantity),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Group totals ──────────────────────────────────────────────
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Divider(height: 1, color: Color(0xFFE5E7EB)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Column(
              children: [
                _totRow('Net Amount', rupees(netAmount)),
                _totRow(
                  'Discount (${discPct.toStringAsFixed(0)}%)',
                  '− ${rupees(discountAmount)}',
                  valueColor: const Color(0xFF16A34A),
                ),
                _totRow('Net Taxable Amount', rupees(netTaxable),
                    bold: true),
                _totRow(
                  'GST $rate%',
                  '+ ${rupees(gstAmount)}',
                  valueColor: const Color(0xFFD97706),
                ),
              ],
            ),
          ),

          // ── Final Payable Amount (highlighted) ────────────────────────
          Container(
            margin: const EdgeInsets.all(12),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: const Color(0xFFECFDF5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFBBF7D0)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Final Payable Amount',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF065F46),
                  ),
                ),
                Text(
                  rupees(finalPayable),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF065F46),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _totRow(String label, String value,
      {bool bold = false, Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
              color: bold
                  ? const Color(0xFF111827)
                  : const Color(0xFF6B7280),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              color: valueColor ??
                  (bold
                      ? const Color(0xFF111827)
                      : const Color(0xFF374151)),
            ),
          ),
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
    final discPct = cartDiscountPercent(cart.mrpTotal);
    final deliveryFee = cartDeliveryFee(cart.mrpTotal);
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
          _row('Net Total', rupees(cart.mrpTotal)),
          _row(
            'Discount (${discPct.toStringAsFixed(0)}%)',
            '− ${rupees(cart.mrpTotal * discPct / 100)}',
            valueColor: const Color(0xFF16A34A),
          ),
          _row(
            'GST Input Credit',
            rupees(cart.netPayable - deliveryFee - cart.mrpTotal * (1 - discPct / 100)),
            valueColor: const Color(0xFFD97706),
          ),
          _row(
            'Delivery Fee',
            deliveryFee > 0 ? rupees(deliveryFee) : 'FREE',
            valueColor: deliveryFee == 0 ? const Color(0xFF16A34A) : null,
          ),
          const Divider(height: 24),
          _row('Net Payable Amount', rupees(cart.netPayable), bold: true),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => _showBillDialog(context),
            child: const Text(
              'View detailed bill →',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF1D4ED8),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 14),
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
          if (deliveryFee == 0)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF0FDF4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFBBF7D0)),
              ),
              child: const Row(
                children: [
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
            )
          else
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFED7AA)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.local_shipping_outlined,
                      size: 15, color: Color(0xFFEA580C)),
                  const SizedBox(width: 7),
                  Text(
                    'Add ₹${(999 - cart.mrpTotal).ceil()} more for free delivery',
                    style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9A3412),
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

  Widget _row(String label, String value,
      {bool bold = false, Color? valueColor}) {
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
                color: valueColor ??
                    (bold
                        ? const Color(0xFF111827)
                        : const Color(0xFF374151)),
              )),
        ],
      ),
    );
  }

  void _showBillDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Colors.white,
        child: SizedBox(
          width: 620,
          height: MediaQuery.of(context).size.height * 0.85,
          child: _GstBillView(cart: cart),
        ),
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
