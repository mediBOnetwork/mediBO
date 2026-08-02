import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../models/product.dart';
import 'animations.dart';
import 'product_image.dart';

/// CHANGE #636 — the Plazza-style compact product card.
///
/// Replaces the old heavy card. Two deliberate removals:
///
///  * The manufacturer line is gone — it lives on the product page now.
///  * The old `_SchemePill` invented a "5+1" badge for ~30% of products from a
///    hash of the product id. That was the app answering "what scheme does
///    this product have?", a question only the backend can answer. The only
///    ribbon here is [Pricing.discountLabel], a string the backend rendered.
///
/// Every size is fixed so the grid never reflows: [extent] is the exact
/// main-axis height the grid delegate must reserve, and it is derived from the
/// same constants the widget lays out with.
class CompactProductCard extends StatelessWidget {
  final Product product;

  /// Pushes the product page. Injected so the grid owns routing and the card
  /// stays free of route literals.
  final VoidCallback onTap;

  const CompactProductCard({
    super.key,
    required this.product,
    required this.onTap,
  });

  // ── Fixed geometry ────────────────────────────────────────────────────────
  static const double _imageH = 120;
  static const double _actionRowH = 34;
  static const double _cardPad = 8;

  /// The card's 1px border sits INSIDE its height, so it must be in this sum.
  /// Leaving it out cost exactly 2px and overflowed the inner Column.
  static const double _borderW = 1;
  static const double cardHeight =
      _imageH + _actionRowH + _cardPad * 2 + _borderW * 2; // 172
  static const double _chipH = 17;
  static const double _nameH = 34; // exactly two 17px lines
  static const double _priceH = 20;

  /// The grid's mainAxisExtent. Kept next to the parts it sums so a change to
  /// the card can never silently overflow the grid the way a hardcoded 365 did.
  static const double extent =
      cardHeight + 8 + _chipH + 4 + _nameH + 2 + _priceH;

  /// Hero tag shared with the product page's first carousel image.
  static String heroTag(String id) => 'pd-img-$id';

  @override
  Widget build(BuildContext context) {
    final pricing = product.pricing;
    final av = product.availability;

    // The backend's verdict, not a stock number. `canAdd` false is the only
    // out-of-stock signal; the app never compares supplier counts.
    final soldOut = av != null && !av.canAdd;

    final card = _Card(
      product: product,
      soldOut: soldOut,
      ribbon: (pricing != null && pricing.hasDiscount)
          ? pricing.discountLabel
          : '',
      soldOutLabel: soldOut ? av.ctaLabel : '',
    );

    return RepaintBoundary(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Dimming the sold-out state is a visual treatment of the
            // backend's own verdict, not a second opinion about it.
            Opacity(opacity: soldOut ? 0.45 : 1.0, child: card),
            const SizedBox(height: 8),
            SizedBox(
              height: _chipH,
              child: product.formChip.isEmpty
                  ? const SizedBox.shrink()
                  : _FormChip(text: product.formChip),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: _nameH,
              child: Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.36,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1F2937),
                ),
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: _priceH,
              child: _PriceLine(pricing: pricing),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Product product;
  final bool soldOut;
  final String ribbon;
  final String soldOutLabel;

  const _Card({
    required this.product,
    required this.soldOut,
    required this.ribbon,
    required this.soldOutLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: CompactProductCard.cardHeight,
      padding: const EdgeInsets.all(CompactProductCard._cardPad),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: const Color(0xFFEDEFF2),
            width: CompactProductCard._borderW),
      ),
      child: Column(
        children: [
          SizedBox(
            height: CompactProductCard._imageH,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Center(
                    child: Hero(
                      tag: CompactProductCard.heroTag(product.id),
                      child: ProductImage(
                        url: product.imageUrl,
                        width: CompactProductCard._imageH,
                        height: CompactProductCard._imageH,
                        radius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                if (ribbon.isNotEmpty)
                  Positioned(left: 0, top: 0, child: _Ribbon(text: ribbon)),
                if (soldOut && soldOutLabel.isNotEmpty)
                  Positioned(
                      left: 0, bottom: 0, child: _SoldOutChip(text: soldOutLabel)),
              ],
            ),
          ),
          SizedBox(
            height: CompactProductCard._actionRowH,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    product.packSize,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Sold out and no notify path exists in this app, so the
                // control is hidden rather than showing a button that does
                // nothing. (Spec: wire Notify if present, else hide.)
                if (!soldOut) CompactCartControl(product: product),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ADD ⇄ stepper, isolated in its own subtree.
///
/// This is the ONLY widget in the card that reads [AppState]. The card itself
/// never does, so a cart write repaints one 34px control instead of every tile
/// in the grid.
class CompactCartControl extends StatelessWidget {
  final Product product;
  CompactCartControl({required this.product})
      : super(key: ValueKey('ccc-${product.id}'));

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final qty = cart.quantityOf(product.id);

    return SizedBox(
      height: 28,
      width: 74,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: ScaleTransition(scale: anim, child: child)),
        child: qty > 0
            ? _Stepper(
                key: const ValueKey('stepper'),
                qty: qty,
                onMinus: () => cart.decrementId(product.id),
                onPlus: () => cart.incrementId(product.id),
              )
            : _AddPill(
                key: const ValueKey('add'),
                label: product.availability?.ctaLabel ?? '',
                onTap: () {
                  if (cart.isPending(product.id)) return;
                  cart.addId(product.id);
                  // Fire-and-forget popularity ping. It must never be able to
                  // break an add-to-cart: the cart write above is the real
                  // work and has already been sent.
                  try {
                    MedicineRepository().incrementSalesCount(product.id);
                  } catch (_) {}
                },
              ),
      ),
    );
  }
}

class _AddPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _AddPill({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: EdgeInsets.zero,
        foregroundColor: const Color(0xFF1B7A43),
        side: const BorderSide(color: Color(0xFF1B7A43), width: 1.2),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      // The button text is the backend's cta_label, printed verbatim. An empty
      // label means the row carried no verdict — show nothing rather than a
      // word chosen here.
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final int qty;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _Stepper({
    super.key,
    required this.qty,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF1B7A43),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _StepIcon(icon: Icons.remove, onTap: onMinus),
          Text(
            '$qty',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          _StepIcon(icon: Icons.add, onTap: onPlus),
        ],
      ),
    );
  }
}

class _StepIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _StepIcon({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 24,
          height: 28,
          child: Icon(icon, size: 14, color: Colors.white),
        ),
      );
}

class _FormChip extends StatelessWidget {
  final String text;
  const _FormChip({required this.text});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: Color(0xFF64748B),
            ),
          ),
        ),
      );
}

class _Ribbon extends StatelessWidget {
  final String text;
  const _Ribbon({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: const BoxDecoration(
          color: Color(0xFF1B7A43),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(8),
            bottomRight: Radius.circular(8),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 9.5,
            height: 1.1,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
      );
}

class _SoldOutChip extends StatelessWidget {
  final String text;
  const _SoldOutChip({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFFEE2E2),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 9.5,
            height: 1.1,
            fontWeight: FontWeight.w700,
            color: Color(0xFFB91C1C),
          ),
        ),
      );
}

class _PriceLine extends StatelessWidget {
  final Pricing? pricing;
  const _PriceLine({required this.pricing});

  @override
  Widget build(BuildContext context) {
    // No pricing block, or an explicit "this product has no MRP" — render
    // nothing rather than a fabricated ₹0.00.
    if (pricing == null || !pricing!.hasPrice) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          pricing!.priceDisplay,
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
          ),
        ),
        if (pricing!.hasDiscount) ...[
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              pricing!.mrpDisplay,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                color: Color(0xFF9CA3AF),
                decoration: TextDecoration.lineThrough,
                decorationColor: Color(0xFF9CA3AF),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Skeleton with the SAME fixed geometry as the real card, so the swap from
/// loading to loaded moves nothing. Uses the app's existing [SkeletonBox] and
/// is wrapped by the grid's existing [Shimmer], so it shimmers exactly like
/// every other loading state in the app.
class CompactCardSkeleton extends StatelessWidget {
  const CompactCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SkeletonBox(
            width: double.infinity,
            height: CompactProductCard.cardHeight,
            radius: 14,
          ),
          SizedBox(height: 8),
          SkeletonBox(width: 42, height: CompactProductCard._chipH),
          SizedBox(height: 4),
          SkeletonBox(
              width: double.infinity, height: CompactProductCard._nameH),
          SizedBox(height: 2),
          SkeletonBox(width: 70, height: CompactProductCard._priceH),
        ],
      );
}
