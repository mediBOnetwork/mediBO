import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../models/product.dart';
import '../models/product_card_view.dart';
import '../models/storefront_p3.dart' show NotifyResult, WishlistResult;
import '../utils/toast.dart';
import '../theme.dart';
import 'animations.dart';
import 'card_pack_icon.dart';
import 'ds_tone.dart';
import 'notify_control.dart';
import 'product_image.dart';
import 'qty_picker.dart';
import '../utils/render_log.dart';

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

  /// CMD #2146 — v5: the pack chip and the in-cart qty chip share ONE size
  /// (28 tall, radius 8); the + is a 38 circle. Tap boxes stay 44.
  static const double chipH = 28;
  static const double plusDotV5 = 38;

  /// CMD #2160 — v6: every chip on the plate (pack, Unavailable, scheme) is
  /// 26 tall; the action spot (+, qty pill, Notify) is always 36.
  static const double chipV6 = 26;
  static const double actionV6 = 36;

  /// v6 text block: name max 2 × 18 + composition 16 — three lines, fixed.
  static const double nameLineV6 = 18;
  static const double subLineV6 = 16;
  static const double textV6 = nameLineV6 * 2 + subLineV6; // 52

  /// Everything under the plate on v6: 8 · text · 8 · price · bottom pad.
  static const double bodyV6 = _gapL + textV6 + _gapL + _priceH + _padBottom;

  /// The tallest the v6 plate may be inside [extent]; below this width the
  /// plate is exactly square (the card's own width).
  static const double plateMaxV6 = extent - _frameBorderW * 2 - bodyV6; // 174

  /// Hero tag shared with the product page's first carousel image.
  static String heroTag(String id) => 'pd-img-$id';

  @override
  Widget build(BuildContext context) {
    final view = ProductCardView.of(product);
    final av = product.availability;

    // The backend's verdict, not a stock number. `canAdd` false is the only
    // out-of-stock signal; the app never compares supplier counts.
    final soldOut = av != null && !av.canAdd;

    // CMD #2146 — Product card v5: the card's colours are the payload's
    // `style` block (photo_bg / text_bg / border), never typed here.
    final v5 = view.v5;

    // CMD #2160 — Product card v6: a square plate, the fixed 3-line text
    // block, the price row at one height on every card.
    final v6 = v5?.v6;
    final Widget card = v5 != null && v6 != null
        ? _V6Card(
            product: product,
            view: view,
            v5: v5,
            v6: v6,
            soldOut: soldOut,
            onTap: onTap,
            onPeek: onPeek,
            wishlistToggle: wishlistToggle,
          )
        : Container(
      height: extent,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: v5 == null ? Ds.c.surface : Ds.hex(v5.textBg, Ds.c.surface),
        borderRadius: v5 == null ? BorderRadius.circular(Rad.card) : Ds.r.rCard,
        border: Border.all(
          color: v5 == null ? Ds.c.divider : Ds.hex(v5.border, Ds.c.divider),
          width: _frameBorderW,
        ),
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
              Container(
                height: tileH,
                color: v5 == null ? null : Ds.hex(v5.photoBg, Ds.c.surface),
                child: v5 != null
                    ? _V5Artwork(
                        product: product,
                        view: view,
                        v5: v5,
                        soldOut: soldOut,
                        wishlistToggle: wishlistToggle,
                      )
                    : _Artwork(
                        product: product,
                        view: view,
                        soldOut: soldOut,
                        wishlistToggle: wishlistToggle,
                      ),
              ),
              if (v5 != null)
                Padding(
                  padding: const EdgeInsets.only(left: _padX, top: _gapL, right: _padX),
                  child: _V5Body(product: product, view: view, v5: v5),
                )
              else
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
                      child: _CardFoot(
                        product: product,
                        view: view,
                        soldOut: soldOut,
                      ),
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

  /// CMD #2146 — v5 prints the MRP in the payload's `mrp_fg` and strikes it
  /// whenever `mrp_struck` says so. Null keeps the older grey.
  final Color? mrpColor;
  final bool forceStrike;

  /// CMD #2160 — v6 strikes the MRP with ONE slanted line (−8°, 1.5 grey)
  /// instead of the font's flat line-through.
  final bool slantStrike;

  const CardPriceRow({
    super.key,
    required this.price,
    required this.height,
    this.mrpColor,
    this.forceStrike = false,
    this.slantStrike = false,
  });

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
    final struck = p.strikeMrp || forceStrike;
    final Widget? mrp = !p.hasMrp
        ? null
        : slantStrike
        ? SlantStrike(
            struck: struck,
            color: Ds.c.textSecondary,
            child: Text(
              p.mrpDisplay,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.l5.copyWith(
                color: mrpColor ?? Brand.inkFaint,
                fontWeight: FontWeight.w500,
              ),
            ),
          )
        : Text(
            p.mrpDisplay,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.t1.copyWith(
              color: mrpColor ?? Brand.inkFaint,
              decoration: struck
                  ? TextDecoration.lineThrough
                  : TextDecoration.none,
              decorationColor: mrpColor ?? Brand.inkFaint,
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
          child: soldOut && CardAction.of(product.card) != null
              ? SizedBox(
                  height: CompactProductCard.pillH,
                  child: Center(
                    child: CardNotifyButton(
                      productId: product.id,
                      action: CardAction.of(product.card)!,
                    ),
                  ),
                )
              : soldOut
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

    // CMD #2124 — a card that carries `action` opens the ONE qty picker from
    // the + and shows the chosen quantity on a pill that reopens it.
    final action = CardAction.of(product.card);
    if (action != null) {
      try {
        RenderLog.write('c2124_card_action', qty > 0 ? 'pill' : 'plus');
      } catch (_) {}
      Future<void> pick() async {
        if (cart.isPending(product.id)) return;
        final picked = await showCardQtyPicker(
          context,
          packType: action.packType,
          current: qty,
          rpc: action.pickerRpc.isEmpty ? 'card_qty_picker' : action.pickerRpc,
        );
        if (picked == null || picked.value == qty) return;
        cart.setQuantityId(product.id, picked.value);
        if (qty == 0 && picked.value > 0) {
          try {
            MedicineRepository().incrementSalesCount(product.id);
          } catch (_) {}
        }
      }

      final v5 = product.card?['style'] is Map;
      final v6 = v5 && product.card?['v6'] is Map;
      if (qty > 0) {
        return v6
            ? _QtyChip(
                key: const ValueKey('qty-chip'),
                label: action.pillLabelV6(qty),
                onTap: pick,
                height: CompactProductCard.actionV6,
                radius: CompactProductCard.actionV6 / 2,
              )
            : v5
            ? _QtyChip(
                key: const ValueKey('qty-chip'),
                label: action.pillLabel(qty),
                onTap: pick,
              )
            : _QtyPill(
                key: const ValueKey('qty-pill'),
                label: action.pillLabel(qty),
                onTap: pick,
              );
      }
      final a = product.availability;
      return _PlusButton(
        key: const ValueKey('add'),
        label: a?.ctaShort.isNotEmpty == true ? a!.ctaShort : (a?.ctaLabel ?? ''),
        onTap: pick,
        dot: v6
            ? CompactProductCard.actionV6
            : v5
            ? CompactProductCard.plusDotV5
            : CompactProductCard.plusDot,
      );
    }

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
  final double dot;
  const _PlusButton({
    super.key,
    required this.label,
    required this.onTap,
    this.dot = CompactProductCard.plusDot,
  });

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
              width: dot,
              height: dot,
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
      // CMD #2146 — on the grid card the pill hugs its word so the struck MRP
      // sits right beside it.
      mainAxisSize: showLabel ? MainAxisSize.max : MainAxisSize.min,
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

/// CMD #2124 — the chosen quantity on the button: a filled brand pill
/// ("5 strip ⌄") in the +'s corner. The words are the backend's template
/// filled with the cart's number; tapping it reopens the qty picker.
class _QtyPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _QtyPill({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: 'card_qty_pill',
      button: true,
      label: label,
      child: SizedBox(
        height: CompactProductCard.pillH,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: CompactProductCard.stepperW),
            child: Material(
              color: Ds.c.brand,
              borderRadius: BorderRadius.circular(Rad.pill),
              child: InkWell(
                key: const ValueKey('card-qty-pill'),
                borderRadius: BorderRadius.circular(Rad.pill),
                onTap: onTap,
                child: SizedBox(
                  height: CompactProductCard.plusDot,
                  child: Padding(
                    padding: EdgeInsets.only(left: Ds.space.x12, right: Ds.space.x8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              label,
                              maxLines: 1,
                              style: AppType.l4.copyWith(
                                color: Ds.c.surface,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: Ds.space.x4),
                        Icon(Icons.keyboard_arrow_down_rounded,
                            size: Ds.space.x16, color: Ds.c.surface),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// CMD #2124 — the ids the viewer asked to be told about in this session, so
/// the button and the foot line of every card showing that pack flip together
/// the moment `stock_notify_request` says subscribed. The backend's own
/// `notified` flag covers every later read.
class CardNotifyLedger {
  static final ValueNotifier<Set<String>> notified = ValueNotifier(<String>{});
  static void mark(String id) =>
      notified.value = {...notified.value, id};
}

/// CMD #2124 — unavailable: an outlined "🔔 Notify" that becomes "✓ Notified".
/// Labels are `card.action.notify`'s; the toast is the RPC's own.
class CardNotifyButton extends StatefulWidget {
  final String productId;
  final CardAction action;
  final Future<NotifyResult> Function(String productId)? request;
  const CardNotifyButton({
    super.key,
    required this.productId,
    required this.action,
    this.request,
  });

  @override
  State<CardNotifyButton> createState() => _CardNotifyButtonState();
}

class _CardNotifyButtonState extends State<CardNotifyButton> {
  bool _busy = false;

  Future<void> _tap() async {
    if (_busy) return;
    setState(() => _busy = true);
    final req = widget.request ??
        (id) => MedicineRepository().stockNotifyRequest(id);
    NotifyResult? r;
    try {
      r = await req(widget.productId);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted || r == null) return;
    if (r.loginRequired) {
      Navigator.of(context).pushNamed('/login');
      return;
    }
    if (r.toast.isNotEmpty) showToast(context, r.toast, isError: !r.ok);
    if (r.ok && r.subscribed) CardNotifyLedger.mark(widget.productId);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: CardNotifyLedger.notified,
      builder: (context, ids, _) {
        final done = widget.action.notified || ids.contains(widget.productId);
        final label = done ? widget.action.notifiedLabel : widget.action.notifyLabel;
        if (label.isEmpty) return const SizedBox.shrink();
        final fg = Ds.c.danger;
        return Semantics(
          identifier: done ? 'card_notified' : 'card_notify',
          button: !done,
          label: label,
          child: Material(
            color: done ? Ds.c.dangerSoft : Ds.c.surface,
            shape: StadiumBorder(
              side: done ? BorderSide.none : BorderSide(color: fg),
            ),
            child: InkWell(
              key: const ValueKey('card-notify'),
              customBorder: const StadiumBorder(),
              onTap: done ? null : _tap,
              child: SizedBox(
                height: CompactProductCard.plusDot,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        done ? Icons.check_rounded : Icons.notifications_rounded,
                        size: Ds.space.x16,
                        color: fg,
                      ),
                      SizedBox(width: Ds.space.x4),
                      Text(
                        label,
                        maxLines: 1,
                        style: AppType.l5.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The ONE line under the price. A `card.action` payload re-picks it from the
/// backend's own lines as the cart and the notify request move; an older
/// payload prints its `foot` as it always did.
class _CardFoot extends StatelessWidget {
  final Product product;
  final ProductCardView view;
  final bool soldOut;
  const _CardFoot({
    required this.product,
    required this.view,
    required this.soldOut,
  });

  Widget _line(String label, String tone) => label.isEmpty
      ? const SizedBox.shrink()
      : Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.t2.copyWith(
            color: dsToneFg(tone),
            fontWeight: tone == 'muted' ? FontWeight.w400 : FontWeight.w600,
          ),
        );

  @override
  Widget build(BuildContext context) {
    final action = CardAction.of(product.card);
    if (action == null) {
      return view.hasFoot
          ? _line(view.footLabel, view.footTone)
          : const SizedBox.shrink();
    }
    if (soldOut) {
      return ValueListenableBuilder<Set<String>>(
        valueListenable: CardNotifyLedger.notified,
        builder: (_, ids, _) {
          final (l, t) = action.foot(
            view: view,
            soldOut: true,
            notifiedNow: ids.contains(product.id),
            qty: 0,
          );
          return _line(l, t);
        },
      );
    }
    final qty = AppState.of(context).quantityOf(product.id);
    final (l, t) =
        action.foot(view: view, soldOut: false, notifiedNow: false, qty: qty);
    return _line(l, t);
  }
}


/// CMD #2146 — v5 image plate: the photo (or, with no photo, the pack-type
/// icon from `placeholder.kind`) on the payload's photo_bg; the pack chip
/// top-left, the heart top-right where Rx was (no Rx / OTC on the card), the
/// scheme tag bottom-left, and the one control bottom-right — the + (which
/// opens the qty sheet), the in-cart qty chip, or Notify me / We'll notify.
class _V5Artwork extends StatelessWidget {
  final Product product;
  final ProductCardView view;
  final CardV5 v5;
  final bool soldOut;
  final Future<WishlistResult> Function(String productId)? wishlistToggle;

  const _V5Artwork({
    required this.product,
    required this.view,
    required this.v5,
    required this.soldOut,
    required this.wishlistToggle,
  });

  static const double _edge = CompactProductCard._gapL;
  static const double _art =
      CompactProductCard.tileH - CompactProductCard.imgPad * 2;

  @override
  Widget build(BuildContext context) {
    final action = CardAction.of(product.card);
    final art = v5.imagePlaceholder || product.imageUrl.isEmpty
        ? Center(
            child: CardPackIcon(
              kind: v5.placeholderKind,
              size: Ds.space.x48 + Ds.space.x16,
              iconUrl: v5.placeholderIconUrl,
              color: Ds.hex(v5.placeholderFg, Ds.c.textSecondary),
            ),
          )
        : Hero(
            tag: CompactProductCard.heroTag(product.id),
            child: ProductImage(
              url: product.imageUrl,
              width: _art,
              height: _art,
              radius: BorderRadius.circular(Rad.tile),
            ),
          );
    return Stack(
      children: [
        Positioned.fill(
          child: Opacity(
            opacity: soldOut ? 0.45 : 1.0,
            child: Padding(
              padding: const EdgeInsets.only(
                left: CompactProductCard.imgPad,
                right: CompactProductCard.imgPad,
                top: CompactProductCard.imgPad + CompactProductCard._gapL,
                bottom: CompactProductCard.imgPad,
              ),
              child: Center(child: art),
            ),
          ),
        ),
        if (v5.hasPackChip)
          Positioned(
            left: _edge,
            top: _edge,
            right: CompactProductCard.wishTapSize,
            child: Row(
              children: [
                Flexible(child: _V5PackChip(label: v5.packChip)),
              ],
            ),
          ),
        if (product.hasWish)
          Positioned(
            right: 0,
            top: 0,
            child: _WishHeart(product: product, toggle: wishlistToggle),
          ),
        if (view.hasOffer)
          Positioned(
            left: _edge,
            bottom: _edge,
            right: CompactProductCard.pillH + _edge,
            child: Row(
              children: [
                Flexible(
                  child: _MiniChip(
                    text: view.offerLabel,
                    bgColor: _Artwork._col(view.offerBg, Ds.c.successSoft),
                    fgColor: _Artwork._col(view.offerFg, Ds.c.success),
                  ),
                ),
              ],
            ),
          ),
        Positioned(
          right: CompactProductCard._gapS,
          bottom: CompactProductCard._gapS,
          left: soldOut ? CompactProductCard._gapS : null,
          child: soldOut && action != null
              ? SizedBox(
                  height: CompactProductCard.pillH,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _V5NotifyChip(productId: product.id, action: action),
                  ),
                )
              : soldOut
              ? const SizedBox.shrink()
              : CompactCartControl(product: product),
        ),
      ],
    );
  }
}

/// The pack chip ("Strip of 10", "60 ml bottle") — `card.pack_chip.label`
/// verbatim, 28 tall, radius 8.
class _V5PackChip extends StatelessWidget {
  final String label;
  const _V5PackChip({required this.label});

  @override
  Widget build(BuildContext context) => Semantics(
        identifier: 'card_pack_chip',
        child: Container(
          height: CompactProductCard.chipH,
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: BorderRadius.circular(Ds.space.x8),
            border: Border.all(color: Ds.c.divider),
          ),
          // No alignment: the chip hugs its label instead of spanning the plate.
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.t2.copyWith(
                color: Ds.c.text,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
}

/// In the cart: the qty chip ("2 strip ⌄") — the SAME 28px / radius 8 as the
/// pack chip, filled brand. Opens the same qty sheet as the +.
class _QtyChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  /// CMD #2160 — v6 draws the pill at the 36 action height, fully rounded.
  final double height;
  final double? radius;
  const _QtyChip({
    super.key,
    required this.label,
    required this.onTap,
    this.height = CompactProductCard.chipH,
    this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius ?? Ds.space.x8);
    return Semantics(
      identifier: 'card_qty_pill',
      button: true,
      label: label,
      child: SizedBox(
        height: CompactProductCard.pillH,
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: CompactProductCard.stepperW),
            child: Material(
              color: Ds.c.brand,
              borderRadius: r,
              child: InkWell(
                key: const ValueKey('card-qty-pill'),
                borderRadius: r,
                onTap: onTap,
                child: SizedBox(
                  height: height,
                  child: Padding(
                    padding: EdgeInsets.only(
                        left: radius == null ? Ds.space.x8 : Ds.space.x12,
                        right: radius == null ? Ds.space.x4 : Ds.space.x8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              label,
                              maxLines: 1,
                              style: (radius == null ? AppType.t2 : AppType.l5).copyWith(
                                color: Ds.c.surface,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        Icon(Icons.keyboard_arrow_down_rounded,
                            size: Ds.space.x16, color: Ds.c.surface),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Out of stock on v5: an outlined "Notify me" chip that becomes a tinted
/// "We'll notify" — both words are `card.action.notify`'s, the toast is the
/// RPC's own. Same 28px chip geometry as the pack chip, inside a 44 tap box.
class _V5NotifyChip extends StatefulWidget {
  final String productId;
  final CardAction action;
  const _V5NotifyChip({required this.productId, required this.action});

  @override
  State<_V5NotifyChip> createState() => _V5NotifyChipState();
}

class _V5NotifyChipState extends State<_V5NotifyChip> {
  bool _busy = false;

  Future<void> _tap() async {
    if (_busy) return;
    setState(() => _busy = true);
    NotifyResult? r;
    try {
      r = await MedicineRepository().stockNotifyRequest(widget.productId);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted || r == null) return;
    if (r.loginRequired) {
      Navigator.of(context).pushNamed('/login');
      return;
    }
    if (r.toast.isNotEmpty) showToast(context, r.toast, isError: !r.ok);
    if (r.ok && r.subscribed) CardNotifyLedger.mark(widget.productId);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: CardNotifyLedger.notified,
      builder: (context, ids, _) {
        final done = widget.action.notified || ids.contains(widget.productId);
        final label =
            done ? widget.action.notifiedLabel : widget.action.notifyLabel;
        if (label.isEmpty) return const SizedBox.shrink();
        final r = BorderRadius.circular(Ds.space.x8);
        final fg = Ds.c.brand;
        return Semantics(
          identifier: done ? 'card_notified' : 'card_notify',
          button: !done,
          label: label,
          child: SizedBox(
            height: CompactProductCard.pillH,
            child: Center(
              child: Material(
                color: done ? Ds.c.brandSoft : Ds.c.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: r,
                  side: done ? BorderSide.none : BorderSide(color: fg),
                ),
                child: InkWell(
                  key: const ValueKey('card-notify'),
                  borderRadius: r,
                  onTap: done ? null : _tap,
                  child: SizedBox(
                    height: CompactProductCard.chipH,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            done
                                ? Icons.check_rounded
                                : Icons.notifications_none_rounded,
                            size: Ds.space.x16,
                            color: fg,
                          ),
                          SizedBox(width: Ds.space.x4),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.t2.copyWith(
                                color: fg,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// CMD #2146 — v5 text area: name + sub line share `layout.text_lines`
/// (a 1-line name leaves 2 sub lines, a 2-line name leaves 1, then "…"),
/// then the price row (PTR pill or own rate + MRP struck in `mrp_fg`), then
/// the foot line ONLY when `foot.has` — otherwise nothing under the price.
/// Every row keeps its fixed height, so every card is the same height.
class _V5Body extends StatelessWidget {
  final Product product;
  final ProductCardView view;
  final CardV5 v5;
  const _V5Body({required this.product, required this.view, required this.v5});

  static const double _textH = CompactProductCard._nameH +
      CompactProductCard._gapS +
      CompactProductCard._packH;

  @override
  Widget build(BuildContext context) {
    final nameStyle = AppType.l5.copyWith(
      fontWeight: FontWeight.w700,
      height: 18 / 12,
      color: Ds.hex(v5.nameFg, Ds.c.text),
    );
    final subStyle = AppType.t1.copyWith(color: Ds.hex(v5.subFg, Ds.c.text));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _textH,
          child: LayoutBuilder(
            builder: (context, c) {
              final tp = TextPainter(
                text: TextSpan(text: product.name, style: nameStyle),
                maxLines: v5.nameMaxLines,
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
              )..layout(maxWidth: c.maxWidth);
              final nameLines =
                  tp.computeLineMetrics().length.clamp(1, v5.nameMaxLines);
              final subLines = v5.hasSubLine ? v5.subLinesFor(nameLines) : 0;
              return ClipRect(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      maxLines: nameLines,
                      overflow: TextOverflow.ellipsis,
                      style: nameStyle,
                    ),
                    if (subLines > 0)
                      Semantics(
                        identifier: 'card_sub_line',
                        child: Text(
                          v5.subLine,
                          maxLines: subLines,
                          overflow: TextOverflow.ellipsis,
                          style: subStyle,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: CompactProductCard._gapM),
        SizedBox(
          height: CompactProductCard._priceH,
          child: CardPriceRow(
            price: view.price,
            height: CompactProductCard._priceH,
            mrpColor: Ds.hex(v5.mrpFg, Ds.c.text),
            forceStrike: v5.mrpStruck,
          ),
        ),
        if (v5.hasFoot) ...[
          const SizedBox(height: CompactProductCard._gapS),
          SizedBox(
            height: CompactProductCard._footH,
            child: Text(
              view.footLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.t2.copyWith(
                color: dsToneFg(view.footTone),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}


// ── CMD #2160 — Product card v6 ────────────────────────────────────────────

/// The v6 card: a square white plate the full card width (capped at
/// [CompactProductCard.plateMaxV6] so the card still fits [extent]), then
/// the fixed 3-line text block 8 below it and the price row 8 under that —
/// the same height on every card, so PTR and MRP never move.
class _V6Card extends StatelessWidget {
  final Product product;
  final ProductCardView view;
  final CardV5 v5;
  final CardV6 v6;
  final bool soldOut;
  final VoidCallback onTap;
  final VoidCallback? onPeek;
  final Future<WishlistResult> Function(String productId)? wishlistToggle;

  const _V6Card({
    required this.product,
    required this.view,
    required this.v5,
    required this.v6,
    required this.soldOut,
    required this.onTap,
    required this.onPeek,
    required this.wishlistToggle,
  });

  @override
  Widget build(BuildContext context) {
    try {
      RenderLog.write('c2160_card_v6', soldOut ? 'unavailable' : 'live');
    } catch (_) {}
    return Container(
      height: CompactProductCard.extent,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Ds.hex(v5.textBg, Ds.c.surface),
        borderRadius: Ds.r.rCard,
        border: Border.all(
          color: Ds.hex(v5.border, Ds.c.divider),
          width: CompactProductCard._frameBorderW,
        ),
        boxShadow: Ds.elevation.e1,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onPeek,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth.isFinite
                  ? c.maxWidth
                  : CompactProductCard.railWidth;
              final plate = w < CompactProductCard.plateMaxV6
                  ? w
                  : CompactProductCard.plateMaxV6;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: plate,
                    width: double.infinity,
                    color: Ds.hex(v5.photoBg, Ds.c.surface),
                    child: _V6Artwork(
                      product: product,
                      v5: v5,
                      v6: v6,
                      soldOut: soldOut,
                      plate: plate,
                      wishlistToggle: wishlistToggle,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(
                      left: CompactProductCard._padX,
                      top: CompactProductCard._gapL,
                      right: CompactProductCard._padX,
                    ),
                    child: _V6Body(product: product, view: view, v5: v5),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The square plate: the photo contained in a centred square [CardV6.imagePct]
/// of the plate (never cropped, no border) — or, with no photo or a dead URL,
/// the pack-type placeholder from `placeholder.kind`. Pack chip (or the
/// backend's "Unavailable" chip) top-left, heart top-right, scheme badge
/// bottom-left, the 36 action bottom-right.
class _V6Artwork extends StatelessWidget {
  final Product product;
  final CardV5 v5;
  final CardV6 v6;
  final bool soldOut;
  final double plate;
  final Future<WishlistResult> Function(String productId)? wishlistToggle;

  const _V6Artwork({
    required this.product,
    required this.v5,
    required this.v6,
    required this.soldOut,
    required this.plate,
    required this.wishlistToggle,
  });

  static const double _edge = CompactProductCard._gapL;

  @override
  Widget build(BuildContext context) {
    final action = CardAction.of(product.card);
    final side = plate * v6.imagePct / 100;
    final placeholder = Center(
      child: CardPackIcon(
        kind: v5.placeholderKind,
        size: Ds.space.x48 + Ds.space.x16,
        iconUrl: v5.placeholderIconUrl,
        color: Ds.hex(v5.placeholderFg, Ds.c.textSecondary),
      ),
    );
    final art = v5.imagePlaceholder || product.imageUrl.isEmpty
        ? placeholder
        : Hero(
            tag: CompactProductCard.heroTag(product.id),
            child: ProductImage(
              url: product.imageUrl,
              width: side,
              height: side,
              errorChild: placeholder,
            ),
          );
    final unavail = soldOut && v6.hasUnavailChip;
    return Stack(
      children: [
        Positioned.fill(
          child: Opacity(
            opacity: soldOut ? 0.45 : 1.0,
            child: Center(
              child: SizedBox(width: side, height: side, child: art),
            ),
          ),
        ),
        if (unavail || v5.hasPackChip)
          Positioned(
            left: _edge,
            top: _edge,
            right: CompactProductCard.wishTapSize,
            child: Row(
              children: [
                Flexible(
                  child: unavail
                      ? _V6Chip(
                          id: 'card_unavailable_chip',
                          label: v6.unavailLabel,
                          bg: Ds.hex(v6.unavailBg, Ds.c.dangerSoft),
                          fg: Ds.hex(v6.unavailFg, Ds.c.danger),
                        )
                      : _V6Chip(
                          id: 'card_pack_chip',
                          label: v5.packChip,
                          bg: Ds.c.surface,
                          fg: Ds.c.text,
                          border: Ds.c.divider,
                        ),
                ),
              ],
            ),
          ),
        if (product.hasWish)
          Positioned(
            right: 0,
            top: 0,
            child: _WishHeart(product: product, toggle: wishlistToggle),
          ),
        if (v6.hasScheme)
          Positioned(
            left: _edge,
            bottom: _edge + (CompactProductCard.actionV6 - CompactProductCard.chipV6) / 2,
            right: CompactProductCard.pillH + _edge,
            child: Row(
              children: [
                Flexible(
                  child: _V6Chip(
                    id: 'card_scheme_badge',
                    label: v6.schemeLabel,
                    bg: Ds.hex(v6.schemeBg, Ds.c.warningSoft),
                    fg: Ds.hex(v6.schemeFg, Ds.c.warning),
                  ),
                ),
              ],
            ),
          ),
        Positioned(
          right: CompactProductCard._gapS,
          bottom: CompactProductCard._gapS,
          left: soldOut ? CompactProductCard._gapS : null,
          child: soldOut && action != null
              ? SizedBox(
                  height: CompactProductCard.pillH,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _V6NotifyPill(
                      productId: product.id,
                      action: action,
                      bg: Ds.hex(v6.notifyBg, Ds.c.danger),
                      fg: Ds.hex(v6.notifyFg, Ds.c.surface),
                    ),
                  ),
                )
              : soldOut
              ? const SizedBox.shrink()
              : CompactCartControl(product: product),
        ),
      ],
    );
  }
}

/// One 26-tall chip on the plate — pack, Unavailable or scheme — hugging its
/// backend label.
class _V6Chip extends StatelessWidget {
  final String id;
  final String label;
  final Color bg;
  final Color fg;
  final Color? border;
  const _V6Chip({
    required this.id,
    required this.label,
    required this.bg,
    required this.fg,
    this.border,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: id,
    label: label,
    child: Container(
      height: CompactProductCard.chipV6,
      padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Ds.space.x8),
        border: border == null ? null : Border.all(color: border!),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.t2.copyWith(color: fg, fontWeight: FontWeight.w700),
        ),
      ),
    ),
  );
}

/// Out of stock on v6: the red 36 pill "Notify me" that becomes the SAME red
/// "We'll notify ✓" — both words `card.action.notify`'s, colours
/// `v6.notify_pill`'s, the toast the RPC's own.
class _V6NotifyPill extends StatefulWidget {
  final String productId;
  final CardAction action;
  final Color bg;
  final Color fg;
  const _V6NotifyPill({
    required this.productId,
    required this.action,
    required this.bg,
    required this.fg,
  });

  @override
  State<_V6NotifyPill> createState() => _V6NotifyPillState();
}

class _V6NotifyPillState extends State<_V6NotifyPill> {
  bool _busy = false;

  Future<void> _tap() async {
    if (_busy) return;
    setState(() => _busy = true);
    NotifyResult? r;
    try {
      r = await MedicineRepository().stockNotifyRequest(widget.productId);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted || r == null) return;
    if (r.loginRequired) {
      Navigator.of(context).pushNamed('/login');
      return;
    }
    if (r.toast.isNotEmpty) showToast(context, r.toast, isError: !r.ok);
    if (r.ok && r.subscribed) CardNotifyLedger.mark(widget.productId);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: CardNotifyLedger.notified,
      builder: (context, ids, _) {
        final done = widget.action.notified || ids.contains(widget.productId);
        final label =
            done ? widget.action.notifiedLabel : widget.action.notifyLabel;
        if (label.isEmpty) return const SizedBox.shrink();
        final r = BorderRadius.circular(CompactProductCard.actionV6 / 2);
        return Semantics(
          identifier: done ? 'card_notified' : 'card_notify',
          button: !done,
          label: label,
          child: SizedBox(
            height: CompactProductCard.pillH,
            child: Center(
              child: Material(
                color: widget.bg,
                borderRadius: r,
                child: InkWell(
                  key: const ValueKey('card-notify'),
                  borderRadius: r,
                  onTap: done ? null : _tap,
                  child: SizedBox(
                    height: CompactProductCard.actionV6,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            done
                                ? Icons.check_rounded
                                : Icons.notifications_none_rounded,
                            size: Ds.space.x16,
                            color: widget.fg,
                          ),
                          SizedBox(width: Ds.space.x4),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.l5.copyWith(
                                color: widget.fg,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The fixed 3-line text block and the price row. Name max 2 lines, the
/// composition directly under it: a 2-line name leaves it 1 line, a 1-line
/// name leaves it 2 (`layout.text_lines`), "…" when cut; the spare line is
/// empty only when both fit on one. Nothing sits under the price row.
class _V6Body extends StatelessWidget {
  final Product product;
  final ProductCardView view;
  final CardV5 v5;
  const _V6Body({required this.product, required this.view, required this.v5});

  @override
  Widget build(BuildContext context) {
    final nameStyle = AppType.l4.copyWith(
      fontWeight: FontWeight.w700,
      color: Ds.hex(v5.nameFg, Ds.c.text),
    );
    final subStyle = AppType.l5.copyWith(
      fontWeight: FontWeight.w400,
      color: Ds.hex(v5.subFg, Ds.c.text),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: CompactProductCard.textV6,
          child: LayoutBuilder(
            builder: (context, c) {
              final tp = TextPainter(
                text: TextSpan(text: product.name, style: nameStyle),
                maxLines: v5.nameMaxLines,
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
              )..layout(maxWidth: c.maxWidth);
              final nameLines =
                  tp.computeLineMetrics().length.clamp(1, v5.nameMaxLines);
              final subLines = v5.hasSubLine ? v5.subLinesFor(nameLines) : 0;
              return ClipRect(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      maxLines: nameLines,
                      overflow: TextOverflow.ellipsis,
                      style: nameStyle,
                    ),
                    if (subLines > 0)
                      Semantics(
                        identifier: 'card_sub_line',
                        child: Text(
                          v5.subLine,
                          maxLines: subLines,
                          overflow: TextOverflow.ellipsis,
                          style: subStyle,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: CompactProductCard._gapL),
        SizedBox(
          height: CompactProductCard._priceH,
          child: CardPriceRow(
            price: view.price,
            height: CompactProductCard._priceH,
            mrpColor: Ds.hex(v5.mrpFg, Ds.c.text),
            forceStrike: v5.mrpStruck,
            slantStrike: true,
          ),
        ),
      ],
    );
  }
}

/// CMD #2160 — the MRP's slanted strike: one straight line across the text,
/// rising left to right at [angleDeg], [stroke] thick.
class SlantStrike extends StatelessWidget {
  final Widget child;
  final bool struck;
  final Color color;
  const SlantStrike({
    super.key,
    required this.child,
    required this.struck,
    required this.color,
  });

  static const double angleDeg = 8;
  static const double stroke = 1.5;

  @override
  Widget build(BuildContext context) => !struck
      ? child
      : Semantics(
          identifier: 'card_mrp_slant',
          child: CustomPaint(
            foregroundPainter: _SlantPainter(color),
            child: child,
          ),
        );
}

class _SlantPainter extends CustomPainter {
  final Color color;
  _SlantPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final rise = size.width / 2 * math.tan(SlantStrike.angleDeg * math.pi / 180);
    final mid = size.height / 2;
    canvas.drawLine(
      Offset(0, mid + rise),
      Offset(size.width, mid - rise),
      Paint()
        ..color = color
        ..strokeWidth = SlantStrike.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SlantPainter old) => old.color != color;
}
