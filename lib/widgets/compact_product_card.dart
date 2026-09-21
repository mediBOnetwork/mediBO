import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../models/product.dart';
import '../models/product_card_view.dart';
import '../models/storefront_p3.dart' show WishlistResult;
import '../utils/toast.dart';
import '../theme.dart';
import 'animations.dart';
import 'ds_tone.dart';
import 'notify_control.dart';
import 'product_image.dart';

// CMD #2123 — the row variant of this card (cart, Bulk Upload) ships with it.
export 'product_row_card.dart';

/// CMD #2122 — THE product card. One widget, every grid: storefront, home
/// rails, category, catalogue, search results and the company page.
///
/// Om's approved design ("Universal product card", image A) — one white
/// card, top to bottom:
///
///  1. **The image plate** — the photo on white with [imgPad] around it.
///     The unit chip ("Strip") sits top-left over it, the scheme badge under
///     that, the Rx dot top-right (the wishlist heart below it), and the
///     **floating round + button** bottom-right. In the cart, the + becomes
///     the filled − n + pill in the same spot; unavailable, it becomes
///     Notify.
///  2. **The name**, two bold lines at most.
///  3. **The pack line** ("10 tablets in 1 strip"), one grey line.
///  4. **The price row** — the sale amount bold with the MRP struck beside it
///     or, locked, the green PTR pill that opens the backend's prompt.
///  5. **The foot line** — the ONE line under the price (`card.foot`): the
///     margin, the scheme's effective rate, "{n} in cart", the lock note, or
///     "Unavailable right now", in the tone the backend chose.
///
/// Rules it keeps:
///
///  * It prints and never computes. Every string, badge, tone and state is in
///    the payload ([ProductCardView] reads it); there is no approval check,
///    no price arithmetic and no choice between lines here.
///  * Every size is fixed. [extent] is the exact main-axis height the grids
///    and rails reserve, summed from the constants the widget lays out with,
///    so the card cannot grow without its container growing with it. One
///    card height everywhere; the grid owns the 12px gutter.
class CompactProductCard extends StatelessWidget {
  final Product product;

  /// Opens the product. The whole card is the target except the controls
  /// sitting on it (+, stepper, Notify, heart, PTR pill), which own theirs.
  final VoidCallback onTap;

  /// CMD #2040 — the product page's salt rail shows a Compare control under
  /// the card. Empty label or null callback = no control and no row.
  final String compareLabel;
  final VoidCallback? onCompare;

  /// Test seam for the heart; production calls the repository.
  final Future<WishlistResult> Function(String productId)? wishlistToggle;

  /// Long-press preview (the peek sheet), where a surface offers one.
  final VoidCallback? onPeek;

  const CompactProductCard({
    super.key,
    required this.product,
    required this.onTap,
    this.compareLabel = '',
    this.onCompare,
    this.wishlistToggle,
    this.onPeek,
  });

  bool get _showsCompare => compareLabel.isNotEmpty && onCompare != null;

  // ── Fixed geometry ────────────────────────────────────────────────────────
  /// The image plate. Near-square at every width the card is laid out at
  /// (162 in a rail, ~170 in a 2-column grid on a 360–412pt phone). Fixed,
  /// not an AspectRatio: [extent] must be a constant, never a function of
  /// the viewport.
  static const double tileH = 152;

  /// The photo's inset on the white plate (the approved design's 10px).
  static const double imgPad = 10;

  /// The in-cart pill's height, and the + button's tap box. 44 is the app's
  /// touch minimum; the circle you SEE is [plusDot].
  static const double pillH = 44;
  static const double plusDot = 36;
  static const double stepperW = 104;

  static const double _nameH = 36; // exactly two 18px lines
  static const double _packH = 16; // the pack line, one line
  static const double _priceH = 22; // sale amount + struck MRP, or the PTR pill
  static const double _footH = 16; // the one foot line

  // Named gaps — the 4/8/12 rhythm, as constants so the design-literal gate
  // sees no bare numbers inside an EdgeInsets/SizedBox on a styling line.
  static const double _gapS = 4;
  static const double _gapM = 6;
  static const double _gapL = 8;
  static const double _padX = 12;
  static const double _padBottom = 12;

  /// Kept for callers that reserve the plate alone (anything measuring the
  /// tappable image area).
  static const double cardHeight = tileH;

  /// The card's hairline. `Border.all` eats it out of the box's CONTENT
  /// height, so it is part of the sum below.
  static const double _frameBorderW = 1;

  /// The grid's mainAxisExtent and the rail's height. Summed from the parts
  /// above so a change to the card can never silently overflow its container.
  static const double extent =
      _frameBorderW * 2 +
      tileH +
      _gapL +
      _nameH +
      _gapS +
      _packH +
      _gapM +
      _priceH +
      _gapS +
      _footH +
      _padBottom; // 278

  /// CMD #2040 — the heart's tap target; the circle you SEE is [wishDotSize].
  static const double wishTapSize = 44;
  static const double wishDotSize = 30;

  /// CMD #2040 — the Compare row. What you SEE is [_compareH]; what you can
  /// hit is the whole [compareRowH].
  static const double _compareH = 32;
  static const double compareRowH = 44;

  /// The extent a container must reserve for a card SHOWING Compare.
  static const double extentWithCompare = extent + _gapS + compareRowH;

  /// CMD #2118 drew a shorter card without the company line on the company
  /// page. CMD #2122 — the approved card has no company line anywhere, so
  /// there is one card height; the name survives for existing callers.
  static const double extentWithoutCompany = extent;

  /// CMD #2010 — the width one card takes in a horizontal rail.
  static const double railWidth = 162;

  /// Hero tag shared with the product page's first carousel image.
  static String heroTag(String id) => 'pd-img-$id';

  @override
  Widget build(BuildContext context) {
    final view = ProductCardView.of(product);
    final av = product.availability;

    // The backend's verdict, not a stock number. `canAdd` false is the only
    // out-of-stock signal; the app never compares supplier counts.
    final soldOut = av != null && !av.canAdd;

    final card = Container(
      height: extent,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Rad.card),
        border: Border.all(color: Ds.c.divider, width: _frameBorderW),
        boxShadow: Ds.elevation.e1,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onPeek,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: tileH,
                child: _Artwork(
                  product: product,
                  view: view,
                  soldOut: soldOut,
                  wishlistToggle: wishlistToggle,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: _padX, top: _gapL, right: _padX),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: _nameH,
                      child: Text(
                        product.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.l5.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 18 / 12,
                          color: Ds.c.text,
                        ),
                      ),
                    ),
                    const SizedBox(height: _gapS),
                    SizedBox(
                      height: _packH,
                      child: Text(
                        view.packLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.t1.copyWith(color: Ds.c.textSecondary),
                      ),
                    ),
                    const SizedBox(height: _gapM),
                    SizedBox(
                      height: _priceH,
                      child: CardPriceRow(price: view.price, height: _priceH),
                    ),
                    const SizedBox(height: _gapS),
                    SizedBox(
                      height: _footH,
                      child: view.hasFoot
                          ? Text(
                              view.footLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.t2.copyWith(
                                color: dsToneFg(view.footTone),
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // CMD #2122 — a stable handle for the browser journeys (Flutter web
    // renders to canvas; the semantics tree is the only thing a script taps).
    final tagged = Semantics(
      identifier: 'product_card',
      container: true,
      child: card,
    );

    return RepaintBoundary(
      child: !_showsCompare
          ? tagged
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                tagged,
                const SizedBox(height: _gapS),
                SizedBox(
                  height: compareRowH,
                  child: CompareButton(
                    label: compareLabel,
                    onTap: onCompare!,
                    height: _compareH,
                  ),
                ),
              ],
            ),
    );
  }
}

/// CMD #2122 — the price row: [CardPrice.priceDisplay] bold with the MRP
/// struck beside it, or — locked — the green PTR pill ([CardSaleLine]) that
/// opens the backend's own prompt. Every branch is a backend boolean
/// (`has_mrp`, `strike_mrp`, `price_locked`); the words and amounts are
/// printed verbatim.
class CardPriceRow extends StatelessWidget {
  final CardPrice? price;
  final double height;

  const CardPriceRow({super.key, required this.price, required this.height});

  @override
  Widget build(BuildContext context) {
    final p = price;
    if (p == null) return const SizedBox.shrink();

    final hasSale = p.priceDisplay.isNotEmpty;
    final mrpLabel = (!hasSale && p.mrpLabel.isNotEmpty)
        ? Text(
            p.mrpLabel,
            maxLines: 1,
            style: AppType.t2.copyWith(color: Brand.inkFaint),
          )
        : null;
    final mrp = !p.hasMrp
        ? null
        : Text(
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
          );

    // Locked: the backend's word ("PTR") on the green pill that opens its
    // prompt, the struck ceiling beside it.
    if (hasSale && p.priceLocked) {
      return Row(
        children: [
          Flexible(
            child: CardSaleLine(price: p, height: height, showLabel: false),
          ),
          if (mrp != null) ...[
            const SizedBox(width: CompactProductCard._gapM),
            Flexible(child: mrp),
          ],
        ],
      );
    }

    // Unlocked: the amount bold, the MRP struck beside it. The caption only
    // when the MRP stands alone (an `mrp_only` payload, where it IS the
    // headline) — beside a sale amount the approved design prints the
    // ceiling bare. On the narrowest rail a long amount scales down rather
    // than being cut: a price is never truncated.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasSale)
            Text(
              p.priceDisplay,
              maxLines: 1,
              style: AppType.l4.copyWith(
                color: Ds.c.text,
                fontWeight: FontWeight.w800,
              ),
            ),
          if (hasSale && mrp != null)
            const SizedBox(width: CompactProductCard._gapM),
          if (mrpLabel != null) ...[
            mrpLabel,
            const SizedBox(width: CompactProductCard._gapS),
          ],
          ?mrp,
        ],
      ),
    );
  }
}

/// CMD #2040 — the compact outlined Compare control.
///
/// Shared by the product page's price block and by every card on its salt
/// rail, so the two can never drift apart. It prints [label] verbatim — an
/// empty caption is the backend saying there is no control, and this widget
/// then draws nothing rather than a word chosen in Dart.
///
/// Outlined, never filled: the one filled brand action on both surfaces is
/// ADD. [height] is what you see; the caller reserves the 44pt row around it.
class CompareButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final double height;

  const CompareButton({
    super.key,
    required this.label,
    required this.onTap,
    this.height = 32,
  });

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Rad.chip),
        child: Center(
          child: Container(
            height: height,
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Rad.chip),
              border: Border.all(color: Brand.accent),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.compare_arrows_rounded,
                    size: Ds.space.x16, color: Brand.accent),
                SizedBox(width: Ds.space.x4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.l3.copyWith(color: Brand.accent),
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

/// CMD #1926 — the availability line, shared by the compact card and the
/// catalogue/search row so the two can never word the same verdict differently.
///
/// It prints [Availability.availabilityLabel] verbatim and colours it through
/// [dsToneFg], the app's ONE tone→colour lookup. An empty label (a payload
/// built before #1926, or a cart line whose product could not be resolved) is
/// an absence the backend declared: nothing is rendered and nothing is guessed.
class AvailabilityLine extends StatelessWidget {
  final Availability? availability;
  final TextAlign align;

  const AvailabilityLine({
    super.key,
    required this.availability,
    this.align = TextAlign.left,
  });

  @override
  Widget build(BuildContext context) {
    final a = availability;
    if (a == null || a.availabilityLabel.isEmpty) {
      return const SizedBox.shrink();
    }
    return Text(
      a.availabilityLabel,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: AppType.t2.copyWith(
        color: dsToneFg(a.availabilityTone),
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// CMD #2122 — the image plate: the photo on white, the unit chip and the
/// scheme badge top-left, the Rx dot (and the heart) top-right, and the
/// floating control bottom-right. Only the PHOTO dims when a pack is sold
/// out — Notify and the heart stay at full contrast, because they are what a
/// sold-out card is still for.
class _Artwork extends StatelessWidget {
  final Product product;
  final ProductCardView view;
  final bool soldOut;
  final Future<WishlistResult> Function(String productId)? wishlistToggle;

  const _Artwork({
    required this.product,
    required this.view,
    required this.soldOut,
    required this.wishlistToggle,
  });

  static const double _edge = CompactProductCard._gapL;

  static Color _col(Object? v, Color fallback) =>
      v is int ? Color(v) : Ds.hex(v, fallback);

  @override
  Widget build(BuildContext context) {
    final pricing = product.pricing;
    // A pre-#2121 payload's notched margin ribbon, exactly as it arrived. The
    // card object carries the margin in its foot line instead, so a `card`
    // payload never draws one.
    final ribbon =
        product.card == null && pricing != null && pricing.hasRibbon;

    return Stack(
      children: [
        Positioned.fill(
          child: Opacity(
            opacity: soldOut ? 0.45 : 1.0,
            child: Padding(
              padding: const EdgeInsets.all(CompactProductCard.imgPad),
              child: Center(
                child: Hero(
                  tag: CompactProductCard.heroTag(product.id),
                  child: ProductImage(
                    url: product.imageUrl,
                    width: CompactProductCard.tileH -
                        CompactProductCard.imgPad * 2,
                    height: CompactProductCard.tileH -
                        CompactProductCard.imgPad * 2,
                    radius: BorderRadius.circular(Rad.tile),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Top-left: the unit chip, then the scheme badge under it.
        Positioned(
          left: _edge,
          top: _edge,
          right: CompactProductCard.wishTapSize,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (view.unitWord.isNotEmpty)
                _UnitChip(text: view.unitWord),
              if (view.unitWord.isNotEmpty && view.hasOffer)
                const SizedBox(height: CompactProductCard._gapS),
              if (view.hasOffer)
                _MiniChip(
                  text: view.offerLabel,
                  bgColor: _col(view.offerBg, Ds.c.successSoft),
                  fgColor: _col(view.offerFg, Ds.c.success),
                ),
            ],
          ),
        ),
        // Top-right: the Rx dot (or an older payload's margin ribbon), then
        // the heart under it.
        Positioned(
          right: 0,
          top: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (ribbon)
                Padding(
                  padding: const EdgeInsets.only(right: _edge),
                  child: _Ribbon(
                    top: pricing.ribbonTop,
                    bottom: pricing.ribbonBottom,
                    bg: pricing.marginChip?.bg,
                    fg: pricing.marginChip?.fg,
                  ),
                )
              else if (view.hasRx)
                Padding(
                  padding: const EdgeInsets.only(top: _edge, right: _edge),
                  child: _RxDot(
                    label: view.rxLabel,
                    bg: _col(view.rxBg, Ds.c.dangerSoft),
                    fg: _col(view.rxFg, Ds.c.danger),
                  ),
                ),
              if (product.hasWish)
                _WishHeart(product: product, toggle: wishlistToggle),
            ],
          ),
        ),
        // A pre-#2121 payload's sold-out word, bottom-left on the plate.
        if (view.soldOutChip.isNotEmpty)
          Positioned(
            left: _edge,
            bottom: _edge,
            right: CompactProductCard.stepperW,
            child: Row(
              children: [
                Flexible(
                  child: _MiniChip(
                    text: view.soldOutChip,
                    bgColor: Ds.c.dangerSoft,
                    fgColor: Ds.c.danger,
                  ),
                ),
              ],
            ),
          ),
        // CMD #791 — the one-tap re-order badge, bottom-left on the plate.
        if (product.purchase.has && view.soldOutChip.isEmpty)
          Positioned(
            left: _edge,
            bottom: _edge,
            right: CompactCartControl.w + _edge,
            child: Row(
              children: [
                Flexible(
                  child: _PurchaseBadge(
                    product: product,
                    enabled: !soldOut && product.purchase.canAdd,
                  ),
                ),
              ],
            ),
          ),
        // Bottom-right: THE floating control.
        Positioned(
          right: CompactProductCard._gapS,
          bottom: CompactProductCard._gapS,
          child: soldOut
              ? SizedBox(
                  height: CompactProductCard.pillH,
                  child: Center(
                    child: NotifyControl(
                      productId: product.id,
                      initiallySubscribed: product.card?['notified'] == true,
                      height: CompactProductCard.plusDot,
                    ),
                  ),
                )
              : CompactCartControl(product: product),
        ),
      ],
    );
  }
}

/// The unit word ("Strip", "Bottle") in a white outlined chip, top-left on
/// the photo. The backend's `card.unit_word`, verbatim.
class _UnitChip extends StatelessWidget {
  final String text;
  const _UnitChip({required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: Ds.space.x8,
      vertical: Ds.space.x4,
    ),
    decoration: BoxDecoration(
      color: Ds.c.surface,
      borderRadius: BorderRadius.circular(Rad.chip),
      border: Border.all(color: Ds.c.divider),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppType.t2.copyWith(
        color: Ds.c.text,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// The prescription dot, top-right: the backend's rx label in its tone.
class _RxDot extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const _RxDot({required this.label, required this.bg, required this.fg});

  static const double size = 24;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
    child: Text(
      label,
      maxLines: 1,
      style: AppType.t3.copyWith(color: fg, fontWeight: FontWeight.w800),
    ),
  );
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

/// CMD #2122 — the floating control: a round + on the photo's bottom-right,
/// which becomes the filled − n + pill once the pack is in the cart.
///
/// This is the ONLY widget in the card that reads [AppState], so a cart write
/// repaints one control instead of every tile in the grid. The + carries the
/// backend's add word (`cta_short`, falling back to `cta_label`) as its
/// tooltip and screen-reader label — never a word typed here.
class CompactCartControl extends StatelessWidget {
  final Product product;
  CompactCartControl({required this.product})
    : super(key: ValueKey('ccc-${product.id}'));

  /// The widest the control gets (the in-cart pill), so the re-order badge
  /// beside it knows where to stop.
  static const double w = CompactProductCard.stepperW;

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final qty = cart.quantityOf(product.id);

    if (qty > 0) {
      return _Stepper(
        key: const ValueKey('stepper'),
        qty: qty,
        onMinus: () => cart.decrementId(product.id),
        onPlus: () => cart.incrementId(product.id),
      );
    }
    final a = product.availability;
    final label = a?.ctaShort.isNotEmpty == true
        ? a!.ctaShort
        : (a?.ctaLabel ?? '');
    return _PlusButton(
      key: const ValueKey('add'),
      label: label,
      onTap: () {
        if (cart.isPending(product.id)) return;
        cart.addId(product.id);
        // Fire-and-forget popularity ping. It must never be able to break an
        // add-to-cart: the cart write above is the real work.
        try {
          MedicineRepository().incrementSalesCount(product.id);
        } catch (_) {}
      },
    );
  }
}

/// The round brand + — a 36px circle inside a 44×44 tap box.
class _PlusButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PlusButton({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: CompactProductCard.pillH,
      height: CompactProductCard.pillH,
      child: Center(
        child: Material(
          color: Ds.c.brand,
          shape: const CircleBorder(),
          elevation: 0,
          child: InkWell(
            key: const ValueKey('card-plus'),
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: CompactProductCard.plusDot,
              height: CompactProductCard.plusDot,
              child: Icon(
                Icons.add_rounded,
                size: Ds.space.x24,
                color: Ds.c.surface,
              ),
            ),
          ),
        ),
      ),
    );
    return Semantics(
      identifier: 'card_plus',
      button: true,
      label: label,
      child: label.isEmpty ? button : Tooltip(message: label, child: button),
    );
  }
}

/// In the cart: the filled − n + pill, same corner, same 44pt height.
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
    return SizedBox(
      height: CompactProductCard.pillH,
      width: CompactProductCard.stepperW,
      child: Center(
        child: Material(
          color: Ds.c.brand,
          borderRadius: BorderRadius.circular(Rad.pill),
          child: SizedBox(
            height: CompactProductCard.plusDot,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StepIcon(icon: Icons.remove_rounded, onTap: onMinus),
                Text(
                  '$qty',
                  style: AppType.l4.copyWith(
                    color: Ds.c.surface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                _StepIcon(icon: Icons.add_rounded, onTap: onPlus),
              ],
            ),
          ),
        ),
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
    customBorder: const CircleBorder(),
    child: SizedBox(
      width: CompactProductCard.plusDot,
      height: CompactProductCard.plusDot,
      child: Icon(icon, size: Ds.space.x16, color: Ds.c.surface),
    ),
  );
}

/// A small tinted chip that hugs its label — the scheme badge on the plate.
/// Colours are the payload's, resolved by the caller.
class _MiniChip extends StatelessWidget {
  final String text;
  final Color bgColor;
  final Color fgColor;

  const _MiniChip({
    required this.text,
    required this.bgColor,
    required this.fgColor,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: Ds.space.x8,
      vertical: Ds.space.x4,
    ),
    decoration: BoxDecoration(
      color: bgColor,
      borderRadius: BorderRadius.circular(Rad.chip),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppType.t2.copyWith(color: fgColor, fontWeight: FontWeight.w700),
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
          child: CardSaleLine(price: p, height: priceHeight),
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
/// the catalogue one, 28 on the product page). The badge is EXACTLY that tall
/// rather than padded to whatever its font needs, which is what keeps one
/// widget safe inside grids whose rows are different heights.
///
/// CMD #2040 — it is public, and the product page's price block prints it too:
/// "the same green PTR badge as cards" in the spec means the same WIDGET, not a
/// second one that looks like it.
class CardSaleLine extends StatelessWidget {
  final CardPrice price;
  final double height;

  /// CMD #2073 — the product page draws this row in ONE type with the company,
  /// the pack line and the MRP above it, so it hands its own style down rather
  /// than growing a second copy of the widget. Null is the card's own type,
  /// which is what every grid still gets.
  final TextStyle? labelStyle;
  final TextStyle? valueStyle;

  /// CMD #2122 — the grid card prints the locked pill alone; the product page
  /// keeps the backend's caption beside it.
  final bool showLabel;

  const CardSaleLine({
    super.key,
    required this.price,
    required this.height,
    this.labelStyle,
    this.valueStyle,
    this.showLabel = true,
  });

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
              style: (valueStyle ??
                      AppType.l5.copyWith(fontWeight: FontWeight.w800))
                  .copyWith(
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
        if (showLabel && price.saleLabel.isNotEmpty) ...[
          Text(
            price.saleLabel,
            maxLines: 1,
            style: labelStyle ?? AppType.t1.copyWith(color: Brand.inkSub),
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

/// Skeleton with the SAME fixed geometry as the real card — one white card,
/// the plate, then the three text lines — so the swap from loading to loaded
/// moves nothing.
class CompactCardSkeleton extends StatelessWidget {
  const CompactCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Container(
    height: CompactProductCard.extent,
    decoration: BoxDecoration(
      color: Ds.c.surface,
      borderRadius: BorderRadius.circular(Rad.card),
      border: Border.all(color: Ds.c.divider),
    ),
    padding: const EdgeInsets.all(CompactProductCard.imgPad),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonBox(
          width: double.infinity,
          height: CompactProductCard.tileH - CompactProductCard.imgPad * 2,
          radius: Rad.tile,
        ),
        SizedBox(height: CompactProductCard._padX),
        SkeletonBox(width: double.infinity, height: CompactProductCard._packH),
        SizedBox(height: CompactProductCard._gapL),
        SkeletonBox(width: 96, height: CompactProductCard._packH),
        SizedBox(height: CompactProductCard._gapL),
        SkeletonBox(width: 72, height: CompactProductCard._packH),
      ],
    ),
  );
}

/// CMD #2040 — the wishlist heart, in the corner the Rx chip used to hold.
///
/// Everything it knows arrives in the card payload's `wish` block
/// (`card_wish()` in Postgres): whether this viewer is offered a wishlist at
/// all, whether this pack is already saved, and the word for each state. The
/// widget decides nothing — it paints a filled heart or an outlined one and
/// sends the tap to `wishlist_toggle`, whose answer (including the toast) is
/// the only thing that can change what it shows.
///
/// The optimistic flip that would normally go here is deliberately absent: a
/// save that the server refused must not leave a filled heart behind, so the
/// state moves when the RPC says it moved and not before.
class _WishHeart extends StatefulWidget {
  final Product product;
  final Future<WishlistResult> Function(String productId)? toggle;

  const _WishHeart({required this.product, required this.toggle});

  @override
  State<_WishHeart> createState() => _WishHeartState();
}

class _WishHeartState extends State<_WishHeart> {
  late bool _saved = widget.product.isWishlisted;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant _WishHeart old) {
    super.didUpdateWidget(old);
    // A fresh payload is the authority: the grid rebuilt with a newer
    // card_wish block and the heart follows it.
    if (old.product.isWishlisted != widget.product.isWishlisted) {
      _saved = widget.product.isWishlisted;
    }
  }

  Future<void> _tap() async {
    if (_busy) return;
    setState(() => _busy = true);
    WishlistResult res;
    try {
      final call =
          widget.toggle ?? (id) => MedicineRepository().wishlistToggle(id);
      res = await call(widget.product.id);
    } catch (_) {
      res = WishlistResult.failed;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.loginRequired) {
      Navigator.of(context).pushNamed('/login');
      return;
    }
    if (!res.ok) return;
    setState(() => _saved = res.isWishlisted);
    if (res.toast.isNotEmpty) showToast(context, res.toast);
  }

  @override
  Widget build(BuildContext context) {
    final label = _saved
        ? widget.product.wishRemoveLabel
        : widget.product.wishAddLabel;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: _tap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: CompactProductCard.wishTapSize,
            height: CompactProductCard.wishTapSize,
            child: Center(
              child: Container(
                width: CompactProductCard.wishDotSize,
                height: CompactProductCard.wishDotSize,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: Ds.elevation.e1,
                ),
                child: Icon(
                  _saved ? Icons.favorite : Icons.favorite_border,
                  key: ValueKey(_saved ? 'wish-on' : 'wish-off'),
                  size: Ds.space.x16,
                  color: _saved ? Ds.c.danger : Ds.c.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
          horizontal: Ds.space.x8,
          vertical: Ds.space.x4,
        ),
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
