// CMD #2066 — ONE bottom stack, and every position in it is STATIC.
//
// WHAT CHANGED, AND WHY
// CMD #2051 put the update bar and the floating cart pill into one column so
// they could not cover each other. That fixed the overlap and left a second
// bug in place: the column MEASURED itself and published its height, so every
// list on screen re-padded whenever the bar arrived, whenever a cart emptied,
// and whenever the update sentence took a second line at 360 px. The chrome
// was one anchor but it still breathed, and the content above it jumped each
// time it did.
//
// Nothing here is measured any more. The stack is three fixed boxes:
//
//   ┌───────────────────────────────────────────────┐
//   │            ( ●● ) 3 items │ View cart  ›       │  ← pill slot   56
//   │                                               │  ← gap         16
//   │  (⚙)  App update available     [ Update Now ] │  ← bar slot    56
//   ╞═══════════════════════════════════════════════╡
//   │   Home      Orders      Bulk      Cart        │  ← the bottom nav
//   └───────────────────────────────────────────────┘
//
// The bar slot is ALWAYS reserved. No update pending means an empty
// transparent box of exactly the same height — so the pill above it sits at
// one height for the life of the app and never moves, and the padding every
// scrolling page reserves ([bottomStackHeight]) is a CONSTANT that no payload,
// no cart write and no line-wrap can change.
//
// WHERE THE BAR RENDERS — THE SHELL ANSWERS, NOT A LIST OF SCREEN NAMES
// The bar belongs on top of a bottom navigation bar, which is the only place
// it has an edge to sit on. So the stack asks the Scaffold it is mounted in
// whether that Scaffold shows one ([bottomNavVisible]): a shell with tabs —
// whichever tabs that user type has — renders the bar, and a route pushed over
// it (product page, cart, checkout, login) does not. The pill is not subject
// to that question: it still floats on a pushed route, at the same height,
// because its slot is above a bar slot that is reserved either way.
//
// ZERO STYLE LITERALS, ZERO DART COPY. The geometry is the `Ds` token layer
// (`listRowMinHeight` is the 56 both rows are tall, `space.x16` is the air
// between them) and every word printed inside it arrives in the payloads the
// two children already read — `app_update_bar()` and `cart_render()`.

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'cart_pill.dart';
import 'update_bar.dart';

/// The two reserved boxes, by name, so the protected suite can measure the
/// SLOTS rather than whatever the pill inside one happens to have scaled to.
const Key kPillSlotKey = Key('bottom_stack_pill_slot');
const Key kBarSlotKey = Key('bottom_stack_bar_slot');

/// The bottom stack's geometry, in one place, as tokens.
///
/// Every one of these is a constant for the life of a frame: that is the whole
/// point of #2066. A screen that needs to know how much room the chrome takes
/// reads [height] — it is never told a number twice and never has to listen
/// for one to change.
class BottomStackMetrics {
  const BottomStackMetrics._();

  /// The update-bar slot. Always reserved, whether or not an update is
  /// pending, so the pill above it cannot move when one arrives.
  static double get slot => Ds.touch.listRowMinHeight;

  /// The air between the pill and the bar slot.
  static double get gap => Ds.space.x16;

  /// The pill slot. The pill itself is one data row tall and animates in and
  /// out INSIDE this box, so an empty cart leaves the box exactly as tall.
  static double get pill => CartPill.kHeight;

  /// Pill + gap + slot: how much of the bottom the chrome covers, measured up
  /// from the top of the bottom nav.
  static double get height => pill + gap + slot;
}

/// How much of the bottom of the screen the whole stack covers, in logical
/// pixels, measured from the top of the bottom nav upwards.
///
/// A CONSTANT (#2066). It was a measured `ValueNotifier` in #2051, which is
/// what made the content above it jump every time the chrome changed shape.
double get bottomStackHeight => BottomStackMetrics.height;

/// Does the Scaffold this widget is mounted in show a bottom navigation bar?
///
/// This is the shell answering for itself. A shell with tabs — customer,
/// supplier, partner, admin, delivery, whichever ones that user type has —
/// has a `bottomNavigationBar` and its body therefore ends at the top of it.
/// A route pushed over the shell, a full-screen panel, a desktop layout: no
/// nav, and the body runs to the bottom of the screen.
///
/// Deliberately NOT a list of screen names, and deliberately not a flag each
/// call site passes in: the two ways the old code got this wrong were a screen
/// index written in Dart and an offset two widgets had to keep equal.
bool bottomNavVisible(BuildContext context) =>
    Scaffold.maybeOf(context)?.widget.bottomNavigationBar != null;

/// The one bottom stack: nav (already there), then the update-bar slot, then
/// the cart-pill slot.
///
/// Mounted at `bottom: 0` of a surface's own Stack. Inside a shell that point
/// is the TOP OF THE BOTTOM NAV (a Scaffold body ends where its
/// `bottomNavigationBar` begins), which is what makes "flush on the nav" a
/// fact of the layout rather than a number kept equal to the nav's height. On
/// a route pushed over the shell there is no nav and the stack clears the
/// system gesture area itself.
class StorefrontBottomStack extends StatelessWidget {
  const StorefrontBottomStack({
    super.key,
    this.onCartTap,
    this.showPill = true,
  });

  /// Opening the cart. The shell opens its own panel; a pushed route asks the
  /// shell for it ([requestOpenCart]). Null on a surface that has no cart at
  /// all (the supplier shell), which is also a surface that floats no pill.
  final VoidCallback? onCartTap;

  /// Does THIS surface DRAW the pill? The answer is the customer-nav
  /// registry's ([CartPill.floatsOnPage]) on the shell, and plainly true on a
  /// product page. Whether the pill then has anything to say is still the cart
  /// payload's own answer.
  ///
  /// It does NOT change the geometry: the slot is reserved either way, because
  /// "content never jumps" has to be true of a page that never floats a pill
  /// as well as of one that does.
  final bool showPill;

  @override
  Widget build(BuildContext context) {
    // CMD #2066 QA round 1 — READ THE METRICS UNCONDITIONALLY, BEFORE THE
    // BRANCH THAT USES THEM. `bottomNavVisible` asks the Scaffold, and
    // `Scaffold.maybeOf` is `findAncestorStateOfType`, which registers NO
    // dependency: on its own it gives a fresh answer only on a build that
    // happens for some other reason. The MediaQuery read used to sit inside
    // the `hasNav ? ... : ...` below, so a first build that FOUND a nav took
    // the constant branch, never touched MediaQuery, and registered no
    // dependency at all — after which nothing could make this element rebuild
    // and BOTH `hasNav` and `safeBottom` latched at their first value for its
    // whole life. A shell that drops its nav on a wide viewport (the supplier
    // shell does, at 900 px) then kept painting a bar with no nav under it.
    // Reading it up front is the dependency: a metrics change is exactly what
    // flips those shells between layouts, so the stack rebuilds and re-asks.
    final viewPaddingBottom = MediaQuery.of(context).viewPadding.bottom;
    final hasNav = bottomNavVisible(context);
    // No nav under us means the system gesture area is ours to clear.
    final safeBottom = hasNav ? 0.0 : viewPaddingBottom;
    final tap = onCartTap;

    return Padding(
      padding: EdgeInsets.only(bottom: safeBottom),
      // A COLUMN of fixed boxes, bottom-up: bar slot, gap, pill slot. The
      // order is the layout, so the bar cannot cover the pill; the heights are
      // constants, so nothing appearing or disappearing moves anything.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            // The RESERVED pill slot. Keyed because it — not the pill's own
            // rectangle — is the static geometry this change is about: at 360
            // px a long backend label makes [CartPill]'s `FittedBox` scale the
            // pill down inside this box, which is the right answer to a narrow
            // phone and must not be mistaken for the chrome moving.
            key: kPillSlotKey,
            height: BottomStackMetrics.pill,
            // An empty box paints nothing and swallows no taps, so a page
            // that floats no pill is not covered by the space it reserves.
            child: showPill && tap != null
                ? RepaintBoundary(child: CartPill(onTap: tap))
                : null,
          ),
          SizedBox(height: BottomStackMetrics.gap),
          _BarSlot(key: kBarSlotKey, hasNav: hasNav),
        ],
      ),
    );
  }
}

/// The update-bar slot: exactly [BottomStackMetrics.slot] tall, always.
///
/// Holds the bar where a bottom nav exists and an update is pending, and an
/// empty transparent box everywhere else. Both are the same height, which is
/// the whole of #2066 in one widget.
class _BarSlot extends StatelessWidget {
  const _BarSlot({super.key, required this.hasNav});

  /// Whether the enclosing shell shows a bottom navigation bar.
  final bool hasNav;

  @override
  Widget build(BuildContext context) {
    final h = BottomStackMetrics.slot;
    // No nav, no bar — the slot is still here so the pill does not move.
    if (!hasNav) return SizedBox(height: h);
    return SizedBox(
      height: h,
      child: AnimatedBuilder(
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
            // FLUSH, and exactly one slot tall: the bar fills the box it was
            // given instead of publishing a height of its own.
            fixedHeight: h,
            onUpdate: appUpdateBar.onUpdate ?? _noop,
          );
        },
      ),
    );
  }

  static void _noop() {}
}

/// The end-of-list box: exactly as tall as the chrome, which is a constant.
///
/// So "the last card is never under the chrome" is one number in one place,
/// true on the first frame, and it never changes — no listener, no rebuild,
/// no jump.
class BottomStackSpacer extends StatelessWidget {
  const BottomStackSpacer({super.key, this.extra = 0});

  /// Air the page wants BELOW its own last item regardless of the chrome.
  final double extra;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: bottomStackHeight +
            extra +
            (bottomNavVisible(context)
                ? 0.0
                : MediaQuery.of(context).viewPadding.bottom),
      );
}

/// The same box for a `CustomScrollView`.
class BottomStackSliverSpacer extends StatelessWidget {
  const BottomStackSliverSpacer({super.key});

  @override
  Widget build(BuildContext context) =>
      const SliverToBoxAdapter(child: BottomStackSpacer());
}
