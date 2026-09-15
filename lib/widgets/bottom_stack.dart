// CMD #2051 — ONE bottom stack.
//
// WHAT THIS IS
// Before this file the update card and the floating cart pill were two
// independent overlays that both anchored themselves to the bottom of the
// screen and neither of which could see the other:
//
//   • the card was installed from `MaterialApp.builder`, so it painted OVER
//     everything the shell drew — including the pill, on Home and on the
//     Catalogue;
//   • the pill was `Positioned` inside each screen's own Stack, lifted by the
//     card's published height on the shell and NOT lifted at all on the
//     product page, where the two therefore overlapped and the pill's edges
//     were clipped by the page's own Stack.
//
// Two anchors for one strip of chrome is the bug. This is the one anchor:
//
//   ┌───────────────────────────────────────────────┐
//   │            ( ●● ) 3 items │ View cart  ›       │   ← the pill, floating
//   ├───────────────────────────────────────────────┤     one step of air above
//   │  (⚙)  App update available     [ Update Now ] │   ← the bar, FLUSH on the
//   ╞═══════════════════════════════════════════════╡     nav, full width
//   │   Home      Orders      Bulk      Cart        │   ← the bottom nav
//   └───────────────────────────────────────────────┘
//
// Bottom-up: nav, bar, pill. It is a COLUMN, so the order is the layout — the
// bar cannot cover the pill because the pill is not behind it, and either one
// disappearing closes its own gap without anybody recomputing an offset.
//
// It is mounted at `bottom: 0` of each storefront surface's own Stack. Inside
// the shell that point is the TOP OF THE BOTTOM NAV (a Scaffold body ends
// where its `bottomNavigationBar` begins), which is what makes "flush on the
// nav" a fact of the layout rather than a number that has to be kept equal to
// the nav's height. On a route pushed over the shell (the product page) there
// is no nav and the stack sits on the safe-area inset instead.
//
// HOW EVERY SCROLLING PAGE GETS OUT OF ITS WAY
// The stack MEASURES itself and publishes the total to [bottomStackHeight];
// [BottomStackSpacer] (and its sliver twin) is that number as a box at the end
// of a list. So "the last card is never under the chrome" is one measurement
// read in one place, and it is right again the frame after the bar appears or
// disappears — no screen holds its own copy of how tall the chrome is.
//
// ZERO STYLE LITERALS, ZERO DART COPY. The geometry is the `Ds` token layer
// (`listRowMinHeight` is the 56 both rows are tall, `space.x16` is the air
// between them) and every word printed inside it arrives in the payloads the
// two children already read — `app_update_bar()` and `cart_render()`.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../design_tokens.dart';
import 'cart_pill.dart';
import 'update_bar.dart';

/// How much of the bottom of the screen the whole stack is covering, in
/// logical pixels, measured from the top of the bottom nav upwards.
///
/// MEASURED, never assumed: at 360 px the update sentence is allowed a second
/// line, and whether the pill is there at all is the cart payload's answer, so
/// nothing may compute this from constants. 0 means the chrome is down and a
/// list ends exactly where the page ends.
final ValueNotifier<double> bottomStackHeight = ValueNotifier<double>(0);

/// The one bottom stack: nav (already there), then the update bar, then the
/// cart pill.
class StorefrontBottomStack extends StatefulWidget {
  const StorefrontBottomStack({
    super.key,
    required this.onCartTap,
    this.showPill = true,
    this.overNav = true,
  });

  /// Opening the cart. The shell opens its own panel; a pushed route asks the
  /// shell for it ([requestOpenCart]).
  final VoidCallback onCartTap;

  /// Does THIS surface float the pill? The answer is the customer-nav
  /// registry's ([CartPill.floatsOnPage]) on the shell, and plainly true on a
  /// product page. Whether the pill then has anything to say is still the cart
  /// payload's own answer — this only says the surface allows it.
  final bool showPill;

  /// True when the stack is mounted inside a Scaffold that has a bottom nav:
  /// the body already ends at the top of the nav, so the stack needs no inset
  /// of its own. False on a pushed route, where it clears the system gesture
  /// area itself.
  final bool overNav;

  @override
  State<StorefrontBottomStack> createState() => _StorefrontBottomStackState();
}

class _StorefrontBottomStackState extends State<StorefrontBottomStack> {
  /// The stack's own box, so the number every list pads by is the height this
  /// thing actually has on this phone, with this payload.
  final GlobalKey _boxKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    bottomStackMounted.value = bottomStackMounted.value + 1;
  }

  @override
  void dispose() {
    bottomStackMounted.value = bottomStackMounted.value - 1;
    // The chrome went with the screen: nothing is covered any more, and a list
    // that outlives this stack must not keep padding for it.
    if (bottomStackMounted.value <= 0 && bottomStackHeight.value != 0) {
      bottomStackHeight.value = 0;
    }
    super.dispose();
  }

  void _publishHeight() {
    if (!mounted) return;
    final box = _boxKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final v = box.size.height;
    if ((bottomStackHeight.value - v).abs() > _epsilon) {
      bottomStackHeight.value = v;
    }
  }

  /// Smaller than this and it is rounding, not a change of height.
  static const double _epsilon = 0.5;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _publishHeight());

    // No nav under us means the system gesture area is ours to clear.
    final safeBottom =
        widget.overNav ? 0.0 : MediaQuery.of(context).viewPadding.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: safeBottom),
      child: Column(
        key: _boxKey,
        mainAxisSize: MainAxisSize.min,
        children: [
          // TOP of the column = TOP of the stack = the pill, one step of air
          // above whatever is under it.
          if (widget.showPill) _PillSlot(onTap: widget.onCartTap),
          const _BarSlot(),
        ],
      ),
    );
  }
}

/// The pill, and the step of air under it — together, so an empty cart takes
/// the gap away with the pill instead of leaving a hole above the bar.
///
/// This reads the cart so that a cart write repaints the slot and not the
/// screen around it: the pill was already the only piece of storefront chrome
/// that reads the cart, and it still is.
class _PillSlot extends StatelessWidget {
  const _PillSlot({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    if (!cart.pillShow) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: RepaintBoundary(child: CartPill(onTap: onTap)),
    );
  }
}

/// The update bar, or nothing. It renders the same [UpdateBar] the app-level
/// host renders, from the same controller and the same payload — the only
/// difference is that here it sits FLUSH (`bottomGap` 0), because the thing it
/// would otherwise have had to clear is already below it in the column.
class _BarSlot extends StatelessWidget {
  const _BarSlot();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: appUpdateBar,
        builder: (context, _) {
          if (!appUpdateBar.visible) return const SizedBox.shrink();
          return UpdateBar(
            title: appUpdateBar.label,
            actionLabel: appUpdateBar.actionLabel,
            updatingLabel: appUpdateBar.updatingLabel,
            downloadedLabel: appUpdateBar.downloadedLabel,
            updating: appUpdateBar.updating,
            downloaded: appUpdateBar.downloaded,
            bottomGap: 0,
            onUpdate: appUpdateBar.onUpdate ?? _noop,
          );
        },
      );

  static void _noop() {}
}

/// The end-of-list box: exactly as tall as the chrome currently is, so the
/// last card of any storefront list clears it and no more.
///
/// It listens, so the frame after the update bar arrives (or goes) every list
/// on screen has already made room for it.
class BottomStackSpacer extends StatelessWidget {
  const BottomStackSpacer({super.key, this.extra = 0});

  /// Air the page wants BELOW its own last item regardless of the chrome.
  final double extra;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: bottomStackHeight,
        builder: (_, h, _) => SizedBox(height: h + extra),
      );
}

/// The same box for a `CustomScrollView`.
class BottomStackSliverSpacer extends StatelessWidget {
  const BottomStackSliverSpacer({super.key});

  @override
  Widget build(BuildContext context) =>
      const SliverToBoxAdapter(child: BottomStackSpacer());
}
