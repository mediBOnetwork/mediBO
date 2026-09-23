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
import '../services/registration_bar.dart';
import '../services/search_chrome_focus.dart';
import 'cart_pill.dart';
import 'update_bar.dart';
// CMD #2147 — the shell's dock draws the update ask in its top row.
export 'update_bar.dart' show appUpdateBar;

/// The two reserved boxes, by name, so the protected suite can measure the
/// SLOTS rather than whatever the pill inside one happens to have scaled to.
const Key kPillSlotKey = Key('bottom_stack_pill_slot');
const Key kBarSlotKey = Key('bottom_stack_bar_slot');

/// The pill's air, as its own box — it closes with the pill (#2091), so the
/// suite can measure that it went with it rather than inferring it.
const Key kPillGapKey = Key('bottom_stack_pill_gap');

/// CMD #2112 — the registration bar, inside the very same slot key. Named so
/// the protected suite can tell WHICH bar the one slot is holding without
/// reading its copy.
const Key kRegistrationBarKey = Key('bottom_stack_registration_bar');

/// CMD #2114 — the login bar, in that same one slot. Same reason as above: the
/// suite asks WHICH bar is up without reading a word of the backend's copy.
const Key kLoginBarKey = Key('bottom_stack_login_bar');

/// The semantics address of the login bar's button, so a browser journey taps
/// the thing this command built rather than a green rectangle.
const String kLoginBarActionId = 'c2114_login_bar_action';

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
  ///
  /// CMD #2172 (Om) — 10, and its own token. The pill is SEPARATE from the
  /// floating card and never hides, so this is the one number that keeps it
  /// clear of whatever the card currently is — both rows at the top of a page,
  /// the banner on its own once the nav row has slid away.
  static double get gap => Ds.touch.cartPillGap;

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
/// What is in the one bar slot. The order of this enum IS the precedence
/// (CMD #2112, CMD #2114): update > login > registration.
///
/// The update outranks both, because a shop that finishes registering on an
/// old build has still not got the new one. The login ask outranks the
/// registration ask trivially — they are the two sides of one question, and
/// only one of them can be true of a given session — but the order is written
/// down rather than left to follow from that, so a future payload that gets
/// both wrong still puts ONE bar on screen instead of two.
enum BottomBarKind { none, registration, login, update }

class BottomStackLiveMetrics {
  const BottomStackLiveMetrics({
    required this.pill,
    required this.bar,
    this.kind = BottomBarKind.none,
  });

  /// The cart pill is on screen: this surface floats one AND the cart payload
  /// says there is something to show.
  final bool pill;

  /// A bar is on screen: this Scaffold has a bottom nav for one to sit on AND
  /// there is something to say — an update is pending, nobody is signed in, or
  /// the shop's registration is owed. CMD #2112/#2114: ONE slot, and the
  /// update always wins, so the other two come up only once the app is on the
  /// new build.
  final bool bar;

  /// Which of the two the slot is holding this frame. `none` when [bar] is
  /// false. The slot draws from this and nothing else.
  final BottomBarKind kind;

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
  // CMD #2117 §3 — the keyboard is up, so the chrome stands down.
  //
  // It is answered HERE, in the one function both the chrome and every box
  // holding room for it read, so the pill and the bar leave AND the pixels
  // they were holding go back to the suggestions in the same frame. A shopper
  // typing on a 360 px phone is not reaching for "View cart" or for a
  // registration ask; they are reading the list the keyboard already halved.
  //
  // WHETHER focus does this is the BACKEND's answer
  // (`search_bar.hide_bottom_chrome_on_focus`); [SearchChromeFocus] only
  // reports what the box observed.
  if (SearchChromeFocus.suppressed.value) {
    return const BottomStackLiveMetrics(pill: false, bar: false);
  }
  // ONE slot, and only one thing in it (CMD #2112/#2114). The precedence is
  // not a preference: an update has to land before anything else the app says
  // is worth acting on, and both asks below it are still there afterwards.
  //
  // WHICH ask it is, is the BACKEND'S word (`kind`), never a guess from the
  // route or from an auth flag read here: one RPC answers signed-out with the
  // login bar and a shop that owes its papers with the registration bar, and
  // this only draws whichever came back.
  // CMD #2147 (Om) — on the customer phone shell the ONE bar (update, else
  // login, else registration) is the TOP ROW of the floating dock card, so
  // the stack draws none of them there: never two bars stacked.
  final kind = !hasNav || bottomBarJoinsDock(context)
      ? BottomBarKind.none
      : appUpdateBar.visible
          ? BottomBarKind.update
          : appRegistrationBar.visible
              ? (appRegistrationBar.kind == 'login'
                  ? BottomBarKind.login
                  : BottomBarKind.registration)
              : BottomBarKind.none;
  return BottomStackLiveMetrics(
    pill: pill && cart != null && cart.pillShow,
    bar: kind != BottomBarKind.none,
    kind: kind,
  );
}

/// Rebuilds [builder] whenever anything that can change the stack's live
/// height changes: the update controller, the cart, the viewport, the nav.
///
/// One place, so the chrome and every box holding room for it are reading the
/// same frame's answer rather than two that drifted apart.
/// CMD #2147 — is the login / registration bar drawn INSIDE the floating
/// dock here? True exactly on the customer phone shell, which is the one
/// Scaffold that floats its dock over the page (`extendBody`).
bool bottomBarJoinsDock(BuildContext context) =>
    Scaffold.maybeOf(context)?.widget.extendBody ?? false;

/// CMD #2147 — the login / registration bar's button, wherever it is drawn:
/// the address and the section are the payload's; no route, no push.
void openRegistrationBar(BuildContext context) {
  final route = appRegistrationBar.route;
  if (route.isEmpty) return;
  final anchor = appRegistrationBar.anchor;
  Navigator.of(context).pushNamed(
    route,
    arguments: anchor.isEmpty ? null : {'anchor': anchor},
  );
}

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
        // Both controllers are ChangeNotifiers, so this is the listener that
        // makes "an update arrived" and "a paper is still owed" arrive here at
        // all. The cart and the viewport come in as dependencies below.
        // CMD #2117 — the search box's focus is a third input to the same
        // answer, so it arrives the same way the other two do.
        animation: Listenable.merge(
            [appUpdateBar, appRegistrationBar, SearchChromeFocus.suppressed]),
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
              _BarSlot(key: kBarSlotKey, kind: live.kind),
            ],
          ),
        );
      },
    );
  }
}

/// The ONE bar slot: [BottomStackMetrics.slot] tall while there is something
/// in it on a shell with a bottom nav, and 0 tall the rest of the time.
///
/// #2066 kept this box at full height either way so the pill above it could
/// not move. #2091 closes it, because on a staff shell — which floats no pill
/// for it to hold still — the permanently reserved box WAS the bug: a blank
/// white strip above the nav on every admin screen, months at a time, holding
/// room for a bar that was not there.
///
/// CMD #2112 — it now holds EITHER bar. Same box, same height, same
/// [UpdateBar] widget, so "the registration banner has the same position,
/// shape, size and colour as the update banner" is one renderer rather than
/// two that have to be kept equal. Which one is in it is
/// [BottomStackLiveMetrics.kind]; this widget only draws.
class _BarSlot extends StatelessWidget {
  const _BarSlot({super.key, required this.kind});

  final BottomBarKind kind;

  @override
  Widget build(BuildContext context) {
    // Live proof that the ONE-slot renderer is the one painting, and which of
    // the two bars it is holding. Written on every build, including the empty
    // one, so a curl of the render-log can tell "no bar" from "no renderer".
    try {
      RenderLog.write('c2112_bar_slot', 1);
      RenderLog.write('c2112_bar_kind', kind.name);
    } catch (_) {}
    return _Collapsible(
        show: kind != BottomBarKind.none,
        height: BottomStackMetrics.slot,
        child: switch (kind) {
          BottomBarKind.update => UpdateBar(
              title: appUpdateBar.label,
              actionLabel: appUpdateBar.actionLabel,
              updatingLabel: appUpdateBar.updatingLabel,
              downloadedLabel: appUpdateBar.downloadedLabel,
              updating: appUpdateBar.updating,
              downloaded: appUpdateBar.downloaded,
              // FLUSH, and exactly one slot tall: the bar fills the box it
              // was given instead of publishing a height of its own.
              fixedHeight: BottomStackMetrics.slot,
              onUpdate: appUpdateBar.onUpdate ?? _noop,
            ),
          // The registration ask. Every string is
          // `customer_registration_bar()`'s, and Continue opens the ONE
          // registration screen — resuming from whatever is already saved, on
          // the section the backend named.
          BottomBarKind.registration => UpdateBar(
              key: kRegistrationBarKey,
              leading: Icons.assignment_outlined,
              title: appRegistrationBar.label,
              actionLabel: appRegistrationBar.actionLabel,
              updatingLabel: appRegistrationBar.actionLabel,
              updating: false,
              fixedHeight: BottomStackMetrics.slot,
              onUpdate: () => _openRegistration(context),
            ),
          // CMD #2114 — the login ask. A signed-out visitor had no way of
          // knowing there was anything to log in to; this is the same pill in
          // the same box, and Login opens the login screen at the address the
          // backend named.
          BottomBarKind.login => UpdateBar(
              key: kLoginBarKey,
              leading: Icons.person_outline,
              title: appRegistrationBar.label,
              actionLabel: appRegistrationBar.actionLabel,
              updatingLabel: appRegistrationBar.actionLabel,
              updating: false,
              fixedHeight: BottomStackMetrics.slot,
              actionIdentifier: kLoginBarActionId,
              onUpdate: () => _openRegistration(context),
            ),
          BottomBarKind.none => null,
        },
      );
  }

  /// The button, for either ask. The address and the section both arrive in
  /// the payload — `/login` for the login bar, the registration form for the
  /// registration bar — and a backend that sent no route opens nothing rather
  /// than guessing one.
  static void _openRegistration(BuildContext context) {
    final route = appRegistrationBar.route;
    if (route.isEmpty) return;
    final anchor = appRegistrationBar.anchor;
    Navigator.of(context).pushNamed(
      route,
      arguments: anchor.isEmpty ? null : {'anchor': anchor},
    );
  }

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
  Widget build(BuildContext context) {
    // CMD #2140 — the shell's page host already holds the chrome's room back
    // for the whole tab ([BottomStackClearance]), so an end-of-list box
    // inside it owes only the page's own air. Counting the chrome twice is
    // the dead band this avoids.
    if (context.dependOnInheritedWidgetOfExactType<_ChromeCleared>() != null) {
      // CMD #2147 — plus whatever bottom padding the host handed down that no
      // scroll view above this box has already applied: a floating host's
      // chrome, inside a CustomScrollView. A ListView consumes (and removes)
      // it, so there this is 0 and nothing is counted twice.
      return SizedBox(height: extra + MediaQuery.paddingOf(context).bottom);
    }
    return BottomStackLive(
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
}

/// CMD #2140 — marks a subtree whose host already clears the bottom chrome.
class _ChromeCleared extends InheritedWidget {
  const _ChromeCleared({required super.child, this.dock = 0});

  /// CMD #2147 — on a FLOATING host, the room under the bottom stack that
  /// the floating dock takes (0 on a padded host, which already cleared it).
  final double dock;

  @override
  bool updateShouldNotify(_ChromeCleared oldWidget) => oldWidget.dock != dock;
}

/// CMD #2147 — the floating dock's share of the bottom a page must clear, on
/// top of [bottomStackLiveOf]'s. 0 anywhere but a floating customer host.
double floatingDockClearanceOf(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_ChromeCleared>()?.dock ?? 0;

/// CMD #2147 — a FLOATING page host: the page runs the full height, behind
/// the View cart pill, the bars and the floating dock, and is TOLD how much of
/// its bottom they cover through `MediaQuery.padding.bottom` — which a
/// ListView / GridView applies as scroll padding by itself, and which
/// [BottomStackSpacer] reads for a CustomScrollView. So the page shows through
/// around the pill (no solid strip behind it) and its last row still scrolls
/// clear of everything.
class _FloatingClearance extends StatelessWidget {
  const _FloatingClearance({required this.child, required this.pill});
  final Widget child;
  final bool pill;

  @override
  Widget build(BuildContext context) => BottomStackLive(
        pill: pill,
        builder: (context, live) {
          final mq = MediaQuery.of(context);
          // With `extendBody`, the Scaffold hands its body the dock's height
          // as bottom padding; that is the part under the stack.
          final dock = mq.padding.bottom;
          try {
            RenderLog.write('c2147_float_clear', (live.height + dock).round());
          } catch (_) {}
          return MediaQuery(
            data: mq.copyWith(
                padding: mq.padding.copyWith(bottom: dock + live.height)),
            child: _ChromeCleared(dock: dock, child: child),
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
          // CMD #2147 — under a floating dock (`extendBody`) the body's own
          // bottom padding IS the dock: a padded host clears it too, and takes
          // it off its child so nothing inside counts it again.
          final dock = hasNav ? MediaQuery.paddingOf(context).bottom : 0.0;
          return AnimatedPadding(
            duration: BottomStackLive.motion,
            curve: BottomStackLive.motionCurve,
            padding: EdgeInsets.only(bottom: live.height + safeBottom + dock),
            child: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: _ChromeCleared(child: child)),
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

/// CMD #2140 — EVERY shell tab ends above the chrome, customer tabs too.
///
/// Bulk Upload v4: the registration bar covered "Add matched to cart", the
/// progress bar and the last review cards, because only Home and Catalogue
/// ever remembered a [BottomStackSpacer]. The shell now clears the live
/// chrome (bar, plus the pill and its air on a tab that floats one) for the
/// whole page host, so no tab has to remember — and the spacers that did are
/// told so ([_ChromeCleared]) and stop counting it a second time.
///
/// CMD #2147 — [float]: a customer tab whose scroll views take their bottom
/// room from `MediaQuery` (Home, Catalogue, Profile) FLOATS instead: the page
/// shows behind the pill and the dock, and its last row still clears them.
Widget shellPageHost(Widget child,
        {required bool staff, bool pill = false, bool float = false}) =>
    !staff && float
        ? _FloatingClearance(pill: pill, child: child)
        : BottomStackClearance(pill: !staff && pill, child: child);

/// The same box for a `CustomScrollView`.
class BottomStackSliverSpacer extends StatelessWidget {
  const BottomStackSliverSpacer({super.key, this.pill = true});

  /// See [BottomStackSpacer.pill].
  final bool pill;

  @override
  Widget build(BuildContext context) =>
      SliverToBoxAdapter(child: BottomStackSpacer(pill: pill));
}
