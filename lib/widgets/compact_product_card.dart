import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../models/product.dart';
import '../theme.dart';
import 'animations.dart';
import 'notify_control.dart';
import 'product_image.dart';

/// CHANGE #673 — the storefront product card, rebuilt.
///
/// What made the old card read as a 90s table cell was not one mistake, it was
/// the absence of every device that makes a card look designed: a hairline box
/// on white, a tiny outlined "Add to cart" sitting inline in a text row, a flat
/// rounded ribbon, and no colour anywhere. Everything sat in one tonal band.
///
/// Four changes, in order of how much they do:
///
///  1. **The ADD pill overlaps the image plate's bottom-right corner** and
///     hangs below it. One element crossing one boundary is what separates a
///     card that was laid out from a card that was designed. Everything else
///     here is ordinary; this is not.
///  2. **A notched ribbon**, V-cut at the bottom like a real bookmark, in the
///     dark brand green — not a rounded rectangle.
///  3. **A caption above the price.** B2B does not sell at MRP, so the number
///     is a PTR and says so. The caption word is [Pricing.priceCaption], from
///     the backend, because "PTR" is a business decision.
///  4. **Type with tracking.** [AppType] at w800/-0.3 instead of stock Roboto
///     at 0.
///
/// Two rules the card keeps from #636:
///
///  * It invents nothing. The ribbon is [Pricing.ribbonTop]/[Pricing.ribbonBottom],
///    the offer chip is [Product.offerChip] gated on [Product.hasOffer], the
///    button word is [Availability.ctaLabel]. There is no string, no percentage
///    and no verdict computed here. The card renders; it never decides.
///  * Every size is fixed. [extent] is the exact main-axis height the grid
///    delegate must reserve and is summed from the same constants the widget
///    lays out with, so the card cannot grow without the grid growing with it.
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
  // The image plate. Near-square at both widths this card is ever laid out at
  // (156 in a rail, ~173 in a 2-column grid on a 390pt phone). It is a fixed
  // height rather than an AspectRatio on purpose: [extent] must be a constant,
  // and a width-derived height would make the grid's reserved height a
  // function of the viewport.
  static const double tileH = 160;

  /// How far the ADD pill hangs below the plate. This overhang is the card's
  /// signature move — if it is ever set to 0 the card goes back to looking
  /// like a form.
  static const double _overhang = 12;
  static const double pillH = 36;

  static const double _chipH = 18; // form chip ("Strip", "Vial")
  static const double _nameH = 40; // exactly two 20px lines
  static const double _priceH = 24; // caption + PTR + struck MRP, one row
  static const double _offerH = 18; // "Scheme available"

  /// Kept for callers that still reserve the plate alone (the skeleton, and
  /// anything measuring the tappable image area).
  static const double cardHeight = tileH;

  /// The grid's mainAxisExtent. Summed from the parts above so a change to the
  /// card can never silently overflow the grid the way a hardcoded 365 did.
  static const double extent = tileH +
      _overhang + // the pill hangs into this
      6 +
      _chipH +
      6 +
      _nameH +
      4 +
      _priceH +
      4 +
      _offerH; // 292

  /// Hero tag shared with the product page's first carousel image.
  static String heroTag(String id) => 'pd-img-$id';

  @override
  Widget build(BuildContext context) {
    final pricing = product.pricing;
    final av = product.availability;

    // The backend's verdict, not a stock number. `canAdd` false is the only
    // out-of-stock signal; the app never compares supplier counts.
    final soldOut = av != null && !av.canAdd;

    return RepaintBoundary(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Rad.tile),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: tileH + _overhang,
              child: Stack(
                children: [
                  // Dimming the sold-out plate is a visual treatment of the
                  // backend's own verdict, not a second opinion about it.
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: Opacity(
                      opacity: soldOut ? 0.45 : 1.0,
                      child: _Plate(
                        product: product,
                        pricing: pricing,
                        soldOut: soldOut,
                        soldOutLabel: soldOut ? av.ctaLabel : '',
                      ),
                    ),
                  ),
                  // The overlap. Sits above the dim layer because it is the one
                  // thing a sold-out card is still for.
                  Positioned(
                    right: 8,
                    bottom: 0,
                    child: soldOut
                        ? SizedBox(
                            height: pillH,
                            child: Center(
                                child: NotifyControl(productId: product.id)))
                        : CompactCartControl(product: product),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: _chipH,
              child: product.formChip.isEmpty
                  ? const SizedBox.shrink()
                  : _FormChip(text: product.formChip),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: _nameH,
              child: Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.l5.copyWith(height: 20 / 12),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(height: _priceH, child: _PriceLine(pricing: pricing)),
            const SizedBox(height: 4),
            SizedBox(
              height: _offerH,
              // Gated on the backend's boolean, never on "the string is not
              // empty" — an offer is a fact about the product, not about the
              // payload.
              child: (product.hasOffer && product.offerChip.isNotEmpty)
                  ? _OfferChip(text: product.offerChip)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The image plate: white, hairline-bordered, with the ribbon top-left and the
/// pack size (or the sold-out chip) bottom-left.
///
/// The pack size lives INSIDE the plate deliberately. Putting it below would
/// make the text block's height depend on whether a product has a pack label,
/// and a fixed-extent grid cannot survive that.
class _Plate extends StatelessWidget {
  final Product product;
  final Pricing? pricing;
  final bool soldOut;
  final String soldOutLabel;

  const _Plate({
    required this.product,
    required this.pricing,
    required this.soldOut,
    required this.soldOutLabel,
  });

  @override
  Widget build(BuildContext context) {
    final ribbon = (pricing != null && pricing!.hasRibbon);

    return Container(
      height: CompactProductCard.tileH,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(Rad.tile),
        border: Border.all(color: Brand.border),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Center(
                child: Hero(
                  tag: CompactProductCard.heroTag(product.id),
                  child: ProductImage(
                    url: product.imageUrl,
                    width: CompactProductCard.tileH - 20,
                    height: CompactProductCard.tileH - 20,
                    radius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
          if (ribbon)
            Positioned(
              left: 8,
              top: 0,
              child: _Ribbon(
                top: pricing!.ribbonTop,
                bottom: pricing!.ribbonBottom,
              ),
            ),
          Positioned(
            left: 8,
            right: 56, // clear of the overlapping pill
            bottom: 7,
            child: (soldOut && soldOutLabel.isNotEmpty)
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: _SoldOutChip(text: soldOutLabel),
                  )
                : Text(
                    product.packSize,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.t1,
                  ),
          ),
        ],
      ),
    );
  }
}

/// The notched corner ribbon. Two backend-sent lines, never one string split
/// here. The V-cut at the bottom is what stops it reading as a badge.
class _Ribbon extends StatelessWidget {
  final String top;
  final String bottom;
  const _Ribbon({required this.top, required this.bottom});

  static const double w = 40;
  static const double h = 40;

  @override
  Widget build(BuildContext context) => ClipPath(
        clipper: const _RibbonClipper(),
        child: Container(
          width: w,
          height: h,
          color: Brand.deep,
          padding: const EdgeInsets.only(top: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(top,
                  maxLines: 1,
                  style: AppType.t3.copyWith(
                      fontSize: 12, height: 14 / 12, letterSpacing: -0.3)),
              Text(bottom,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: AppType.t3.copyWith(fontSize: 7, height: 9 / 7)),
            ],
          ),
        ),
      );
}

class _RibbonClipper extends CustomClipper<Path> {
  const _RibbonClipper();

  /// How deep the V bites into the bottom edge.
  static const double notch = 8;

  @override
  Path getClip(Size size) => Path()
    ..moveTo(0, 0)
    ..lineTo(size.width, 0)
    ..lineTo(size.width, size.height)
    ..lineTo(size.width / 2, size.height - notch)
    ..lineTo(0, size.height)
    ..close();

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// ADD ⇄ stepper, isolated in its own subtree.
///
/// This is the ONLY widget in the card that reads [AppState]. The card itself
/// never does, so a cart write repaints one 36px control instead of every tile
/// in the grid.
class CompactCartControl extends StatelessWidget {
  final Product product;
  CompactCartControl({required this.product})
      : super(key: ValueKey('ccc-${product.id}'));

  static const double w = 76;

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final qty = cart.quantityOf(product.id);

    return SizedBox(
      height: CompactProductCard.pillH,
      width: w,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim, child: ScaleTransition(scale: anim, child: child)),
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

/// White fill, accent outline, accent text — it reads as a button sitting on
/// top of the card rather than a line of text inside it.
class _AddPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _AddPill({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(Rad.tile),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Rad.tile),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Rad.tile),
            border: Border.all(color: Brand.accent, width: 1.5),
          ),
          child: Center(
            // The button text is the backend's cta_label, printed verbatim. An
            // empty label means the row carried no verdict — show nothing
            // rather than a word chosen here.
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.l3.copyWith(color: Brand.accent),
            ),
          ),
        ),
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
    return Material(
      color: Brand.accent,
      borderRadius: BorderRadius.circular(Rad.tile),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _StepIcon(icon: Icons.remove_rounded, onTap: onMinus),
          Text('$qty',
              style: AppType.l4.copyWith(
                  color: Colors.white, fontWeight: FontWeight.w800)),
          _StepIcon(icon: Icons.add_rounded, onTap: onPlus),
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
          height: CompactProductCard.pillH,
          child: Icon(icon, size: 16, color: Colors.white),
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
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: Brand.field,
            borderRadius: BorderRadius.circular(Rad.chip),
          ),
          alignment: Alignment.center,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.t2,
          ),
        ),
      );
}

/// The backend's own offer wording, on the positive tint. Not a "5+1" invented
/// from a hash of the product id — that was the old `_SchemePill`, and it was
/// the app answering a question only the catalogue can answer.
class _OfferChip extends StatelessWidget {
  final String text;
  const _OfferChip({required this.text});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: Brand.positiveBg,
            borderRadius: BorderRadius.circular(Rad.chip),
          ),
          alignment: Alignment.center,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.t2.copyWith(
                color: Brand.positiveFg, fontWeight: FontWeight.w700),
          ),
        ),
      );
}

class _SoldOutChip extends StatelessWidget {
  final String text;
  const _SoldOutChip({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Brand.negativeBg,
          borderRadius: BorderRadius.circular(Rad.chip),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.t2.copyWith(
              color: Brand.negativeFg, fontWeight: FontWeight.w700),
        ),
      );
}

/// Caption + PTR + struck MRP, on one 24px row.
///
/// The caption ("PTR") is [Pricing.priceCaption] — a backend string, because
/// what the number *is* is a business decision. B2B buys at PTR and resells at
/// MRP, so the struck number here is what the pharmacy earns against, not a
/// consumer discount.
class _PriceLine extends StatelessWidget {
  final Pricing? pricing;
  const _PriceLine({required this.pricing});

  @override
  Widget build(BuildContext context) {
    // No pricing block, or an explicit "this product has no MRP" — render
    // nothing rather than a fabricated ₹0.00.
    final p = pricing;
    if (p == null || !p.hasPrice) return const SizedBox.shrink();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (p.priceCaption.isNotEmpty) ...[
          // Flexible because the caption is a backend word. "PTR" fits, but
          // rewording it to "NET RATE" in Postgres must not overflow the row —
          // a copy edit is a data change and may never need a deploy.
          Flexible(
            child: Text(p.priceCaption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.t2.copyWith(
                    fontSize: 9,
                    color: Brand.inkFaint,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4)),
          ),
          const SizedBox(width: 4),
        ],
        Text(
          p.priceDisplay,
          style: AppType.l3.copyWith(
              fontWeight: FontWeight.w800, color: Brand.price),
        ),
        if (p.hasDiscount) ...[
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              p.mrpDisplay,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.t1.copyWith(
                color: Brand.inkFaint,
                decoration: TextDecoration.lineThrough,
                decorationColor: Brand.inkFaint,
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
            height: CompactProductCard.tileH,
            radius: Rad.tile,
          ),
          // Stands in for the pill overhang, so nothing shifts on load.
          SizedBox(height: CompactProductCard._overhang + 6),
          SkeletonBox(width: 44, height: CompactProductCard._chipH),
          SizedBox(height: 6),
          SkeletonBox(width: double.infinity, height: CompactProductCard._nameH),
          SizedBox(height: 4),
          SkeletonBox(width: 82, height: CompactProductCard._priceH),
          SizedBox(height: 4),
          SkeletonBox(width: 96, height: CompactProductCard._offerH),
        ],
      );
}
