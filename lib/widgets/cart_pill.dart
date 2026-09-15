import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/cart_model.dart';
import '../design_tokens.dart';
import '../utils/render_log.dart';
import 'product_image.dart';

/// CMD #2043 — the floating "View cart" pill, back to its original shape.
///
/// #2029 kept the right idea (show WHAT is in the cart, not just a count) and
/// the wrong geometry: a 90px two-line card 60% of the viewport wide, which on
/// a 360px phone sat across two rows of product cards. The thumbnails stay;
/// the shape goes back to what it was — ONE 56px line, hugging its own
/// content, centred, floating just above the bottom nav.
///
/// Everything it SAYS still comes from `cart_render().render.pill`: whether to
/// appear at all (`show`), the count wording (`items_label` — the backend
/// pluralises, never Dart), the CTA (`cta`) and the thumbnail stack (`thumbs`,
/// in DRAW order: [0] behind, [1] the most recently added item on top). The
/// app does not count the cart, does not pick "the first image" and does not
/// decide what an item without a picture looks like — an empty url makes
/// [ProductImage] paint the same grey placeholder tile the product cards use,
/// which is the answer to "no image", never an empty circle.
///
/// This is the only widget in the storefront chrome that reads the cart, so a
/// cart write repaints the pill and nothing else.
class CartPill extends StatelessWidget {
  final VoidCallback onTap;
  const CartPill({super.key, required this.onTap});

  /// Geometry. Named so no bare number is written into a layout call and the
  /// whole shape can be re-proportioned in one place.
  ///
  /// The pill is a single 56px line and its width HUGS its content — there is
  /// no width factor and no minimum any more, because both of those were ways
  /// of deciding the width from the viewport instead of from what is in it.
  static const double kHeight = 56;
  static const double kThumb = 40;
  static const double kThumbRing = 2;

  /// How far the second (newest) thumbnail is pushed right of the first, so
  /// two overlapping circles still read as two.
  static const double kThumbOverlap = 14;
  static const double kPadLeft = 12;
  static const double kPadRight = 16;
  static const double kDividerWidth = 1;
  static const double kDividerHeight = 20;
  static const double kDividerAlpha = 0.34;
  static const double kItemsSize = 16;
  static const double kChevron = 20;
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
    if (show) {
      try {
        RenderLog.write('c2029_cart_pill',
            'items=${cart.pillItemsLabel}|thumbs=${thumbs.length}');
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
          // The pill sizes itself to its row; the Center is what keeps it in
          // the middle of whatever width the shell hands it, and the padding
          // is the only thing that stops a very long count from reaching the
          // screen edges on a 320px phone.
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            child: Center(
              // The Row sizes itself to its own content (unbounded, inside the
              // FittedBox), which is what "hugs" means here. The FittedBox is
              // the only concession to a narrow phone: a backend label long
              // enough to reach the screen edges scales the whole pill down in
              // proportion rather than clipping a word or overflowing.
              child: FittedBox(
                key: const Key('c2029_pill'),
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  height: kHeight,
                  // Nothing is printed when the backend says there is no pill.
                  // An empty label is still a Text, and a hidden pill must
                  // leave no widget on the page it floats over — the product
                  // page proves it (`find.text('')` there is an assertion that
                  // the page prints no blank captions of its own).
                  child: show ? _pill(cart, thumbs) : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(CartModel cart, List<Map<String, dynamic>> thumbs) {
    final radius = BorderRadius.circular(kHeight / 2);
    return Material(
      color: Ds.c.brand,
      borderRadius: radius,
      elevation: kShadowElevation,
      shadowColor: Colors.black.withValues(alpha: kShadowAlpha),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: kPadLeft, right: kPadRight),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ThumbStack(thumbs: thumbs),
              SizedBox(width: Ds.space.x12),
              // Backend copy, both of them, on ONE line.
              _line(
                cart.pillItemsLabel,
                Ds.t.body.copyWith(
                  color: Colors.white,
                  fontSize: kItemsSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(width: Ds.space.x12),
              _divider(),
              SizedBox(width: Ds.space.x12),
              _line(cart.pillCta, Ds.t.body.copyWith(color: Colors.white)),
              SizedBox(width: Ds.space.x4),
              const Icon(Icons.chevron_right,
                  color: Colors.white, size: kChevron),
            ],
          ),
        ),
      ),
    );
  }

  /// Backend copy, rendered verbatim on one line. It is never wrapped and
  /// never ellipsised: the pill is as wide as its words, and the FittedBox
  /// above is what keeps that promise on a 320px phone.
  Widget _line(String text, TextStyle style) =>
      Text(text, maxLines: 1, softWrap: false, style: style);

  /// The hairline between the count and the CTA. Two facts on one line need
  /// something between them, and a rule is quieter than a gap wide enough to
  /// read as one.
  Widget _divider() => SizedBox(
        width: kDividerWidth,
        height: kDividerHeight,
        child: ColoredBox(
          color: Colors.white.withValues(alpha: kDividerAlpha),
        ),
      );
}

/// The one or two overlapping thumbnails. One item draws one circle; the
/// backend decides how many there are and in which order they stack.
class _ThumbStack extends StatelessWidget {
  final List<Map<String, dynamic>> thumbs;
  const _ThumbStack({required this.thumbs});

  @override
  Widget build(BuildContext context) {
    if (thumbs.isEmpty) {
      return const SizedBox(width: CartPill.kThumb, height: CartPill.kThumb);
    }
    final steps = thumbs.length - 1;
    return SizedBox(
      width: CartPill.kThumb + CartPill.kThumbOverlap * steps,
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
