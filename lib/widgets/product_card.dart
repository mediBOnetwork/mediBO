import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../models/product.dart';
import '../theme.dart';
import '../util.dart';
import 'animations.dart';

class ProductCard extends StatelessWidget {
  final Product product;
  final bool isBestSeller;
  const ProductCard({super.key, required this.product, this.isBestSeller = false});

  @override
  Widget build(BuildContext context) {
    final style = categoryStyle(product.category);
    final discountPct = product.mrp > 0
        ? ((product.mrp - product.b2bPrice) / product.mrp * 100).round()
        : 0;

    return RepaintBoundary(
      child: HoverLift(
        child: PressEffect(
          scale: 0.98,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ImageBlock(
                    product: product,
                    style: style,
                    discountPct: discountPct,
                    isBestSeller: isBestSeller),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Line 1 — manufacturer (1 line, fixed)
                        Text(
                          product.manufacturer.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF9CA3AF),
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 3),
                        // Line 2 — product name (1 line, fixed)
                        Text(
                          product.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: Color(0xFF111827),
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 3),
                        // Lines 3-4 — composition (exactly 2 lines, fixed height)
                        SizedBox(
                          height: 29,
                          child: Text(
                            product.genericName.isNotEmpty
                                ? product.genericName
                                : '—',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF6B7280),
                              height: 1.3,
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        // Line 5 — category badge
                        _Pill(
                          text: prettyCategory(product.therapeuticClass),
                          bg: style.fg.withValues(alpha: 0.88),
                        ),
                        const SizedBox(height: 6),
                        // Line 6 — price row
                        _PriceRow(product: product),
                        const SizedBox(height: 8),
                        // Line 7 — cart button
                        _CartControl(product: product),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Price row ───────────────────────────────────────────────────────────────

class _PriceRow extends StatelessWidget {
  final Product product;
  const _PriceRow({required this.product});

  @override
  Widget build(BuildContext context) {
    // Fixed-height row: left side is natural width, Expanded gives remaining
    // space to pack-size so it can never push price off-screen or wrap.
    return SizedBox(
      height: 22,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            rupees(product.b2bPrice),
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 18,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            'MRP',
            style: TextStyle(
              fontSize: 11,
              color: Color(0xFF9CA3AF),
              fontWeight: FontWeight.w500,
            ),
          ),
          // Expanded captures all remaining space; text right-aligns inside it.
          Expanded(
            child: Text(
              product.packSize,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF16A34A),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Add-to-cart / stepper ───────────────────────────────────────────────────

class _CartControl extends StatelessWidget {
  final Product product;
  // Key on product.id so AnimatedSwitcher state resets if a different product
  // ends up at the same grid position (e.g. after a category/search change).
  _CartControl({required this.product}) : super(key: ValueKey('ctrl-${product.id}'));

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final qty = cart.quantityOf(product.id);

    return SizedBox(
      width: double.infinity,
      height: 48,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: child,
        ),
        child: qty > 0
            ? SizedBox.expand(
                key: const ValueKey('stepper'),
                child: _QuantityStepper(
                  product: product,
                  quantity: qty,
                ),
              )
            : PressEffect(
                key: const ValueKey('add'),
                child: SizedBox.expand(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0d0d1a),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFD1D5DB),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6)),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: const TextStyle(
                          fontWeight: FontWeight.w500, fontSize: 14),
                      elevation: 0,
                      splashFactory: NoSplash.splashFactory,
                      shadowColor: Colors.transparent,
                    ).copyWith(
                      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                    ),
                    onPressed: product.inStock
                        ? () {
                            cart.add(product);
                            MedicineRepository().incrementSalesCount(product.id);
                          }
                        : null,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add to cart'),
                  ),
                ),
              ),
      ),
    );
  }
}

// ─── Image block ─────────────────────────────────────────────────────────────

class _ImageBlock extends StatelessWidget {
  final Product product;
  final CategoryStyle style;
  final int discountPct;
  final bool isBestSeller;
  const _ImageBlock({
    required this.product,
    required this.style,
    required this.discountPct,
    this.isBestSeller = false,
  });

  @override
  Widget build(BuildContext context) {
    final status = product.inStock ? 'Available' : 'Out of Stock';
    return SizedBox(
      height: 180,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Product image — cover fill (no white gaps around image)
          product.imageUrl.isEmpty
              ? _IconFallback(style: style)
              : Image.network(
                  product.imageUrl,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : Container(color: style.bg.withValues(alpha: 0.4)),
                  errorBuilder: (_, _, _) => _IconFallback(style: style),
                ),
          // Scheme badge top-left — deterministic 30% of products
          if (_hasScheme(product.id))
            Positioned(
              left: 8,
              top: 8,
              child: _SchemePill(text: '5+1'),
            ),
          // Available / Out of Stock — top right, fully opaque
          Positioned(
            right: 8,
            top: 8,
            child: _Pill(
              text: status,
              bg: product.inStock
                  ? const Color(0xFF16A34A)
                  : const Color(0xFFDC2626),
            ),
          ),
          // Best Seller badge — bottom left, gold
          if (isBestSeller)
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFD97706),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.local_fire_department_rounded,
                        size: 12, color: Colors.white),
                    SizedBox(width: 4),
                    Text(
                      'Best Seller',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.0,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Badge helpers ────────────────────────────────────────────────────────────

// Deterministic scheme assignment: ~30% of products based on numeric ID.
// Uses the actual DB id (bigint as string) so the result is stable across reloads.
bool _hasScheme(String productId) {
  final id = int.tryParse(productId) ?? 0;
  return id % 10 < 3;
}

// Scheme badge (top-left of image): solid yellow, white bold text, boxy shape.
class _SchemePill extends StatelessWidget {
  final String text;
  const _SchemePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFFB800),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color bg;
  const _Pill({required this.text, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 8, right: 8, top: 3, bottom: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          height: 1.2,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}

// ─── Icon fallback ────────────────────────────────────────────────────────────

class _IconFallback extends StatelessWidget {
  final CategoryStyle style;
  const _IconFallback({required this.style});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: style.bg,
      alignment: Alignment.center,
      child: Icon(style.icon, size: 64, color: style.fg.withValues(alpha: 0.4)),
    );
  }
}

// ─── Quantity stepper ─────────────────────────────────────────────────────────

class _QuantityStepper extends StatefulWidget {
  final Product product;
  final int quantity;
  const _QuantityStepper(
      {super.key, required this.product, required this.quantity});

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
  State<_QuantityStepper> createState() => _QuantityStepperState();
}

class _QuantityStepperState extends State<_QuantityStepper> {
  bool _increasing = true;

  @override
  void didUpdateWidget(_QuantityStepper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.quantity != oldWidget.quantity) {
      _increasing = widget.quantity > oldWidget.quantity;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final unit = _QuantityStepper._unit(widget.product.packSize);
    final qty = widget.quantity;
    final increasing = _increasing;

    // White stepper: transparent buttons with dark symbols, white center.
    // A Positioned.fill overlay of three invisible tap zones sits on top so
    // the entire left/right thirds are clickable, not just the ± symbols.
    return Stack(
      children: [
        // ── Visual layer — unchanged ──────────────────────────────────
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Minus button — transparent, dark symbol
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => cart.decrement(widget.product),
                  child: const SizedBox(
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
                ),
              ),
              // Center — number and unit, same style
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
                                begin: begin,
                                end: Offset.zero,
                              ).animate(anim),
                              child: child,
                            );
                          },
                          child: Text(
                            '$qty',
                            key: ValueKey<int>(qty),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1a1a1a),
                              fontSize: 16,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        unit,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xFF1a1a1a),
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Plus button — transparent, dark symbol
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => cart.increment(widget.product),
                  child: const SizedBox(
                    width: 44,
                    child: Center(
                      child: Text(
                        '+',
                        style: TextStyle(
                          color: Color(0xFF1a1a1a),
                          fontSize: 22,
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
        // ── Invisible tap-zone overlay ────────────────────────────────
        Positioned.fill(
          child: Row(
            children: [
              // Left 33%: decrement
              Expanded(
                flex: 33,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => cart.decrement(widget.product),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              // Middle 34%: absorbs taps, does nothing
              Expanded(
                flex: 34,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  child: const SizedBox.expand(),
                ),
              ),
              // Right 33%: increment
              Expanded(
                flex: 33,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => cart.increment(widget.product),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
