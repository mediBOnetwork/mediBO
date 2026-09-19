import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/cart_model.dart';
import '../design_tokens.dart';
import '../utils/render_log.dart';
import 'product_image.dart';

/// CMD #2081 — the floating "View cart" pill, in the Blinkit shape.
///
/// One solid dark-green full-radius pill, [kHeight] tall and about
/// [kWidthFactor] of the screen wide (never narrower than [kMinWidth], never
/// wider than the room it is handed), centred over the bottom stack. Left: the
/// overlapping ringed thumbnails, then the backend's "+N" bubble when the
/// basket holds more than they show. Middle: TWO STACKED LINES. Right: one
/// chevron inside a subtle circle. There is no separator bar any more — #2043
/// needed one because both facts shared a single line, and they no longer do.
///
/// Everything it SAYS still comes from `cart_render().render.pill`: whether to
/// appear at all (`show`), the two stacked lines (`lines`, in DRAW order — the
/// backend pluralises and words them, never Dart), the thumbnail stack
/// (`thumbs`, [0] behind and the most recently added item on top) and the
/// overflow bubble (`has_more` / `more_label`). The app does not count the
/// cart, does not pick "the first image", does not work out what "+2" means
/// and does not decide what an item without a picture looks like — an empty
/// url makes [ProductImage] paint the same grey placeholder tile the product
/// cards use, which is the answer to "no image", never an empty circle.
///
/// This is the only widget in the storefront chrome that reads the cart, so a
/// cart write repaints the pill and nothing else.
class CartPill extends StatelessWidget {
  final VoidCallback onTap;
  const CartPill({super.key, required this.onTap});

  /// Geometry. Named so no bare number is written into a layout call and the
  /// whole shape can be re-proportioned in one place.
  static const double kHeight = 64;
  static const double kThumb = 40;
  static const double kThumbRing = 2;

  /// How far each further circle is pushed right of the one before it, so
  /// overlapping tiles still read as separate tiles.
  static const double kThumbOverlap = 14;
  static const double kPadLeft = 12;
  static const double kPadRight = 12;

  /// The pill is a proportion of the screen, not of its content: Blinkit's
  /// shape is a fixed bar, and a bar that changed width every time an item
  /// was added would be the thing the eye follows instead of the basket.
  static const double kWidthFactor = 0.6;

  /// …with a floor, because 60% of a 320px phone is less than two thumbnails,
  /// two lines and a chevron need. Below ~400px the floor wins and the pill
  /// simply reads a little wider. It is still clamped to the room it was
  /// handed, so it can never reach the screen edges.
  static const double kMinWidth = 240;

  /// The chevron's circle, and the glyph inside it.
  static const double kChevronBox = 32;
  static const double kChevron = 20;
  static const double kChevronAlpha = 0.18;

  /// The second line is the quieter of the two.
  static const double kSubAlpha = 0.85;
  static const double kShadowElevation = 6;
  static const double kShadowAlpha = 0.24;

  /// The gap between the pill and the bottom nav, and the inset a scrolling
  /// storefront surface reserves at its end so the last card is never left
  /// underneath the pill. One number, read by the shell (which positions the
  /// pill) and by the lists (which get out of its way), so the two can never
  /// disagree about how much room the pill takes.
  static double get bottomGap => Ds.space.x12;
  static double get bottomInset => kHeight + bottomGap * 2;

  /// The same inset as a sliver, for the `CustomScrollView` surfaces.
  static Widget get bottomInsetSliver =>
      SliverToBoxAdapter(child: SizedBox(height: bottomInset));

  /// CMD #2043 — does [page] float the pill?
  ///
  /// The shell asked `_index == 0`: a page number written in Dart, in two
  /// places, decided when Home was the only storefront surface and never
  /// revisited when the Catalogue became page 12. So a shopper inside a
  /// company or a salt list had a full cart and no way back to it.
  ///
  /// `customer_nav()` already names every surface the customer can stand on,
  /// so the answer is the slot row's own `cart_pill` and adding a surface is
  /// an UPDATE. A page with no slot floats nothing — the pill belongs to the
  /// storefront, not to whatever a pushed route happens to be showing.
  ///
  /// Until the registry answers (`slots` still empty at boot) Home alone
  /// floats it: exactly the surface it floated on before this change, so a
  /// slow nav fetch can never take away a control that was already there.
  static bool floatsOnPage(List<Map<String, dynamic>> slots, int page) {
    if (slots.isEmpty) return page == 0;
    for (final s in slots) {
      if (((s['page_index'] as num?)?.toInt() ?? 0) == page) {
        return s['cart_pill'] == true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final show = cart.pillShow;
    final thumbs = cart.pillThumbs;
    final more = cart.pillHasMore ? cart.pillMoreLabel : '';
    if (show) {
      try {
        RenderLog.write('c2029_cart_pill',
            'items=${cart.pillItemsLabel}|thumbs=${thumbs.length}');
        RenderLog.write('c2081_cart_pill',
            'lines=${cart.pillLines.length}|thumbs=${thumbs.length}|more=$more');
      } catch (_) {}
    }

    return IgnorePointer(
      ignoring: !show,
      child: AnimatedSlide(
        duration: Ds.motion.sheet,
        curve: Ds.motion.curve,
        offset: show ? Offset.zero : const Offset(0, 1.6),
        child: AnimatedOpacity(
          duration: Ds.motion.standard,
          opacity: show ? 1 : 0,
          // The Center keeps the pill in the middle of whatever width the
          // stack hands it; the padding is what stops it reaching the screen
          // edges on a 320px phone.
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            child: LayoutBuilder(
              builder: (context, box) {
                // 60% of the SCREEN (the padding above is added back), floored
                // so the content always fits and capped at the room available:
                // 320 / 360 / 412 / 480 all land inside their own screen with
                // nothing wrapped and nothing clipped.
                final screen = box.maxWidth + Ds.space.x16 * 2;
                final floor =
                    kMinWidth > box.maxWidth ? box.maxWidth : kMinWidth;
                final width =
                    (screen * kWidthFactor).clamp(floor, box.maxWidth);
                return Center(
                  child: SizedBox(
                    key: const Key('c2029_pill'),
                    width: width,
                    height: kHeight,
                    // Nothing is printed when the backend says there is no
                    // pill. An empty label is still a Text, and a hidden pill
                    // must leave no widget on the page it floats over — the
                    // product page proves it (`find.text('')` there is an
                    // assertion that the page prints no blank captions).
                    child: show
                        ? _pill(cart, thumbs, more)
                        : const SizedBox.shrink(),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(
      CartModel cart, List<Map<String, dynamic>> thumbs, String moreLabel) {
    final radius = BorderRadius.circular(kHeight / 2);
    return Material(
      color: Ds.c.brandDark,
      borderRadius: radius,
      elevation: kShadowElevation,
      shadowColor: Colors.black.withValues(alpha: kShadowAlpha),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Semantics(
          identifier: cart.pillIdentifier,
          label: cart.pillA11y,
          button: true,
          child: Padding(
            padding: const EdgeInsets.only(left: kPadLeft, right: kPadRight),
            child: Row(
              children: [
                _ThumbStack(thumbs: thumbs, moreLabel: moreLabel),
                SizedBox(width: Ds.space.x12),
                // The two stacked lines, both backend copy.
                Expanded(child: _Lines(lines: cart.pillLines)),
                SizedBox(width: Ds.space.x8),
                const _Chevron(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The two stacked lines, printed in the payload's own order: [0] is the
/// strong one, the rest sit under it. Nothing here knows what they say, and
/// nothing here counts anything.
class _Lines extends StatelessWidget {
  final List<Map<String, dynamic>> lines;
  const _Lines({required this.lines});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < lines.length; i++) {
      final text = (lines[i]['text'] ?? '').toString();
      if (text.isEmpty) continue;
      rows.add(Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: i == 0
            ? Ds.t.body.copyWith(
                color: Colors.white, fontWeight: FontWeight.w700)
            : Ds.t.caption.copyWith(
                color: Colors.white.withValues(alpha: CartPill.kSubAlpha)),
      ));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }
}

/// One chevron inside a subtle circle. #2043's hairline divider is gone with
/// the single line it separated.
class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: CartPill.kChevronBox,
      height: CartPill.kChevronBox,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: CartPill.kChevronAlpha),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.chevron_right,
          color: Colors.white, size: CartPill.kChevron),
    );
  }
}

/// The one or two overlapping thumbnails, and the backend's "+N" bubble when
/// the basket holds more than they show. One item draws one circle; the
/// backend decides how many there are, in which order they stack, and whether
/// there is an overflow at all.
class _ThumbStack extends StatelessWidget {
  final List<Map<String, dynamic>> thumbs;

  /// `more_label`, verbatim — '' when `has_more` was false. The count inside
  /// it was worked out in SQL; this widget only prints it.
  final String moreLabel;
  const _ThumbStack({required this.thumbs, this.moreLabel = ''});

  @override
  Widget build(BuildContext context) {
    final slots = thumbs.length + (moreLabel.isEmpty ? 0 : 1);
    if (slots == 0) {
      return const SizedBox(width: CartPill.kThumb, height: CartPill.kThumb);
    }
    return SizedBox(
      width: CartPill.kThumb + CartPill.kThumbOverlap * (slots - 1),
      height: CartPill.kThumb,
      child: Stack(
        children: [
          for (var i = 0; i < thumbs.length; i++)
            Positioned(
              key: Key('c2029_pill_thumb_$i'),
              left: CartPill.kThumbOverlap * i,
              top: 0,
              child: _tile(thumbs[i]),
            ),
          if (moreLabel.isNotEmpty)
            Positioned(
              key: const Key('c2081_pill_more'),
              left: CartPill.kThumbOverlap * thumbs.length,
              top: 0,
              child: _bubble(moreLabel),
            ),
        ],
      ),
    );
  }

  /// A circle of the product's own picture inside a white ring, so two
  /// overlapping tiles still read as two.
  Widget _tile(Map<String, dynamic> t) {
    final url = (t['image_url'] ?? '').toString();
    const inner = CartPill.kThumb - CartPill.kThumbRing * 2;
    return Container(
      width: CartPill.kThumb,
      height: CartPill.kThumb,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: ProductImage(
        url: url,
        width: inner,
        height: inner,
        fit: BoxFit.cover,
        radius: BorderRadius.circular(inner / 2),
      ),
    );
  }

  /// The overflow bubble: the same ringed circle as a thumbnail, so the row
  /// reads as one strip, carrying the backend's own string.
  Widget _bubble(String label) {
    return Container(
      width: CartPill.kThumb,
      height: CartPill.kThumb,
      padding: const EdgeInsets.all(CartPill.kThumbRing),
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: Ds.c.brand, shape: BoxShape.circle),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: EdgeInsets.all(Ds.space.x4),
              child: Text(
                label,
                maxLines: 1,
                style: Ds.t.caption.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// CMD #1896 — "open the cart" as a request, not a call.
///
/// The cart is a panel INSIDE HomeShell, so a screen pushed on top of the
/// shell (the product page) has no handle on it. Bumping this notifier is that
/// screen saying "the buyer asked for the cart"; HomeShell listens and opens
/// its own panel. Nothing about the cart is decided here — this carries an
/// intent, not state, which is why it is an int that only ever goes up.
///
/// CMD #2043 — restored. #2029 rewrote this file around the pill widget and
/// dropped both symbols with it, which left `home_shell.dart` and
/// `product_detail_screen.dart` referring to names that no longer existed:
/// three `undefined_identifier` errors and a `lib/` that does not compile.
/// They belong beside the pill because the pill is the other half of the same
/// intent — one asks the shell for the cart from inside it, this asks from a
/// route pushed on top of it.
final ValueNotifier<int> kOpenCartRequest = ValueNotifier<int>(0);

/// Pop back to the shell and ask it for the cart. Safe from any route depth.
void requestOpenCart(BuildContext context) {
  Navigator.of(context).popUntil((r) => r.isFirst);
  kOpenCartRequest.value = kOpenCartRequest.value + 1;
}
