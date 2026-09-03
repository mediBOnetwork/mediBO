import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../models/product.dart';
import '../theme.dart';
import 'animations.dart';
import 'notify_control.dart';
import 'product_image.dart';

/// CHANGE #274 — the storefront product card, rebuilt to the reference
/// storefront's anatomy, keeping mediBO's B2B trade pricing.
///
/// Om put the two apps side by side: theirs read as a finished shop, ours as a
/// form. The layout is theirs; the money is ours. Top to bottom:
///
///  1. **A square white image plate.** Pure white behind the pack shot — a
///     tinted plate makes every photo look like it was cut out badly.
///  2. **The pack TYPE sits bottom-LEFT ON the image** ("Strip", "Vial"), in
///     the plate's own footer strip. CHANGE #287 put it there: that strip is
///     only as wide as the card minus the add pill, so the long quantity
///     sentence that used to live here was ellipsised on every card
///     ("10 tablet er…"). One word always fits. The string is
///     [Product.packTypeLabel] — MEDICINE.pack_type, decided in the RPC.
///  3. **The add control is a compact pill, bottom-RIGHT, half over the plate's
///     edge.** One element crossing one boundary is what separates a card that
///     was laid out from a card that was designed. It becomes a −/qty/+ pill
///     the moment something is in the cart.
///  4. **Below the plate**: the pack QUANTITY chip ("10.0 tablets in 1 strip"
///     — [Product.packQtyLabel], the stored value verbatim, and no chip at all
///     when the catalogue has none), the name at exactly two bold lines, the
///     manufacturer small and grey, then the price.
///
/// What is deliberately GONE from #673's card:
///
///  * The full-width grey pill. `_FormChip` set `alignment` on a `Container`
///    under an `Align`, and a Container with a non-null alignment FILLS the
///    loose constraints it is handed — so the chip stretched the whole card
///    width and printed the long pack sentence. It hugs its label now.
///  * The empty 18px offer row under the price. It reserved height on every
///    card so that a minority could show a chip, and that reserved emptiness
///    was most of the "large dead gap" Om saw. A scheme badge now rides on the
///    plate, where it costs no height at all.
///
/// The price block is [CardPrice] and is the whole reason this is a B2B card:
/// MRP struck on its own line as the printed ceiling, PTR under it in a filled
/// box as the rate the pharmacy actually pays. No "% OFF", no "best offer
/// applied", no "on orders of ₹999+" — those are consumer-discount devices and
/// mediBO does not sell that way; discounts land on the bill.
///
/// Two rules the card keeps:
///
///  * It invents nothing. Every string — pack type, pack quantity, MRP, PTR, the
///    locked-price note, the ADD word — arrives rendered. There is no number
///    formatted here and no verdict reached here.
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

  /// How far the add pill hangs below the plate. This overhang is the card's
  /// signature move — set it to 0 and the card goes back to looking like a
  /// form.
  static const double _overhang = 14;
  static const double pillH = 34;

  /// The plate's footer strip, holding the pack badge clear of the artwork.
  static const double _footerH = 30;

  static const double _chipH = 18; // pack quantity chip (#287)
  static const double _nameH = 36; // exactly two 18px lines
  static const double _mfrH = 15; // manufacturer, one line
  static const double _mrpH = 15; // "MRP ₹117.19", struck
  static const double _ptrH = 22; // the filled trade-price box

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
      _overhang + // the pill hangs into this
      _gapL +
      _chipH +
      _gapM +
      _nameH +
      _gapS +
      _mfrH +
      _gapM +
      _mrpH +
      _gapS +
      _ptrH; // 298

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
                    right: _gapL,
                    bottom: 0,
                    child: soldOut
                        ? SizedBox(
                            height: pillH,
                            child: Center(
                              child: NotifyControl(productId: product.id),
                            ),
                          )
                        : CompactCartControl(product: product),
                  ),
                ],
              ),
            ),
            const SizedBox(height: _gapL),
            // CHANGE #287 — the pack QUANTITY chip. The two pack strings swapped
            // places: the long sentence gets the full card width here, the one
            // word gets the narrow gap beside the ADD pill. Empty label = no
            // chip at all (most `Piece` rows carry no pack_qty); the row's
            // height stays reserved so the grid's fixed extent still holds.
            SizedBox(
              height: _chipH,
              child: product.packQtyLabel.isEmpty
                  ? const SizedBox.shrink()
                  : _TypeChip(text: product.packQtyLabel),
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
            _CardPriceBlock(price: pricing?.cardPrice),
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
          // The artwork sits above the footer strip, never under the badge.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: CompactProductCard._footerH,
            child: Padding(
              padding: const EdgeInsets.all(CompactProductCard._gapL),
              child: Center(
                child: Hero(
                  tag: CompactProductCard.heroTag(product.id),
                  child: ProductImage(
                    url: product.imageUrl,
                    width:
                        CompactProductCard.tileH -
                        CompactProductCard._footerH -
                        CompactProductCard._gapL * 2,
                    height:
                        CompactProductCard.tileH -
                        CompactProductCard._footerH -
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
              bottom: CompactProductCard._footerH + CompactProductCard._gapS,
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
          // The footer strip: pack badge left, kept clear of the pill's corner.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: CompactProductCard._footerH,
            child: Container(
              color: Brand.section,
              padding: const EdgeInsets.only(
                left: CompactProductCard._gapM * 2,
                right: CompactProductCard._gapL * 9,
              ),
              alignment: Alignment.centerLeft,
              child: (soldOut && soldOutLabel.isNotEmpty)
                  ? _MiniChip(text: soldOutLabel, strong: true)
                  // CHANGE #287 — one word ("Strip", "Vial"), because this
                  // strip is only as wide as the card minus the add pill.
                  : Text(
                      product.packTypeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.t1.copyWith(color: Brand.inkSub),
                    ),
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
            // The button text is the backend's, printed verbatim. An empty
            // label means the row carried no verdict — show nothing rather
            // than a word chosen here.
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.l4.copyWith(
                color: Brand.accent,
                fontWeight: FontWeight.w800,
              ),
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

/// CHANGE #274 — the B2B price block: MRP struck on its own line, PTR under it
/// in a filled box.
///
/// Every branch here is a backend boolean, never a test on a string being
/// empty:
///
///  * [CardPrice.hasMrp] — the catalogue has a printed price at all. 9.7% of
///    MEDICINE rows carry no mrp, and "₹0.00" reads as FREE rather than
///    unknown.
///  * [CardPrice.strikeMrp] — strike it only when a trade price sits beneath.
///  * [CardPrice.hasPtr] — the viewer is entitled to a trade price AND one
///    exists. An un-entitled viewer's payload has no ptr key at all, so this
///    widget is not hiding anything: there is nothing here to hide.
///  * [CardPrice.hasNote] — what to tell a visitor who is not entitled yet.
///    Its wording is the backend's, so "register and get approved" can be
///    reworded with an UPDATE.
class _CardPriceBlock extends StatelessWidget {
  final CardPrice? price;
  const _CardPriceBlock({required this.price});

  @override
  Widget build(BuildContext context) {
    final p = price;
    if (p == null) {
      return const SizedBox(
        height:
            CompactProductCard._mrpH +
            CompactProductCard._gapS +
            CompactProductCard._ptrH,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: CompactProductCard._mrpH,
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
        const SizedBox(height: CompactProductCard._gapS),
        SizedBox(
          height: CompactProductCard._ptrH,
          child: p.hasPtr
              ? _PtrBox(price: p)
              : (p.hasNote
                    ? Text(
                        p.note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.t2.copyWith(
                          color: Brand.inkMuted,
                          height: 11 / 10,
                        ),
                      )
                    : const SizedBox.shrink()),
        ),
      ],
    );
  }
}

/// The trade price, in a solid filled box. This is the number the pharmacy
/// pays; the box is what makes it, and not the struck MRP above it, read as
/// the price of the product.
class _PtrBox extends StatelessWidget {
  final CardPrice price;
  const _PtrBox({required this.price});

  static const double _padH = 7;

  // Same reason as _TypeChip: a Row so the box sits hard left in the card's
  // full-width price column, rather than being centred by the SizedBox that
  // reserves its height.
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Flexible(
        child: Container(
          height: CompactProductCard._ptrH,
          padding: const EdgeInsets.symmetric(horizontal: _padH),
          decoration: BoxDecoration(
            color: price.ptrBg == null ? Brand.accent : Color(price.ptrBg!),
            borderRadius: BorderRadius.circular(Rad.chip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Both halves are Flexible: the label and the number are BOTH
              // backend strings, and a card 148pt wide in a rail on a 360pt
              // phone must survive "NET RATE" replacing "PTR" without a
              // deploy. A copy edit is a data change; it may never overflow.
              if (price.ptrLabel.isNotEmpty) ...[
                Flexible(
                  child: Text(
                    price.ptrLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.t2.copyWith(
                      color: price.ptrFg == null
                          ? Colors.white
                          : Color(price.ptrFg!),
                    ),
                  ),
                ),
                const SizedBox(width: CompactProductCard._gapS),
              ],
              Flexible(
                child: Text(
                  price.ptrDisplay,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.l5.copyWith(
                    fontWeight: FontWeight.w800,
                    color: price.ptrFg == null
                        ? Colors.white
                        : Color(price.ptrFg!),
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
      // Stands in for the pill overhang, so nothing shifts on load.
      SizedBox(height: CompactProductCard._overhang + CompactProductCard._gapL),
      SkeletonBox(width: 44, height: CompactProductCard._chipH),
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
