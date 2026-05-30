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
    final cart = AppState.of(context);
    final discountPct = cartDiscountPercent(cart.mrpTotal).round();

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
    final cart = AppState.of(context);
    final discPct = cartDiscountPercent(cart.mrpTotal);
    final salePrice = product.mrp * (1 - discPct / 100);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              rupees(salePrice),
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: Color(0xFF111827),
              ),
            ),
            if (discPct > 0) ...[
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
        ),
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
  late final PageController _pageCtrl;
  late final int _rawInitial;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    final count = widget.product.imageUrls.length;
    _rawInitial = count > 1 ? count * 500 : 0;
    _pageCtrl = PageController(initialPage: _rawInitial);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  // Navigate to a logical index, choosing the closest raw page (supports loop).
  void _goTo(int logical) {
    final count = widget.product.imageUrls.length;
    if (count < 2) return;
    final raw = _pageCtrl.page?.round() ?? _rawInitial;
    final base = (raw ~/ count) * count;
    var target = base + logical;
    if (target - raw > count / 2) target -= count;
    if (raw - target > count / 2) target += count;
    setState(() => _page = logical);
    _pageCtrl.animateToPage(target,
        duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
  }

  void _openZoom(BuildContext context, List<String> images) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      barrierDismissible: true,
      builder: (_) => _ZoomDialog(images: images, initialPage: _page),
    );
  }

  Widget _netImage(String url) => Image.network(
        url,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        gaplessPlayback: true,
        cacheWidth: 400,
        cacheHeight: 360,
        loadingBuilder: (_, child, prog) => prog == null
            ? child
            : const ColoredBox(
                color: Colors.white,
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFFD1D5DB)),
                  ),
                ),
              ),
        errorBuilder: (_, __, ___) => const _IconFallback(),
      );

  @override
  Widget build(BuildContext context) {
    final images = widget.product.imageUrls;
    final count = images.length;
    final multi = count > 1;

    return SizedBox(
      height: 180,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Image / carousel (infinite loop) ─────────────────────────
          GestureDetector(
            onTap: images.isNotEmpty ? () => _openZoom(context, images) : null,
            child: images.isEmpty
                ? const _IconFallback()
                : images.length == 1
                    ? Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(4),
                        child: _netImage(images[0]),
                      )
                    : Container(
                        color: Colors.white,
                        child: PageView.builder(
                          controller: _pageCtrl,
                          // Large virtual count → seamless infinite loop
                          itemCount: count * 1000,
                          onPageChanged: (p) =>
                              setState(() => _page = p % count),
                          itemBuilder: (_, i) => Padding(
                            padding: const EdgeInsets.all(4),
                            child: _netImage(images[i % count]),
                          ),
                        ),
                      ),
          ),
          // ── Static overlays ───────────────────────────────────────────
          Positioned(
            left: 8,
            top: 8,
            right: _hasScheme(widget.product.id) ? 50 : 8,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _CategoryImagePill(
                  text: prettyCategory(widget.product.category)),
            ),
          ),
          if (_hasScheme(widget.product.id))
            Positioned(right: 8, top: 8, child: _SchemePill(text: '5+1')),
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
          // ── Dot nav (replaces arrows) ─────────────────────────────────
          if (multi)
            Positioned(
              bottom: 6,
              left: 0,
              right: 0,
              child: _DotNav(
                count: images.length,
                current: _page,
                onSelect: _goTo,
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Dot navigation ───────────────────────────────────────────────────────────

class _DotNav extends StatelessWidget {
  final int count;
  final int current;
  final ValueChanged<int> onSelect;
  // true when shown on a dark backdrop (zoom dialog) — uses white dots
  final bool darkBackground;
  const _DotNav({
    required this.count,
    required this.current,
    required this.onSelect,
    this.darkBackground = false,
  });

  // Graduated size: active=6, distance-1=4, distance≥2=3
  static double _size(int dist) {
    if (dist == 0) return 6.0;
    if (dist == 1) return 4.0;
    return 3.0;
  }

  // Graduated colour: white variants on dark, grey variants on light
  Color _color(int dist) {
    if (darkBackground) {
      if (dist == 0) return Colors.white;
      if (dist == 1) return Colors.white.withValues(alpha: 0.5);
      return Colors.white.withValues(alpha: 0.25);
    }
    if (dist == 0) return const Color(0xFF1F2937);
    if (dist == 1) return const Color(0xFF6B7280);
    return const Color(0xFFD1D5DB);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final dist = (i - current).abs();
        final sz = _size(dist);
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => onSelect(i),
          child: GestureDetector(
            onTap: () => onSelect(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeInOut,
                width: sz,
                height: sz,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _color(dist),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

// ─── Zoom dialog ──────────────────────────────────────────────────────────────

class _ZoomDialog extends StatefulWidget {
  final List<String> images;
  final int initialPage;
  const _ZoomDialog({required this.images, required this.initialPage});

  @override
  State<_ZoomDialog> createState() => _ZoomDialogState();
}

class _ZoomDialogState extends State<_ZoomDialog> {
  late final PageController _ctrl;
  late final int _rawInitial;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage;
    final count = widget.images.length;
    _rawInitial = count > 1 ? count * 500 + widget.initialPage : 0;
    _ctrl = PageController(initialPage: _rawInitial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _goTo(int logical) {
    final count = widget.images.length;
    if (count < 2) return;
    final raw = _ctrl.page?.round() ?? _rawInitial;
    final base = (raw ~/ count) * count;
    var target = base + logical;
    if (target - raw > count / 2) target -= count;
    if (raw - target > count / 2) target += count;
    setState(() => _page = logical);
    _ctrl.animateToPage(target,
        duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
  }

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    final count = images.length;
    final multi = count > 1;
    final size = MediaQuery.sizeOf(context);
    // Constrain image width so left/right backdrop strips remain tappable.
    final imgWidth = size.width * 0.95;
    final imgHeight = size.height * 0.78;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Stack(
          children: [
            // ── Backdrop: full screen — tapping ANY part closes dialog ──
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            // ── Image content: absorbs taps within its constrained bounds ─
            Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: imgWidth,
                      height: imgHeight,
                      child: multi
                          ? PageView.builder(
                              controller: _ctrl,
                              itemCount: count * 1000,
                              onPageChanged: (p) =>
                                  setState(() => _page = p % count),
                              itemBuilder: (_, i) => InteractiveViewer(
                                minScale: 0.8,
                                maxScale: 4.0,
                                child: Image.network(
                                  images[i % count],
                                  fit: BoxFit.contain,
                                ),
                              ),
                            )
                          : InteractiveViewer(
                              minScale: 0.8,
                              maxScale: 4.0,
                              child: Image.network(
                                images[0],
                                fit: BoxFit.contain,
                              ),
                            ),
                    ),
                    if (multi) ...[
                      const SizedBox(height: 12),
                      _DotNav(
                        count: count,
                        current: _page,
                        onSelect: _goTo,
                        darkBackground: true,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // ── Close button ─────────────────────────────────────────────
            Positioned(
              top: MediaQuery.paddingOf(context).top + 12,
              right: 16,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 20),
                ),
              ),
            ),
          ],
        ),
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

// Category overlay pill (top-left of image): semi-transparent dark background.
class _CategoryImagePill extends StatelessWidget {
  final String text;
  const _CategoryImagePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          height: 1.0,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}

// Scheme badge (top-right of image): solid amber, white bold text.
// Padding and text style intentionally match _CategoryImagePill so both
// badges are the same height when they appear on the same row.
class _SchemePill extends StatelessWidget {
  final String text;
  const _SchemePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
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
          height: 1.0,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}

// ─── Pack size row ────────────────────────────────────────────────────────────

class _PackSizeRow extends StatelessWidget {
  final Product product;
  const _PackSizeRow({required this.product});

  @override
  Widget build(BuildContext context) {
    return Text(
      product.packSize.isNotEmpty ? product.packSize : '—',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 11,
        color: Color(0xFF1D9E75),
        fontWeight: FontWeight.w500,
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
  const _IconFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      alignment: Alignment.center,
      child: const Icon(
        Icons.medication_outlined,
        size: 56,
        color: Color(0xFFE5E7EB),
      ),
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
