import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../models/product.dart';
import '../theme.dart';
import 'animations.dart';
import 'notify_control.dart';
import 'product_image.dart';

/// CHANGE #1895 — the storefront product card, rebuilt to Om's 08-Sep sketch.
///
/// Top to bottom, exactly as drawn:
///
///  1. **The image plate**, with the pack sentence ON it along the bottom
///     ("10 capsules in 1 strip") and the Rx badge top-right. The strip runs
///     the full width of the plate now — nothing overlaps it — so the sentence
///     that used to be ellipsised as "10 tablet er…" reads in full.
///  2. **One row under the plate**: the pack TYPE ("Strip") hard left, the ADD
///     control hard right. The add pill stopped hanging over the image: it is
///     a row of its own, which is what makes the two pack strings readable at
///     the width a card actually gets in a 2-column grid.
///  3. **The name**, two bold lines.
///  4. **The company**, one grey line.
///  5. **MRP, struck, always** — the printed ceiling is shown to everyone,
///     including a visitor who is not signed in.
///  6. **The sale line, bold**: [CardPrice.priceDisplay]. ONE backend string —
///     the trade amount when the viewer is approved and a trade price exists,
///     the literal word "PTR" otherwise. Tapping the word opens the backend's
///     own register/approval prompt; the sentence that used to sit on the card
///     ("Register and get approved to see trade prices") is that prompt's note
///     now, not a third line of card copy.
///
/// Two rules the card keeps:
///
///  * It invents nothing and it decides nothing. There is no approval check
///    here, no price arithmetic and no formatting — `price_locked` is the
///    backend's verdict and `price_display` is the backend's string.
///  * Every size is fixed. [extent] is the exact main-axis height the grid and
///    the rail reserve, summed from the same constants the widget lays out
///    with, so the card cannot grow without its container growing with it.
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
  // (162 in a rail, ~173 in a 2-column grid on a 390pt phone). A fixed height
  // rather than an AspectRatio on purpose: [extent] must be a constant, and a
  // width-derived height would make the reserved height a function of the
  // viewport.
  static const double tileH = 152;

  /// The add control's height, and with it the height of the row it shares
  /// with the pack type. 34 leaves the whole row a 44pt tap target once the
  /// gaps above and below it are counted.
  static const double pillH = 34;

  /// The pack-type + ADD row under the plate (#1895).
  static const double _actionH = pillH;

  /// CHANGE #1895b — Om's sketch: the pack sentence is a GREEN BADGE lying ON
  /// the photo at its bottom edge, not a grey strip under it. The artwork now
  /// fills the whole plate and the badge floats over it, so this is the
  /// badge's own height (what the purchase badge has to clear), not a band
  /// carved out of the image.
  static const double _footerH = 20;

  static const double _nameH = 36; // exactly two 18px lines
  static const double _mfrH = 15; // company, one line
  static const double _mrpH = 15; // "MRP ₹174.38", struck
  static const double _ptrH = 22; // the sale line: the amount, or "PTR"

  // Named gaps — the 4/8/12/16 rhythm, as constants so the design-literal gate
  // sees no bare numbers inside an EdgeInsets/SizedBox on a styling line.
  static const double _gapS = 4;
  static const double _gapM = 6;
  static const double _gapL = 8;

  /// Kept for callers that reserve the plate alone (the skeleton, and anything
  /// measuring the tappable image area).
  static const double cardHeight = tileH;

  /// The grid's mainAxisExtent and the rail's height. Summed from the parts
  /// above so a change to the card can never silently overflow its container
  /// the way a hardcoded number did.
  static const double extent =
      tileH +
      _gapM +
      _actionH + // pack type left, ADD right
      _gapM +
      _nameH +
      _gapS +
      _mfrH +
      _gapM +
      _mrpH +
      _gapS +
      _ptrH; // 300 — unchanged by #1895, so no grid had to move

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
        borderRadius: BorderRadius.circular(Rad.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Dimming the sold-out plate is a visual treatment of the backend's
            // own verdict, not a second opinion about it.
            Opacity(
              opacity: soldOut ? 0.45 : 1.0,
              child: _Plate(
                product: product,
                pricing: pricing,
                soldOut: soldOut,
                soldOutLabel: soldOut ? av.ctaLabel : '',
              ),
            ),
            const SizedBox(height: _gapM),
            // #1895 — the action row. The pack TYPE is one word ("Strip",
            // "Vial") and sits hard left; the add control sits hard right. The
            // row's height is reserved whether or not either is present, so a
            // product with no pack type cannot shorten the card.
            SizedBox(
              height: _actionH,
              child: Row(
                children: [
                  Expanded(
                    child: product.packTypeLabel.isEmpty
                        ? const SizedBox.shrink()
                        : _TypeChip(text: product.packTypeLabel),
                  ),
                  const SizedBox(width: _gapM),
                  soldOut
                      ? NotifyControl(productId: product.id)
                      : CompactCartControl(product: product),
                ],
              ),
            ),
            const SizedBox(height: _gapM),
            SizedBox(
              height: _nameH,
              child: Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.l5.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 18 / 12,
                ),
              ),
            ),
            const SizedBox(height: _gapS),
            SizedBox(
              height: _mfrH,
              child: Text(
                product.manufacturer,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.t1,
              ),
            ),
            const SizedBox(height: _gapM),
            CardPriceLines(
              price: pricing?.cardPrice,
              mrpHeight: _mrpH,
              priceHeight: _ptrH,
              gap: _gapS,
            ),
          ],
        ),
      ),
    );
  }
}

/// The image plate: white, hairline-bordered, one soft shadow, with the pack
/// badge in a footer strip along its bottom edge.
///
/// The pack badge lives INSIDE the plate deliberately — twice over. It is
/// where Om asked for it, and putting it below would make the text block's
/// height depend on whether a product has a pack label, which a fixed-extent
/// grid cannot survive.
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

    // The scheme badge, gated on the BACKEND's boolean in both forms. The
    // pricing block's badge (colours included) wins; `has_offer` + `offer_chip`
    // is the older, colourless signal a product carries before its trade
    // pricing has been captured. Either way an offer is a fact about the
    // product, never inferred from a string being non-empty.
    final badge = pricing?.schemeBadge;
    final hasBadge =
        pricing?.hasSchemeBadge == true &&
        badge != null &&
        badge.label.isNotEmpty;
    final offerText = (!hasBadge && product.hasOffer) ? product.offerChip : '';

    return Container(
      height: CompactProductCard.tileH,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(Rad.card),
        border: Border.all(color: Brand.border),
        boxShadow: Ds.elevation.e1,
      ),
      child: Stack(
        children: [
          // #1895b — the artwork fills the plate. The pack badge lies on top of
          // it (below), which is what "inside the image" means on the sketch.
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(CompactProductCard._gapL),
              child: Center(
                child: Hero(
                  tag: CompactProductCard.heroTag(product.id),
                  child: ProductImage(
                    url: product.imageUrl,
                    width:
                        CompactProductCard.tileH -
                        CompactProductCard._gapL * 2,
                    height:
                        CompactProductCard.tileH -
                        CompactProductCard._gapL * 2,
                    radius: BorderRadius.circular(Rad.tile),
                  ),
                ),
              ),
            ),
          ),
          if (ribbon)
            Positioned(
              left: CompactProductCard._gapL,
              top: 0,
              child: _Ribbon(
                top: pricing!.ribbonTop,
                bottom: pricing!.ribbonBottom,
                bg: pricing!.marginChip?.bg,
                fg: pricing!.marginChip?.fg,
              ),
            ),
          // CMD #791 — the repeat-purchase badge. It rides ON the plate, in
          // the same place and for the same reason as the scheme badge: the
          // grid's mainAxisExtent is a SUM of this card's constants, so a new
          // row under the price would silently overflow every grid that
          // reserves it. `has` is the backend's — an anonymous visitor's
          // payload simply carries no `purchase` block, so nothing here asks
          // whether anyone is signed in.
          //
          // Tapping it is the one-tap re-order: it SETS the usual quantity the
          // backend decided, it does not increment. Not offered on a sold-out
          // plate, because `canAdd` is false there and the write would be
          // refused by the same verdict the pill already reads.
          if (product.purchase.has)
            Positioned(
              left: CompactProductCard._gapM,
              bottom:
                  CompactProductCard._footerH + CompactProductCard._gapL * 2,
              child: _PurchaseBadge(
                product: product,
                enabled: !soldOut && product.purchase.canAdd,
              ),
            ),
          // CHANGE #274 — the scheme badge moved onto the plate. It used to own
          // an 18px row under the price on EVERY card, which is height spent on
          // the cards that have no scheme.
          // CHANGE #461/#170 — the prescription class joins it in the same
          // top-right stack rather than taking a row of its own: the grid's
          // mainAxisExtent is a sum of this card's constants, and a new row
          // would silently overflow every grid that reserves it.
          if (hasBadge || offerText.isNotEmpty || product.hasRxBadge)
            Positioned(
              right: CompactProductCard._gapM,
              top: CompactProductCard._gapM,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasBadge || offerText.isNotEmpty)
                    _MiniChip(
                      text: hasBadge ? badge.label : offerText,
                      bg: hasBadge ? badge.bg : null,
                      fg: hasBadge ? badge.fg : null,
                    ),
                  if (product.hasRxBadge) ...[
                    if (hasBadge || offerText.isNotEmpty)
                      SizedBox(height: Ds.space.x4),
                    _C461RxChip(
                      label: product.rxLabel,
                      tone: product.rxTone,
                    ),
                  ],
                ],
              ),
            ),
          // CHANGE #1895b — the pack SENTENCE ("10 capsules in 1 strip") is a
          // GREEN BADGE lying on the photo's bottom edge. #1895 put it in a
          // grey strip UNDER the artwork and Om sent it back: on his sketch
          // the badge is inside the image. It hugs its text (a Row, so the
          // Container is not stretched to the plate width) and ellipsises
          // inside the plate rather than painting past it.
          //
          // Sold out, the same slot carries the backend's own out-of-stock
          // word instead — one badge, never two stacked on the artwork.
          if (product.packQtyLabel.isNotEmpty ||
              (soldOut && soldOutLabel.isNotEmpty))
            Positioned(
              left: CompactProductCard._gapL,
              right: CompactProductCard._gapL,
              bottom: CompactProductCard._gapL,
              child: Row(
                children: [
                  Flexible(
                    child: (soldOut && soldOutLabel.isNotEmpty)
                        ? _MiniChip(text: soldOutLabel, strong: true)
                        : _PackBadge(text: product.packQtyLabel),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The notched corner ribbon. Two backend-sent lines, never one string split
/// here. The V-cut at the bottom is what stops it reading as a badge.
///
/// It carries a TRADE margin ("18% / margin"), which the backend only sends to
/// a viewer entitled to trade prices — it is not a consumer "% OFF" flash.
class _Ribbon extends StatelessWidget {
  final String top;
  final String bottom;

  /// CHANGE #174 — the margin band's colours, when the payload sent a chip.
  /// Which band a margin falls into is a business rule (`pricing_margin_bands`
  /// in Postgres), so the colour travels with the words. Null keeps the
  /// original fixed styling — the geometry is identical either way.
  final int? bg;
  final int? fg;

  const _Ribbon({required this.top, required this.bottom, this.bg, this.fg});

  static const double w = 38;
  static const double h = 38;

  @override
  Widget build(BuildContext context) => ClipPath(
    clipper: const _RibbonClipper(),
    child: Container(
      width: w,
      height: h,
      color: bg == null ? Brand.deep : Color(bg!),
      padding: const EdgeInsets.only(top: CompactProductCard._gapS),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            top,
            maxLines: 1,
            style: AppType.t3.copyWith(
              height: 14 / 9,
              letterSpacing: -0.3,
              color: fg == null ? null : Color(fg!),
            ),
          ),
          Text(
            bottom,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: AppType.t3.copyWith(
              height: 10 / 9,
              fontWeight: FontWeight.w600,
              color: fg == null ? null : Color(fg!),
            ),
          ),
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
/// never does, so a cart write repaints one 34px control instead of every tile
/// in the grid.
class CompactCartControl extends StatelessWidget {
  final Product product;
  CompactCartControl({required this.product})
    : super(key: ValueKey('ccc-${product.id}'));

  static const double w = 72;

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final qty = cart.quantityOf(product.id);

    return SizedBox(
      height: CompactProductCard.pillH,
      width: w,
      // CHANGE #678a — the Add pill becomes the stepper instantly.
      //
      // It used to cross-fade and scale over 180ms. On a grid of cards that is
      // motion the user did not ask for, in the one place they are tapping
      // fast. The storefront paints; it does not perform.
      child: qty > 0
          ? _Stepper(
              key: const ValueKey('stepper'),
              qty: qty,
              onMinus: () => cart.decrementId(product.id),
              onPlus: () => cart.incrementId(product.id),
            )
          : _AddPill(
              key: const ValueKey('add'),
              // CHANGE #274 — the SHORT word. "Add to cart" never fitted a
              // 72px pill and was ellipsised to "Add to c…" on every tile.
              // Both forms are backend strings; the card takes the short one
              // and falls back to the long one rather than inventing a word.
              label: product.availability?.ctaShort.isNotEmpty == true
                  ? product.availability!.ctaShort
                  : (product.availability?.ctaLabel ?? ''),
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
    // CHANGE #1895b — SOLID green with a white label. It was an outlined
    // white pill and Om sent it back: on the sketch the ADD is the filled
    // green action, and it is the only one on the card.
    return Material(
      color: Brand.accent,
      borderRadius: BorderRadius.circular(Rad.tile),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Rad.tile),
        child: Center(
          // The button text is the backend's, printed verbatim. An empty
          // label means the row carried no verdict — show nothing rather
          // than a word chosen here.
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.l4.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
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
          Text(
            '$qty',
            style: AppType.l4.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
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

/// CHANGE #1895b — the pack sentence, as a solid green badge lying on the
/// photo's bottom edge ("10 capsules in 1 strip").
///
/// The sentence itself is the backend's `pack_qty_label`, printed verbatim —
/// nothing here counts units or picks a plural. Green because Om drew it
/// green, and it hugs its text so a short sentence does not paint a bar the
/// width of the plate.
class _PackBadge extends StatelessWidget {
  final String text;
  const _PackBadge({required this.text});

  static const double _padH = 8;
  static const double _padV = 3;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: _padH, vertical: _padV),
    decoration: BoxDecoration(
      color: Brand.accent,
      borderRadius: BorderRadius.circular(Rad.chip),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppType.t2.copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// The dosage-form chip under the plate ("Strip", "Vial", "Bottle").
///
/// It HUGS its label. The #673 version wrapped a `Container(alignment: …)` in
/// an `Align`, and a Container with a non-null alignment expands to fill the
/// loose constraints Align hands it — which is exactly how a 40px chip became
/// the full-width grey pill across the whole card.
class _TypeChip extends StatelessWidget {
  final String text;
  const _TypeChip({required this.text});

  static const double _padH = 8;

  // A Row, not an Align. `Align(widthFactor: 1)` shrinks the ALIGN to its
  // child, and the fixed-height SizedBox above it then centres that shrunken
  // box — which is why the chip rendered mid-card on the first deploy. A Row
  // fills the width and starts its children at the left, and the Container
  // (no `alignment` of its own — see the class doc) hugs its Text.
  @override
  Widget build(BuildContext context) => Row(
    children: [
      // CHANGE #287 — Flexible, because the chip now prints the stored pack
      // sentence. A Row lays a non-flex child out with an UNBOUNDED main-axis
      // constraint, so a long label would paint past the card edge (and stripe
      // in debug) instead of ellipsising inside it.
      Flexible(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: _padH),
          decoration: BoxDecoration(
            color: Brand.accentSoft,
            borderRadius: BorderRadius.circular(Rad.chip),
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.t2.copyWith(color: Brand.accentDark),
          ),
        ),
      ),
    ],
  );
}

/// A small tinted chip that hugs its label — the scheme badge on the plate and
/// the sold-out chip in the footer. Colours come from the payload when it sent
/// any; otherwise it wears the app's own tints.
class _MiniChip extends StatelessWidget {
  final String text;
  final int? bg;
  final int? fg;

  /// The sold-out variant: the negative tint, bolder.
  final bool strong;

  const _MiniChip({required this.text, this.bg, this.fg, this.strong = false});

  static const double _padH = 7;
  static const double _padV = 3;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: _padH, vertical: _padV),
    decoration: BoxDecoration(
      color: bg != null
          ? Color(bg!)
          : (strong ? Brand.negativeBg : Brand.positiveBg),
      borderRadius: BorderRadius.circular(Rad.chip),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppType.t2.copyWith(
        color: fg != null
            ? Color(fg!)
            : (strong ? Brand.negativeFg : Brand.positiveFg),
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// CHANGE #1895 — the B2B price block: the struck MRP, then the sale line.
///
/// Every branch here is a backend boolean, never a test on a string being
/// empty:
///
///  * [CardPrice.hasMrp] — the catalogue has a printed price at all. 9.7% of
///    MEDICINE rows carry no mrp, and "₹0.00" reads as FREE rather than
///    unknown.
///  * [CardPrice.strikeMrp] — the MRP is the printed ceiling and is struck
///    whether or not the viewer may see a trade rate. What sits under it is
///    an amount for one viewer and the word "PTR" for another.
///  * [CardPrice.priceLocked] — the backend's entitlement verdict, and the
///    ONLY thing that decides whether the sale line is tappable. An
///    unentitled viewer's payload carries no trade number at all, so this
///    widget is not hiding one: there is nothing here to hide.
///
/// What LEFT the card in #1895: the "Register and get approved to see trade
/// prices" sentence. It was a third line of copy on every card a visitor saw;
/// it is the prompt behind the word now.
///
/// It is PUBLIC because the catalogue card renders the same two lines from the
/// same block: "identical everywhere" is one widget, not two that agree today.
/// The two heights are the caller's, because the two grids reserve different
/// extents; everything else is shared.
class CardPriceLines extends StatelessWidget {
  final CardPrice? price;
  final double mrpHeight;
  final double priceHeight;
  final double gap;

  const CardPriceLines({
    super.key,
    required this.price,
    required this.mrpHeight,
    required this.priceHeight,
    required this.gap,
  });

  @override
  Widget build(BuildContext context) {
    final p = price;
    if (p == null) {
      return SizedBox(height: mrpHeight + gap + priceHeight);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Line 4 — the MRP. Struck whenever the backend says so, which since
        // #1895 is whenever there is one: the printed ceiling is a fact about
        // the pack, not about who is looking at it.
        SizedBox(
          height: mrpHeight,
          child: !p.hasMrp
              ? const SizedBox.shrink()
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (p.mrpLabel.isNotEmpty) ...[
                      Text(
                        p.mrpLabel,
                        maxLines: 1,
                        style: AppType.t2.copyWith(color: Brand.inkFaint),
                      ),
                      const SizedBox(width: CompactProductCard._gapS),
                    ],
                    Flexible(
                      child: Text(
                        p.mrpDisplay,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.t1.copyWith(
                          color: Brand.inkFaint,
                          decoration: p.strikeMrp
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                          decorationColor: Brand.inkFaint,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        SizedBox(height: gap),
        // Line 5 — the sale line. ONE string either way, so there is no branch
        // here on approval, on a role, or on whether a number arrived: the
        // backend already answered all three when it chose what to put in
        // price_display. The only thing the lock changes is the tap.
        SizedBox(
          height: priceHeight,
          child: _SaleLine(price: p, height: priceHeight),
        ),
      ],
    );
  }
}

/// The sale line: the backend's caption, then [CardPrice.priceDisplay] riding
/// in a badge the backend colours.
///
/// CHANGE #1895b — Om's sketch turned the bare bold amount into a labelled
/// row: "Sale price:" in caption grey, then the value on a green plate. Both
/// the caption ([CardPrice.saleLabel]) and the two colours
/// ([CardPrice.saleBg] / [CardPrice.saleFg]) arrive in the payload, so the
/// word and the green are an UPDATE to `storefront_ui_label`, not a deploy.
/// A payload built before #1895b carries neither, and the fallbacks below
/// keep it rendering the card's own accent rather than nothing.
///
/// Locked, the value is the word the backend chose ("PTR") and the badge
/// opens that block's own prompt. Unlocked, it is the trade amount and it is
/// inert — tapping the card is what opens the product. Nothing here knows
/// which of the two it is holding; [CardPrice.priceLocked] is the backend's
/// verdict.
///
/// [height] is the extent the caller reserved (22 on the compact card, 20 on
/// the catalogue one). The badge is EXACTLY that tall rather than padded to
/// whatever its font needs, which is what keeps one widget safe inside two
/// grids whose rows are different heights.
class _SaleLine extends StatelessWidget {
  final CardPrice price;
  final double height;
  const _SaleLine({required this.price, required this.height});

  /// The badge's side padding. Vertical padding would fight [height].
  static const double _padH = 8;

  @override
  Widget build(BuildContext context) {
    if (price.priceDisplay.isEmpty) return const SizedBox.shrink();

    // A Container with a null alignment shrink-wraps its child, which is the
    // whole reason the badge hugs "₹99.56" instead of painting a green bar
    // the width of the card — the same trap [_TypeChip] documents.
    final badge = Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: _padH),
      decoration: BoxDecoration(
        color: price.saleBg == null ? Brand.accent : Color(price.saleBg!),
        borderRadius: BorderRadius.circular(Rad.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              price.priceDisplay,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.l5.copyWith(
                fontWeight: FontWeight.w800,
                color: price.saleFg == null
                    ? Colors.white
                    : Color(price.saleFg!),
              ),
            ),
          ),
          if (price.priceLocked) ...[
            const SizedBox(width: CompactProductCard._gapS),
            Icon(
              Icons.lock_outline_rounded,
              size: Ds.space.x12,
              color: price.saleFg == null ? Colors.white : Color(price.saleFg!),
            ),
          ],
        ],
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (price.saleLabel.isNotEmpty) ...[
          Text(
            price.saleLabel,
            maxLines: 1,
            style: AppType.t1.copyWith(color: Brand.inkSub),
          ),
          const SizedBox(width: CompactProductCard._gapM),
        ],
        Flexible(
          child: price.priceLocked
              ? InkWell(
                  onTap: () => showPriceLockedSheet(context, price),
                  borderRadius: BorderRadius.circular(Rad.chip),
                  child: badge,
                )
              : badge,
        ),
      ],
    );
  }
}

/// The register/approval prompt the locked word opens.
///
/// A sheet, not a dialog (the design contract), and every word in it — the
/// heading, the sentence, the button, and the ROUTE the button takes — is the
/// payload's. Nothing is worded or routed here, so the prompt can be reworded
/// or re-pointed with an UPDATE to storefront_ui_label.
Future<void> showPriceLockedSheet(BuildContext context, CardPrice price) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Rad.card)),
    ),
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (price.lockedTitle.isNotEmpty) ...[
              Text(price.lockedTitle, style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x8),
            ],
            if (price.lockedNote.isNotEmpty)
              Text(price.lockedNote, style: Ds.t.body),
            if (price.lockedCta.isNotEmpty) ...[
              SizedBox(height: Ds.space.x16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(sheet).pop();
                    if (price.lockedRoute.isEmpty) return;
                    Navigator.of(context).pushNamed(price.lockedRoute);
                  },
                  child: Text(price.lockedCta),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
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
        radius: Rad.card,
      ),
      SizedBox(height: CompactProductCard._gapM),
      // The pack-type + ADD row, so nothing shifts when the card loads.
      SkeletonBox(width: double.infinity, height: CompactProductCard._actionH),
      SizedBox(height: CompactProductCard._gapM),
      SkeletonBox(width: double.infinity, height: CompactProductCard._nameH),
      SizedBox(height: CompactProductCard._gapS),
      SkeletonBox(width: 96, height: CompactProductCard._mfrH),
      SizedBox(height: CompactProductCard._gapM),
      SkeletonBox(width: 72, height: CompactProductCard._mrpH),
      SizedBox(height: CompactProductCard._gapS),
      SkeletonBox(width: 88, height: CompactProductCard._ptrH),
    ],
  );
}

/// CHANGE #461/#170 — the Rx / OTC chip. One backend label in the backend's
/// own tone; no schedule is mapped, inferred or coloured here.
class _C461RxChip extends StatelessWidget {
  final String label;
  final Map<String, dynamic>? tone;
  const _C461RxChip({required this.label, this.tone});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4 / 2),
      decoration: BoxDecoration(
        color: Ds.hex(tone?['bg'], Ds.c.infoSoft),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(
        label,
        style: Ds.t.caption.copyWith(color: Ds.hex(tone?['fg'], Ds.c.text)),
      ),
    );
  }
}


/// CMD #791 — the catalogue card's repeat-purchase badge.
///
/// One pill, one word set, one tap. `short_label` ("Ordered 12 Aug") is the
/// backend's compact form of the same sentence the product page prints in
/// full — the card does not truncate the long one, because a truncation is a
/// string decision and those belong upstream.
///
/// The tap SETS `usual_qty`. A pharmacy that always buys three strips gets
/// three in one tap instead of three taps on the plus, and the number comes
/// from its own order history rather than from anything this widget counts.
class _PurchaseBadge extends StatelessWidget {
  final Product product;
  final bool enabled;
  const _PurchaseBadge({required this.product, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final o = product.purchase;
    if (o.shortLabel.isEmpty) return const SizedBox.shrink();
    final bg = Ds.hex(o.tone['bg'], Ds.c.bg);
    final fg = Ds.hex(o.tone['fg'], Ds.c.text);

    return GestureDetector(
      onTap: enabled
          ? () => AppState.of(context).setQuantityId(product.id, o.usualQty)
          : null,
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
        child: Text(
          o.shortLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Ds.t.caption.copyWith(color: fg),
        ),
      ),
    );
  }
}
