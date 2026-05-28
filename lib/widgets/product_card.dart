import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../models/product.dart';
import '../screens/auth/login_screen.dart';
import '../theme.dart';
import '../user_state.dart';
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
                        // Line 2 — product name (2 lines)
                        Text(
                          product.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: Color(0xFF111827),
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 3),
                        // Line 3 — composition (1 line, ellipsis)
                        Text(
                          product.genericName.isNotEmpty
                              ? product.genericName
                              : '—',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF6B7280),
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 5),
                        // Line 4 — pack size (left, ellipsis) + scheme badge (right, fixed)
                        _PackSizeRow(product: product),
                        const SizedBox(height: 5),
                        // Line 5 — price row
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          rupees(product.b2bPrice),
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            color: Color(0xFF111827),
          ),
        ),
        if (product.mrp > product.b2bPrice) ...[
          const SizedBox(width: 6),
          Text(
            rupees(product.mrp),
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF9CA3AF),
              fontWeight: FontWeight.w400,
              decoration: TextDecoration.lineThrough,
              decorationColor: Color(0xFF9CA3AF),
            ),
          ),
        ],
      ],
    );
  }
}

// ─── Add-to-cart / stepper ───────────────────────────────────────────────────

class _CartControl extends StatefulWidget {
  final Product product;
  // Key on product.id so state resets if a different product ends up at the
  // same grid position (e.g. after a category/search change).
  _CartControl({required this.product}) : super(key: ValueKey('ctrl-${product.id}'));

  @override
  State<_CartControl> createState() => _CartControlState();
}

class _CartControlState extends State<_CartControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _popCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  late final Animation<double> _popAnim = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.18), weight: 35),
    TweenSequenceItem(
        tween: Tween(begin: 1.18, end: 0.92)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 30),
    TweenSequenceItem(
        tween: Tween(begin: 0.92, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 35),
  ]).animate(_popCtrl);

  @override
  void dispose() {
    _popCtrl.dispose();
    super.dispose();
  }

  Future<void> _addToCart() async {
    // TODO: RE-ENABLE LOGIN CHECK BEFORE LAUNCH
    // DISABLED FOR NOW - RE-ENABLE LATER
    // final auth = UserState.read(context);
    // if (!auth.isAuthenticated) {
    //   final goLogin = await showDialog<bool>(
    //     context: context,
    //     builder: (ctx) => AlertDialog(
    //       shape: RoundedRectangleBorder(
    //           borderRadius: BorderRadius.circular(16)),
    //       title: const Text(
    //         'Login required',
    //         style: TextStyle(fontWeight: FontWeight.w700),
    //       ),
    //       content: const Text(
    //         'Please log in to add items to your cart.',
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
    //   if (!mounted) return;
    //   if (!UserState.read(context).isAuthenticated) return;
    // }
    _popCtrl.forward(from: 0);
    AppState.of(context).add(widget.product);
    MedicineRepository().incrementSalesCount(widget.product.id);
  }

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final qty = cart.quantityOf(widget.product.id);

    return SizedBox(
      width: double.infinity,
      height: 48,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(scale: anim, child: child),
        ),
        child: qty > 0
            ? SizedBox.expand(
                key: const ValueKey('stepper'),
                child: _QuantityStepper(
                  product: widget.product,
                  quantity: qty,
                ),
              )
            : ScaleTransition(
                scale: _popAnim,
                child: widget.product.inStock
                    ? PressEffect(
                        key: const ValueKey('add'),
                        child: SizedBox.expand(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF0d0d1a),
                              foregroundColor: Colors.white,
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
                              overlayColor: const WidgetStatePropertyAll(
                                  Colors.transparent),
                            ),
                            onPressed: _addToCart,
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Add to cart'),
                          ),
                        ),
                      )
                    : SizedBox.expand(
                        key: const ValueKey('unavailable'),
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFF3F4F6),
                            foregroundColor: const Color(0xFF9CA3AF),
                            disabledBackgroundColor: const Color(0xFFF3F4F6),
                            disabledForegroundColor: const Color(0xFF9CA3AF),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6)),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            textStyle: const TextStyle(
                                fontWeight: FontWeight.w500, fontSize: 14),
                            elevation: 0,
                            splashFactory: NoSplash.splashFactory,
                            shadowColor: Colors.transparent,
                          ),
                          onPressed: null,
                          child: const Text('Unavailable'),
                        ),
                      ),
              ),
      ),
    );
  }
}

// ─── Image block (carousel when multiple images) ─────────────────────────────

class _ImageBlock extends StatefulWidget {
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
  State<_ImageBlock> createState() => _ImageBlockState();
}

class _ImageBlockState extends State<_ImageBlock> {
  late final PageController _pageCtrl = PageController();
  int _page = 0;
  bool _hovered = false;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _prev() => _pageCtrl.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );

  void _next() => _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );

  @override
  Widget build(BuildContext context) {
    final images = widget.product.imageUrls;
    final multi = images.length > 1;
    // Desktop (≥900px): show arrows only on hover. Mobile: always show.
    final isDesktop = MediaQuery.sizeOf(context).width >= 900;
    final showArrows = multi && (isDesktop ? _hovered : true);
    return SizedBox(
      height: 180,
      width: double.infinity,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Image / carousel ──────────────────────────────────────────
            images.isEmpty
                ? _IconFallback(style: widget.style)
                : images.length == 1
                    ? Image.network(
                        images[0],
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        cacheWidth: 400,
                        cacheHeight: 360,
                        loadingBuilder: (_, child, prog) => prog == null
                            ? child
                            : Container(
                                color: widget.style.bg.withValues(alpha: 0.4)),
                        errorBuilder: (_, _, _) =>
                            _IconFallback(style: widget.style),
                      )
                    : PageView.builder(
                        controller: _pageCtrl,
                        itemCount: images.length,
                        onPageChanged: (p) => setState(() => _page = p),
                        itemBuilder: (_, i) => Image.network(
                          images[i],
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          cacheWidth: 400,
                          cacheHeight: 360,
                          loadingBuilder: (_, child, prog) => prog == null
                              ? child
                              : Container(
                                  color:
                                      widget.style.bg.withValues(alpha: 0.4)),
                          errorBuilder: (_, _, _) =>
                              _IconFallback(style: widget.style),
                        ),
                      ),
            // ── Static overlays ───────────────────────────────────────────
            if (_hasScheme(widget.product.id))
              Positioned(left: 8, top: 8, child: _SchemePill(text: '5+1')),
            if (widget.isBestSeller)
              Positioned(
                left: 8,
                bottom: multi ? 24 : 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
            // ── Carousel arrows ───────────────────────────────────────────
            if (showArrows && _page > 0)
              Positioned(
                left: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _CarouselArrow(icon: Icons.chevron_left, onTap: _prev),
                ),
              ),
            if (showArrows && _page < images.length - 1)
              Positioned(
                right: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child:
                      _CarouselArrow(icon: Icons.chevron_right, onTap: _next),
                ),
              ),
            // ── Dot indicators ────────────────────────────────────────────
            if (multi)
              Positioned(
                bottom: 6,
                left: 0,
                right: 0,
                child: _DotIndicators(count: images.length, current: _page),
              ),
          ],
        ),
      ),
    );
  }
}

class _CarouselArrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CarouselArrow({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }
}

class _DotIndicators extends StatelessWidget {
  final int count;
  final int current;
  const _DotIndicators({required this.count, required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: i == current ? 12.0 : 6.0,
          height: 6,
          decoration: BoxDecoration(
            color: i == current
                ? Colors.white
                : Colors.white.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
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

// ─── Pack size + scheme badge row ────────────────────────────────────────────

class _PackSizeRow extends StatelessWidget {
  final Product product;
  const _PackSizeRow({required this.product});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            product.packSize.isNotEmpty ? product.packSize : '—',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF9CA3AF),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (_hasScheme(product.id)) ...[
          const SizedBox(width: 6),
          _SchemePill(text: '5+1'),
        ],
      ],
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
