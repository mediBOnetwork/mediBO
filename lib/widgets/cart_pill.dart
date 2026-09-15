import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/cart_model.dart';
import '../design_tokens.dart';
import '../utils/render_log.dart';
import 'product_image.dart';

/// CMD #2029 — the floating "View cart" pill.
///
/// Everything it shows comes from `cart_render().render.pill`: whether to
/// appear at all (`show`), the count wording (`items_label` — the backend
/// pluralises, never Dart), the second line (`cta`) and the thumbnail stack
/// (`thumbs`, in DRAW order: [0] behind, [1] the most recently added item on
/// top). The app does not count the cart, does not pick "the first image" and
/// does not decide what an item without a picture looks like — `has_image` is
/// the backend's own answer and the empty url makes [ProductImage] paint the
/// placeholder icon inside the white square.
///
/// This is the only widget in the storefront chrome that reads the cart, so a
/// cart write repaints the pill and nothing else.
class CartPill extends StatelessWidget {
  final VoidCallback onTap;
  const CartPill({super.key, required this.onTap});

  /// Geometry. Named so no bare number is written into a layout call and the
  /// whole shape can be re-proportioned in one place.
  static const double kHeight = 90;
  static const double kWidthFactor = 0.60;

  /// The pill is 60% of the viewport, but never so narrow that the count and
  /// the button collide — at 360px 60% is 216px, which cannot hold both.
  static const double kMinWidth = 248;
  static const double kMaxWidth = 420;
  static const double kThumb = 44;
  static const double kThumbOffset = 14;
  static const double kThumbRadius = 10;
  static const double kThumbRing = 2;
  static const double kThumbInset = 3;
  static const double kButton = 56;
  static const double kChevron = 26;
  static const double kShadowElevation = 10;
  static const double kShadowAlpha = 0.26;

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
          child: LayoutBuilder(
            builder: (context, box) => Center(
              child: SizedBox(
                key: const Key('c2029_pill'),
                width: _width(box.maxWidth),
                height: kHeight,
                child: _pill(cart, thumbs),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 60% of the viewport, clamped so the pill never squeezes its own contents
  /// on a 320px phone and never stretches into a banner on a desktop.
  double _width(double available) {
    final w = available.isFinite && available > 0 ? available : kMinWidth;
    final target = (w * kWidthFactor).clamp(kMinWidth, kMaxWidth).toDouble();
    final room = w - Ds.space.x16 * 2;
    return room > 0 && target > room ? room : target;
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
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
          child: Row(
            children: [
              _ThumbStack(thumbs: thumbs),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // CMD #1896 — an empty backend string renders NOTHING.
                    // The pill is built even while hidden (it slides out
                    // rather than popping), so an unguarded Text leaves empty
                    // text nodes on every page that floats it.
                    if (cart.pillItemsLabel.isNotEmpty)
                      _line(
                          cart.pillItemsLabel,
                          Ds.t.title.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                    if (cart.pillItemsLabel.isNotEmpty &&
                        cart.pillCta.isNotEmpty)
                      SizedBox(height: Ds.space.x4),
                    if (cart.pillCta.isNotEmpty)
                      _line(cart.pillCta,
                          Ds.t.body.copyWith(color: Colors.white)),
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x8),
              _chevron(),
            ],
          ),
        ),
      ),
    );
  }

  /// Backend copy, rendered verbatim — scaled down rather than clipped, so a
  /// long count ("13 items") still fits a 320px phone.
  Widget _line(String text, TextStyle style) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(text, maxLines: 1, softWrap: false, style: style),
      );

  Widget _chevron() => SizedBox(
        width: kButton,
        height: kButton,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Ds.c.brandDark,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.chevron_right,
              color: Colors.white, size: kChevron),
        ),
      );
}

/// The two overlapping thumbnails. One item draws one square; the backend
/// decides how many there are and in which order they stack.
class _ThumbStack extends StatelessWidget {
  final List<Map<String, dynamic>> thumbs;
  const _ThumbStack({required this.thumbs});

  @override
  Widget build(BuildContext context) {
    if (thumbs.isEmpty) {
      return const SizedBox(width: CartPill.kThumb, height: CartPill.kThumb);
    }
    final steps = thumbs.length - 1;
    final span = CartPill.kThumb + CartPill.kThumbOffset * steps;
    return SizedBox(
      width: span,
      height: span,
      child: Stack(
        children: [
          for (var i = 0; i < thumbs.length; i++)
            Positioned(
              key: Key('c2029_pill_thumb_$i'),
              left: CartPill.kThumbOffset * i,
              top: CartPill.kThumbOffset * i,
              child: _tile(thumbs[i]),
            ),
        ],
      ),
    );
  }

  /// A white rounded square inside a ring of the pill's own green, so two
  /// overlapping white squares still read as two.
  Widget _tile(Map<String, dynamic> t) {
    final url = (t['image_url'] ?? '').toString();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Ds.c.brand,
        borderRadius:
            BorderRadius.circular(CartPill.kThumbRadius + CartPill.kThumbRing),
      ),
      child: Padding(
        padding: const EdgeInsets.all(CartPill.kThumbRing),
        child: Container(
          width: CartPill.kThumb,
          height: CartPill.kThumb,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(CartPill.kThumbRadius),
            border: Border.all(color: Colors.white, width: CartPill.kThumbRing),
          ),
          child: Padding(
            padding: const EdgeInsets.all(CartPill.kThumbInset),
            child: ProductImage(
              url: url,
              width: CartPill.kThumb,
              height: CartPill.kThumb,
              radius: BorderRadius.circular(
                  CartPill.kThumbRadius - CartPill.kThumbInset),
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
final ValueNotifier<int> kOpenCartRequest = ValueNotifier<int>(0);

/// Pop back to the shell and ask it for the cart. Safe from any route depth.
void requestOpenCart(BuildContext context) {
  Navigator.of(context).popUntil((r) => r.isFirst);
  kOpenCartRequest.value = kOpenCartRequest.value + 1;
}
