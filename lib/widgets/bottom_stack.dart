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
// CMD #2091 — A SLOT IS AS TALL AS WHAT IS IN IT, AND 0 WHEN IT IS EMPTY.
//
// #2066 reserved both slots unconditionally so nothing above them could move.
// The cost landed on every staff page: admin, super admin and partner float no
// pill and see an update bar perhaps once a month, so the reserved room was a
// permanent blank white strip sitting above the bottom nav on every one of
// their screens — the empty box was more visible, more often, than the thing
// it was holding room for.
//
// So the geometry is no longer a compile-time constant; it is a pure function
// of TWO BOOLEANS, and nothing else:
//
//     bar showing   = this Scaffold has a bottom nav AND an update is pending
//     pill showing  = this surface floats the pill AND the cart payload says
//                     `show`
//
// Neither is measured, neither is published by a child, and neither can be
// changed by a line-wrap, a longer sentence or a wider phone — which is what
// #2051 got wrong and #2066 was right to remove. What #2091 adds is that an
// EMPTY slot is 0 tall instead of 56, and that every box which holds room for
// the chrome ([BottomStackSpacer], [BottomStackClearance]) reads the very same
// function, so the room and the chrome can never disagree.
//
// Both sides animate on ONE token — `Ds.motion.sheet` / `Ds.motion.curve`. A
// dismissed bar therefore does not leave a gap behind it: the bar collapsing
// and the page host giving the pixels back are the same curve started on the
// same frame.
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

import '../app_state.dart';
import '../design_tokens.dart';
import '../models/cart_model.dart';
import '../utils/render_log.dart';
import 'cart_pill.dart';
import 'update_bar.dart';

/// The two reserved boxes, by name, so the protected suite can measure the
/// SLOTS rather than whatever the pill inside one happens to have scaled to.
const Key kPillSlotKey = Key('bottom_stack_pill_slot');
const Key kBarSlotKey = Key('bottom_stack_bar_slot');

/// The pill's air, as its own box — it closes with the pill (#2091), so the
/// suite can measure that it went with it rather than inferring it.
const Key kPillGapKey = Key('bottom_stack_pill_gap');

/// The bottom stack's geometry, in one place, as tokens.
///
/// These are the heights of the boxes when they are FULL. Nothing here is
/// measured and nothing here is published by a child — a slot is either the
/// size named below or it is 0 ([BottomStackLiveMetrics]), which is the whole
/// of #2091.
class BottomStackMetrics {
  const BottomStackMetrics._();

  /// The update-bar slot, when an update is pending.
  static double get slot => Ds.touch.listRowMinHeight;

  /// The air the pill floats on: between it and whatever is below it, which is
  /// the bar slot when there is an update and the bottom nav when there is not.
  static double get gap => Ds.space.x12;

  /// The pill slot, when the cart payload says there is a pill.
  static double get pill => CartPill.kHeight;

  /// Pill + gap + slot: the MOST of the bottom the chrome can ever cover,
  /// measured up from the top of the bottom nav.
  static double get height => pill + gap + slot;
}

/// The most of the bottom of the screen the whole stack can cover, in logical
/// pixels, measured from the top of the bottom nav upwards.
///
/// The CEILING, not the current height (#2091) — what is on screen right now
/// is [BottomStackLiveMetrics.height], and only a widget with a `BuildContext`
/// can answer that, because the answer depends on the shell it is standing in.
double get bottomStackHeight => BottomStackMetrics.height;

/// What the bottom stack is showing RIGHT NOW, and therefore how much room it
/// is taking (#2091).
///
/// Two booleans and no arithmetic anyone else has to repeat. An empty stack is
/// `height == 0`: the page above it runs all the way down to the bottom nav,
/// which is what a staff screen with no update pending should always have
/// looked like.
class BottomStackLiveMetrics {
  const BottomStackLiveMetrics({required this.pill, required this.bar});

  /// The cart pill is on screen: this surface floats one AND the cart payload
  /// says there is something to show.
  final bool pill;

  /// The update bar is on screen: this Scaffold has a bottom nav for it to sit
  /// on AND an update is pending.
  final bool bar;

  double get pillBox => pill ? BottomStackMetrics.pill : 0;

  /// The pill's air. It belongs to the PILL, not to the bar: a pill with no
  /// bar under it still must not touch the nav, and a bar with no pill over it
  /// is flush on the nav by design (#2051).
  double get gapBox => pill ? BottomStackMetrics.gap : 0;

  double get barBox => bar ? BottomStackMetrics.slot : 0;

  /// How much of the bottom the chrome covers this frame. 0 when the stack is
  /// empty — the blank strip #2091 removes.
  double get height => pillBox + gapBox + barBox;

  /// Nothing is in the stack, so nothing owes it any room.
  bool get isEmpty => !pill && !bar;
}

/// The cart, if this subtree has one — with a real dependency on it, so a cart
/// write rebuilds whoever asked.
///
/// [AppState.of] asserts; the chrome is mounted on surfaces that have no cart
/// at all (the supplier shell) and in tests that mount a spacer on its own, so
/// this asks the same question without the assertion.
CartModel? _cartOrNull(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<AppState>()?.notifier;

/// Reads every input the stack's live height depends on, registering a real
/// dependency on each of them.
///
/// [pill] is whether this SURFACE floats a pill at all — the customer-nav
/// registry's answer on a shell, plainly false on every staff surface. Whether
/// the pill then has anything to say is the cart payload's own answer, read
/// here.
///
/// The MediaQuery read is deliberate and unconditional (#2066 QA round 1):
/// `bottomNavVisible` is `findAncestorStateOfType`, which registers NO
/// dependency, so without this the first answer would be the last one this
/// element ever gave and a shell that drops its nav on a wide viewport would
/// latch. It is also the `viewPadding` every caller needs.
BottomStackLiveMetrics bottomStackLiveOf(
  BuildContext context, {
  required bool pill,
}) {
  final hasNav = bottomNavVisible(context);
  final cart = _cartOrNull(context);
  return BottomStackLiveMetrics(
    pill: pill && cart != null && cart.pillShow,
    bar: hasNav && appUpdateBar.visible,
  );
}

/// Rebuilds [builder] whenever anything that can change the stack's live
/// height changes: the update controller, the cart, the viewport, the nav.
///
/// One place, so the chrome and every box holding room for it are reading the
/// same frame's answer rather than two that drifted apart.
class BottomStackLive extends StatelessWidget {
  const BottomStackLive({
    super.key,
    required this.pill,
    required this.builder,
  });

  /// Does this SURFACE float the cart pill? Staff surfaces do not.
  final bool pill;

  final Widget Function(BuildContext context, BottomStackLiveMetrics live)
      builder;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        // The controller is a ChangeNotifier, so this is the listener that
        // makes "an update arrived" and "the bar was dismissed" arrive here at
        // all. The cart and the viewport come in as dependencies below.
        animation: appUpdateBar,
        builder: (context, _) =>
            builder(context, bottomStackLiveOf(context, pill: pill)),
      );

  /// The one duration and the one curve BOTH sides of #2091 animate on: the
  /// slot closing and the page host taking its pixels back.
  static Duration get motion => Ds.motion.sheet;
  static Curve get motionCurve => Ds.motion.curve;
}

/// A slot that is [height] tall while [show], 0 tall when it is not, and
/// travels between the two on [BottomStackLive.motion].
///
/// The child is laid out at its FULL height throughout and the box is clipped
/// to the animated fraction, so a bar or a pill on its way out slides down
/// behind the nav instead of being squashed into a box too small for it — and
/// nothing ever overflows.
class _Collapsible extends StatefulWidget {
  const _Collapsible({
    super.key,
    required this.show,
    required this.height,
    this.child,
  });

  final bool show;
  final double height;
  final Widget? child;

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  /// What was in the slot when it was last open. Held only while the box is
  /// closing, so the thing being dismissed is still on screen for the travel
  /// instead of vanishing a frame before the room does.
  Widget? _leaving;

  @override
  Widget build(BuildContext context) {
    if (widget.show && widget.child != null) _leaving = widget.child;
    final Widget? content = widget.show ? widget.child : _leaving;
    return TweenAnimationBuilder<double>(
      // No `begin`: the first build lands on the answer rather than animating
      // into it, so a page that opens with a bar already pending is right on
      // its first frame.
      tween: Tween<double>(end: widget.show ? 1.0 : 0.0),
      duration: BottomStackLive.motion,
      curve: BottomStackLive.motionCurve,
      onEnd: () {
        if (widget.show || _leaving == null) return;
        setState(() => _leaving = null);
      },
      builder: (context, t, _) {
        if (t <= 0) return const SizedBox(width: double.infinity, height: 0);
        return ClipRect(
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: t,
            child: SizedBox(
              width: double.infinity,
              height: widget.height,
              child: content,
            ),
          ),
        );
      },
    );
  }
}

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
    final tap = onCartTap;
    // Does this SURFACE draw a pill at all? Whether there is anything in it is
    // the cart's answer, read inside [BottomStackLive].
    final floats = showPill && tap != null;

    return BottomStackLive(
      pill: floats,
      builder: (context, live) {
        // CMD #2066 QA round 1 — read the metrics unconditionally, before the
        // branch that uses them; `bottomStackLiveOf` above does the same, for
        // the same reason (`Scaffold.maybeOf` registers no dependency).
        final viewPaddingBottom = MediaQuery.of(context).viewPadding.bottom;
        final hasNav = bottomNavVisible(context);
        // No nav under us means the system gesture area is ours to clear.
        final safeBottom = hasNav ? 0.0 : viewPaddingBottom;

        return Padding(
          padding: EdgeInsets.only(bottom: safeBottom),
          // A COLUMN, bottom-up: bar slot, gap, pill slot. The ORDER is still
          // the layout, so the bar can never cover the pill. What #2091
          // changed is only the heights: an empty slot is 0, and it travels
          // there on one curve.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Collapsible(
                // The pill slot. Keyed because it — not the pill's own
                // rectangle — is the geometry the suite measures: at 360 px a
                // long backend label makes [CartPill] scale down inside this
                // box, which is the right answer to a narrow phone and is not
                // the chrome moving.
                key: kPillSlotKey,
                show: live.pill,
                height: BottomStackMetrics.pill,
                // The pill stays mounted while the box closes and plays its
                // own slide inside it, so an emptied cart reads as one motion
                // rather than a disappearance followed by a collapse.
                child: floats ? RepaintBoundary(child: CartPill(onTap: tap)) : null,
              ),
              // The pill's own air — see [BottomStackLiveMetrics.gapBox]. It
              // closes with the pill, never with the bar, so a bar on its own
              // is flush on the nav exactly as #2051 drew it.
              _Collapsible(
                key: kPillGapKey,
                show: live.pill,
                height: BottomStackMetrics.gap,
              ),
              _BarSlot(key: kBarSlotKey, show: live.bar),
            ],
          ),
        );
      },
    );
  }
}

/// The update-bar slot: [BottomStackMetrics.slot] tall while an update is
/// pending on a shell with a bottom nav, and 0 tall the rest of the time.
///
/// #2066 kept this box at full height either way so the pill above it could
/// not move. #2091 closes it, because on a staff shell — which floats no pill
/// for it to hold still — the permanently reserved box WAS the bug: a blank
/// white strip above the nav on every admin screen, months at a time, holding
/// room for a bar that was not there.
class _BarSlot extends StatelessWidget {
  const _BarSlot({super.key, required this.show});

  /// Has this shell a nav for the bar to sit on, and is an update pending?
  /// Both are decided in [bottomStackLiveOf]; this widget only draws.
  final bool show;

  @override
  Widget build(BuildContext context) => _Collapsible(
        show: show,
        height: BottomStackMetrics.slot,
        child: show
            ? UpdateBar(
                title: appUpdateBar.label,
                actionLabel: appUpdateBar.actionLabel,
                updatingLabel: appUpdateBar.updatingLabel,
                downloadedLabel: appUpdateBar.downloadedLabel,
                updating: appUpdateBar.updating,
                downloaded: appUpdateBar.downloaded,
                // CMD #2065 — Later, when the backend sent one. Both null on a
                // forced update, which is how "non-dismissable" is rendered:
                // not a disabled button, no control at all.
                dismissLabel: appUpdateBar.dismissLabel,
                onDismiss: appUpdateBar.onDismiss,
                // FLUSH, and exactly one slot tall: the bar fills the box it
                // was given instead of publishing a height of its own.
                fixedHeight: BottomStackMetrics.slot,
                onUpdate: appUpdateBar.onUpdate ?? _noop,
              )
            : null,
      );

  static void _noop() {}
}

/// The end-of-list box: exactly as tall as the chrome IS.
///
/// CMD #2091 — it was [bottomStackHeight], the ceiling, whether or not
/// anything was in the stack, so a list whose cart was empty and whose app was
/// up to date ended 116 px short of the nav for no reason anyone could see. It
/// now reads [bottomStackLiveOf] and travels on the same curve the slots do,
/// so the last card clears the chrome when there is chrome and reaches the nav
/// when there is not.
class BottomStackSpacer extends StatelessWidget {
  const BottomStackSpacer({super.key, this.extra = 0, this.pill = true});

  /// Air the page wants BELOW its own last item regardless of the chrome.
  final double extra;

  /// Does the surface this box is the end of float the cart pill? The customer
  /// surfaces do; a staff list passes false and clears the bar alone.
  final bool pill;

  @override
  Widget build(BuildContext context) => BottomStackLive(
        pill: pill,
        builder: (context, live) {
          // The same unconditional read the stack itself makes, for the same
          // reason (see [bottomStackLiveOf]).
          final viewPaddingBottom = MediaQuery.of(context).viewPadding.bottom;
          final hasNav = bottomNavVisible(context);
          return AnimatedContainer(
            duration: BottomStackLive.motion,
            curve: BottomStackLive.motionCurve,
            height:
                live.height + extra + (hasNav ? 0.0 : viewPaddingBottom),
          );
        },
      );
}

/// How much bottom chrome a surface that floats NO cart pill can cover.
///
/// The staff shells (admin, supplier, partner) mount the stack with
/// `showPill: false`: the pill slot above the bar is then an empty
/// transparent box that paints nothing and swallows no taps, so the only box
/// that can ever put ink over a staff page is the bar slot. Reserving the
/// pill's 56 as well would hand every admin phone a permanently dead band
/// twice the height of the thing it is clearing.
///
/// The CEILING for a pill-less surface (#2091): what it clears while an update
/// is pending, and 0 the rest of the time.
double get bottomBarOnlyHeight => BottomStackMetrics.slot;

/// Reserves the chrome's height under a WHOLE PAGE HOST, once, in the shell.
///
/// CMD #2070 — [BottomStackSpacer] is an end-of-list box each scrolling page
/// has to remember to add, and only the customer surfaces ever did. The staff
/// shells host dozens of pages built by dozens of commands, so "every page
/// remembers" was never going to hold: the shell reserves the room instead,
/// which is one place, cannot be forgotten by a page written next month, and
/// needs no page to know the chrome exists at all.
///
/// Wraps the shell's page host, so every page inside it — list, form, board,
/// empty state — ends above the bar instead of under it.
///
/// CMD #2091 — and ONLY while the bar is there. This is the widget the blank
/// strip came out of: it padded every admin, super-admin and partner page by a
/// whole bar slot on the months-long stretches when no update was pending, so
/// a staff phone showed a dead white band above its bottom nav on every
/// screen. The room is now the live height, and it is given back on the same
/// curve the bar leaves on — which is what "no leftover gap after dismiss"
/// means in layout terms.
class BottomStackClearance extends StatelessWidget {
  const BottomStackClearance({
    super.key,
    required this.child,
    this.pill = false,
  });

  /// The shell's page host.
  final Widget child;

  /// Does this surface float the cart pill? Staff surfaces do not, so they
  /// clear the bar alone.
  final bool pill;

  @override
  Widget build(BuildContext context) => BottomStackLive(
        pill: pill,
        builder: (context, live) {
          // Unconditional, before the branch that uses it — see
          // [bottomStackLiveOf].
          final viewPaddingBottom = MediaQuery.of(context).viewPadding.bottom;
          final hasNav = bottomNavVisible(context);
          // CMD #2091 — the number the bug was: how many pixels this page host
          // is holding back right now. 0 on the ordinary day is the proof the
          // blank strip is gone, and it is a fact a browser journey can read
          // out of the render log rather than a screenshot someone has to
          // squint at.
          try {
            RenderLog.write('c2091_bottom_clear', live.height.round());
          } catch (_) {}
          // No nav means no bar (see [_BarSlot]) — on that layout the only
          // thing below the page is the system gesture area, and the stack
          // clears it itself, so the host owes the chrome nothing.
          final safeBottom = hasNav ? 0.0 : viewPaddingBottom;
          return AnimatedPadding(
            duration: BottomStackLive.motion,
            curve: BottomStackLive.motionCurve,
            padding: EdgeInsets.only(bottom: live.height + safeBottom),
            child: child,
          );
        },
      );
}

/// A shell's page host, with the bottom chrome cleared when that shell is a
/// STAFF shell.
///
/// CMD #2070 — the customer surfaces pad their own lists
/// ([BottomStackSpacer]) so a storefront list scrolls UNDER the floating pill,
/// which is the behaviour a shopper expects. The staff shells float no pill
/// and their pages carry no spacer, so the shell reserves the bar's room for
/// all of them at once. One call per shell, and a staff page added tomorrow
/// inherits it without knowing the chrome exists.
///
/// CMD #2091 — "the bar's room" is now the room the bar is ACTUALLY taking, so
/// on the ordinary day when no update is pending a staff page runs all the way
/// down to its bottom nav.
Widget staffPageHost(Widget child, {required bool staff}) =>
    staff ? BottomStackClearance(child: child) : child;

/// The same box for a `CustomScrollView`.
class BottomStackSliverSpacer extends StatelessWidget {
  const BottomStackSliverSpacer({super.key, this.pill = true});

  /// See [BottomStackSpacer.pill].
  final bool pill;

  @override
  Widget build(BuildContext context) =>
      SliverToBoxAdapter(child: BottomStackSpacer(pill: pill));
}
