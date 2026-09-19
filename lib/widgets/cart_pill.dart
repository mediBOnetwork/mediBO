import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/cart_model.dart';
import '../design_tokens.dart';
import '../utils/render_log.dart';
import 'product_image.dart';

/// CMD #2089 — the floating "View cart" pill: compact, brand green, no bubble.
///
/// One solid full-radius pill in the mediBO brand green — the SAME token the
/// Place-order and every other primary button uses — about [kWidthFactor] of
/// the screen wide and [kHeight] tall, centred over the bottom stack. Left:
/// up to two overlapping ringed thumbnails. Middle: TWO STACKED LINES. Right:
/// one chevron inside a subtle circle.
///
/// WHAT #2089 CHANGED, AND WHY
///  * The "+N" bubble is gone. The second line already says "N items", so the
///    circle beside the thumbnails was the same number twice — and it was the
///    widest thing in a pill this change makes narrower. The backend stopped
///    emitting it (`has_more` false, `more_label` empty) and this widget no
///    longer knows how to draw one.
///  * 48 px tall and 55% of the screen, down from #2081's 64 / 60%. The
///    thumbnails, the chevron circle and both paddings scale with it.
///  * `Ds.c.brand`, not `Ds.c.brandDark`. The pill names a design TOKEN, never
///    a hex, so `ui_design_set` still recolours it with the rest of the app.
///
/// EVERYTHING IT SAYS — AND NOW EVERYTHING IT IS — COMES FROM THE PAYLOAD.
/// `cart_render().render.pill` decides whether to appear (`show`), the two
/// stacked lines (`lines`, in draw order — the backend pluralises and words
/// them, never Dart), the thumbnail stack (`thumbs`, [0] behind and the most
/// recently added item on top) and, since #2089, the SHAPE: `ui.color_token`,
/// `ui.height`, `ui.width_factor`, `ui.min_width`, `ui.thumb`,
/// `ui.thumb_overlap`, `ui.chevron_box`, `ui.chevron`, `ui.pad_left`,
/// `ui.pad_right`. Re-proportioning or recolouring the pill is an UPDATE to
/// `storefront_ui_label`, not a deploy.
///
/// The `k*` constants below are NOT a second opinion — they are what is drawn
/// in the one frame before the first payload lands, and they are the same
/// shape the backend ships. A pill that is briefly 48 px is right; a pill that
/// is briefly nothing is not.
///
/// This is the only widget in the storefront chrome that reads the cart, so a
/// cart write repaints the pill and nothing else.
class CartPill extends StatelessWidget {
  final VoidCallback onTap;
  const CartPill({super.key, required this.onTap});

  /// The SLOT's height, and the pill's own default. The bottom stack reserves
  /// exactly this much room for the pill ([BottomStackMetrics.pill]) and that
  /// reservation is a compile-time constant on purpose (#2066): it is what
  /// stops every list on screen re-padding when a payload arrives. So
  /// `ui.height` may make the pill SHORTER than its slot — which moves
  /// nothing, because the pill is centred in the room it was given — and is
  /// clamped at this value, which is also the height the backend ships.
  static const double kHeight = 48;
  static const double kThumb = 30;
  static const double kThumbRing = 2;

  /// How far each further circle is pushed right of the one before it, so
  /// overlapping tiles still read as separate tiles.
  static const double kThumbOverlap = 11;
  static const double kPadLeft = 8;
  static const double kPadRight = 10;

  /// The pill is a proportion of the screen, not of its content: a bar that
  /// changed width every time an item was added would be the thing the eye
  /// follows instead of the basket.
  static const double kWidthFactor = 0.55;

  /// …with a floor, because 55% of a 320 px phone is less than two thumbnails,
  /// two lines and a chevron need. Below ~345 px the floor wins and the pill
  /// simply reads a little wider. It is still clamped to the room it was
  /// handed, so it can never reach the screen edges.
  static const double kMinWidth = 190;

  /// The chevron's circle, and the glyph inside it.
  static const double kChevronBox = 26;
  static const double kChevron = 18;
  static const double kChevronAlpha = 0.18;

  /// The second line is the quieter of the two.
  static const double kSubAlpha = 0.85;
  static const double kShadowElevation = 6;
  static const double kShadowAlpha = 0.24;

  /// The gap between the pill and the bottom bar above which it floats, and
  /// the inset a scrolling storefront surface reserves at its end so the last
  /// card is never left underneath the pill. One number, read by the shell
  /// (which positions the pill) and by the lists (which get out of its way),
  /// so the two can never disagree about how much room the pill takes.
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
    final ui = PillUi.from(cart.pillUi);
    if (show) {
      try {
        RenderLog.write('c2029_cart_pill',
            'items=${cart.pillItemsLabel}|thumbs=${thumbs.length}');
        RenderLog.write('c2081_cart_pill',
            'lines=${cart.pillLines.length}|thumbs=${thumbs.length}|more=');
        // CMD #2089 — the SHAPE that actually painted, so "the pill got
        // smaller and greener" is something the render log can answer.
        RenderLog.write(
            'c2089_cart_pill',
            'h=${ui.height.round()}|wf=${ui.widthFactor}'
            '|token=${ui.colorToken}|thumbs=${thumbs.length}|bubble=0');
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
          // edges on a 320 px phone.
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            child: LayoutBuilder(
              builder: (context, box) {
                // The backend's share of the SCREEN (the padding above is
                // added back), floored so the content always fits and capped
                // at the room available: 320 / 360 / 412 / 480 all land inside
                // their own screen with nothing wrapped and nothing clipped.
                final screen = box.maxWidth + Ds.space.x16 * 2;
                final floor =
                    ui.minWidth > box.maxWidth ? box.maxWidth : ui.minWidth;
                final width =
                    (screen * ui.widthFactor).clamp(floor, box.maxWidth);
                return Center(
                  child: SizedBox(
                    key: const Key('c2029_pill'),
                    width: width,
                    // Never taller than the slot the stack reserved — see
                    // [kHeight]. Shorter is free; the pill is centred in it.
                    height: ui.height > kHeight ? kHeight : ui.height,
                    // Nothing is printed when the backend says there is no
                    // pill. An empty label is still a Text, and a hidden pill
                    // must leave no widget on the page it floats over — the
                    // product page proves it (`find.text('')` there is an
                    // assertion that the page prints no blank captions).
                    child: show
                        ? _pill(cart, thumbs, ui)
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
      CartModel cart, List<Map<String, dynamic>> thumbs, PillUi ui) {
    final h = ui.height > kHeight ? kHeight : ui.height;
    final radius = BorderRadius.circular(h / 2);
    return Material(
      color: ui.color,
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
            padding:
                EdgeInsets.only(left: ui.padLeft, right: ui.padRight),
            child: Row(
              children: [
                _ThumbStack(thumbs: thumbs, ui: ui),
                SizedBox(width: Ds.space.x8),
                // The two stacked lines, both backend copy.
                Expanded(child: _Lines(lines: cart.pillLines)),
                SizedBox(width: Ds.space.x8),
                _Chevron(ui: ui),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// CMD #2089 — the pill's shape, as the backend sent it.
///
/// Every field falls back to the matching `CartPill.k*` constant, which is the
/// value the backend ships: the fallback exists for the frame before the first
/// payload, not as a second opinion about how big the pill should be.
///
/// [colorToken] names a key of `design.colors` — `brand` is the primary green
/// the Place-order button uses. Resolving it here is what keeps a hex out of
/// this file: the pill asks for a TOKEN and the token layer answers, so
/// `ui_design_set` recolours the pill along with everything else.
class PillUi {
  final String colorToken;
  final double height, widthFactor, minWidth;
  final double thumb, thumbOverlap, chevronBox, chevron, padLeft, padRight;

  const PillUi({
    required this.colorToken,
    required this.height,
    required this.widthFactor,
    required this.minWidth,
    required this.thumb,
    required this.thumbOverlap,
    required this.chevronBox,
    required this.chevron,
    required this.padLeft,
    required this.padRight,
  });

  static double _d(Object? v, double fallback) {
    if (v is num) {
      final d = v.toDouble();
      return d > 0 ? d : fallback;
    }
    if (v is String) {
      final d = double.tryParse(v.trim());
      if (d != null && d > 0) return d;
    }
    return fallback;
  }

  factory PillUi.from(Map<String, dynamic> m) => PillUi(
        colorToken: ((m['color_token'] ?? '').toString().trim().isEmpty)
            ? 'brand'
            : m['color_token'].toString().trim(),
        height: _d(m['height'], CartPill.kHeight),
        widthFactor: _d(m['width_factor'], CartPill.kWidthFactor),
        minWidth: _d(m['min_width'], CartPill.kMinWidth),
        thumb: _d(m['thumb'], CartPill.kThumb),
        thumbOverlap: _d(m['thumb_overlap'], CartPill.kThumbOverlap),
        chevronBox: _d(m['chevron_box'], CartPill.kChevronBox),
        chevron: _d(m['chevron'], CartPill.kChevron),
        padLeft: _d(m['pad_left'], CartPill.kPadLeft),
        padRight: _d(m['pad_right'], CartPill.kPadRight),
      );

  /// The token, resolved. An unknown name falls back to the brand green rather
  /// than to a colour this file invented.
  Color get color {
    switch (colorToken) {
      case 'brandDark':
        return Ds.c.brandDark;
      case 'success':
        return Ds.c.success;
      case 'info':
        return Ds.c.info;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      case 'text':
        return Ds.c.text;
      case 'brand':
      default:
        return Ds.c.brand;
    }
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
            ? Ds.t.caption.copyWith(
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

/// One chevron inside a subtle circle, sized by the payload.
class _Chevron extends StatelessWidget {
  const _Chevron({required this.ui});
  final PillUi ui;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: ui.chevronBox,
      height: ui.chevronBox,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: CartPill.kChevronAlpha),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.chevron_right,
          color: Colors.white, size: ui.chevron),
    );
  }
}

/// The overlapping thumbnails — and, since #2089, NOTHING ELSE.
///
/// The backend decides how many circles there are (`ui.max_thumbs`, two) and
/// in which order they stack. The "+N" bubble that used to sit at the end of
/// this strip is gone: the pill's own second line already says "N items", so
/// the circle repeated a number the shopper was already reading, in the part
/// of a narrower pill that could least afford the width.
class _ThumbStack extends StatelessWidget {
  final List<Map<String, dynamic>> thumbs;
  final PillUi ui;
  const _ThumbStack({required this.thumbs, required this.ui});

  @override
  Widget build(BuildContext context) {
    if (thumbs.isEmpty) {
      return SizedBox(width: ui.thumb, height: ui.thumb);
    }
    return SizedBox(
      width: ui.thumb + ui.thumbOverlap * (thumbs.length - 1),
      height: ui.thumb,
      child: Stack(
        children: [
          for (var i = 0; i < thumbs.length; i++)
            Positioned(
              key: Key('c2029_pill_thumb_$i'),
              left: ui.thumbOverlap * i,
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
    final inner = ui.thumb - CartPill.kThumbRing * 2;
    return Container(
      width: ui.thumb,
      height: ui.thumb,
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
