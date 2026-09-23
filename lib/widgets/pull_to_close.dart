// CMD #2170 — pull down to close, on every screen, from ONE place.
//
// THE SHAPE OF THIS FEATURE
// The spec's first line is the important one: "One shared wrapper, not
// per-screen code." So nothing here is wired into a screen. There are exactly
// two injection points and neither belongs to a page:
//
//   1. [PullClosePageTransitions] is the app's `PageTransitionsTheme` builder
//      (lib/theme.dart). Flutter hands it EVERY pushed `MaterialPageRoute`, so
//      the product page, search, cart, compare, company, category, wishlist,
//      bulk upload, an order and the profile pages all get the gesture without
//      knowing it exists — and so does the next screen anyone adds.
//   2. [PullToHomeTab] wraps the shell's tab host once (shell_bottom_bars.dart),
//      so Catalogue, Bulk, Orders and Profile pull back to the Home tab. Home
//      itself is excluded by the backend, because Home's pull is the refresh it
//      already has.
//
// WHY IT DRIVES THE ROUTE'S OWN ANIMATION
// The gesture does not draw a fake page. It runs `route.controller` backwards,
// exactly the way iOS's back-swipe does, between `didStartUserGesture()` and
// `didStopUserGesture()`. That one decision buys four of the spec's bullets for
// free, because it is what the framework already reacts to:
//   • the page underneath becomes visible (a route stops being opaque while its
//     animation is running), and it is the SAME page — same scroll offset, same
//     rail offsets, same filters, same search text, no rebuild (spec 5);
//   • `HeroController.didStartUserGesture` starts the hero flight, so the photo
//     shrinks back into the very card it grew out of (spec 3);
//   • the back button, Android back and browser back all pop the same route
//     through the same controller, so they close identically (spec 4);
//   • a short pull is just the controller run forward again (spec 2).
//
// NOTHING HERE IS A TASTE THE APP HOLDS
// Every number — 120 dp, 700 dp/s, 200 ms, 250 ms, 24 dp, the dim, which routes
// participate, which tabs pull home — is `Ds.pullClose`, which is
// `ui_boot().design.pull_close`. Re-tuning the gesture is one UPDATE.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

/// How the page reacts to a pull that is in progress.
///
/// Pure so the protected test can check the decisions without a Navigator, a
/// canvas or a gesture: given a pull distance and a release velocity, does the
/// page close or spring back, and what does it look like on the way?
class PullCloseGeometry {
  const PullCloseGeometry(this.t);

  /// 1.0 = the page is at rest, 0.0 = it is entirely gone.
  final double t;

  static PullCloseGeometry forPull(double pulledPx, double viewportPx) {
    if (viewportPx <= 0) return const PullCloseGeometry(1);
    final moved = (pulledPx * Ds.pullClose.follow).clamp(0.0, viewportPx);
    return PullCloseGeometry(1 - moved / viewportPx);
  }

  /// The page's downward offset for a viewport [h].
  double offset(double h) => (1 - t) * h;

  /// Top corners round off as the page leaves; square again at rest.
  double get radius => Ds.pullClose.cornerDp * (1 - t);

  double get scale => Ds.pullClose.scaleMin + (1 - Ds.pullClose.scaleMin) * t;

  /// The dim layer over the screen behind: full at rest, gone when the page is.
  double get scrimOpacity => (Ds.pullClose.scrimOpacity * t).clamp(0.0, 1.0);

  /// A pull closes when it went far enough OR was flicked fast enough — the
  /// backend owns both numbers, and a short slow pull springs back.
  static bool shouldClose(double pulledPx, double velocityPxPerS) =>
      pulledPx >= Ds.pullClose.thresholdDp ||
      velocityPxPerS >= Ds.pullClose.flingDps;
}

/// Recognises ONLY a deliberate downward pull that starts at the top of the
/// page, and claims it from the list underneath the moment it is sure.
///
/// A plain `VerticalDragGestureRecognizer` cannot do this: the scrollable's own
/// recogniser sits deeper in the arena and wins every vertical drag. This one
/// watches the pointer itself and resolves EARLY — after [slop] of downward
/// travel while [canStart] is true — so the list never starts scrolling. Any
/// other direction, or a pull that starts mid-list, is handed straight back and
/// scrolling behaves exactly as it always did (spec 2, "normal scrolling
/// unchanged").
class PullDownRecognizer extends OneSequenceGestureRecognizer {
  PullDownRecognizer({
    required this.canStart,
    required this.onPullStart,
    required this.onPullUpdate,
    required this.onPullEnd,
    super.debugOwner,
  });

  /// Reassigned every rebuild by the recogniser factory, so the callbacks
  /// always close over the CURRENT state — a stale one would pull a page that
  /// has already gone.
  bool Function() canStart;
  VoidCallback onPullStart;
  ValueChanged<double> onPullUpdate;

  /// Downward velocity in logical px/s at release.
  ValueChanged<double> onPullEnd;

  Offset? _down;
  bool _won = false;
  VelocityTracker? _velocity;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _down = event.position;
    _won = false;
    _velocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  @override
  void handleEvent(PointerEvent event) {
    final down = _down;
    if (down == null) return;
    if (event is PointerMoveEvent) {
      _velocity?.addPosition(event.timeStamp, event.position);
      final d = event.position - down;
      if (_won) {
        onPullUpdate(d.dy);
        return;
      }
      final slop = Ds.pullClose.slopDp;
      if (d.dy >= slop && d.dy.abs() > d.dx.abs() && canStart()) {
        resolve(GestureDisposition.accepted);
      } else if (d.distance >= slop) {
        // Not ours — give the list its drag back, untouched.
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
      }
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_won) {
        final v = _velocity?.getVelocity().pixelsPerSecond.dy ?? 0;
        onPullEnd(event is PointerCancelEvent ? 0 : v);
      }
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {
    if (_won) return;
    _won = true;
    onPullStart();
  }

  @override
  void rejectGesture(int pointer) => stopTrackingPointer(pointer);

  @override
  void didStopTrackingLastPointer(int pointer) {
    _won = false;
    _down = null;
    _velocity = null;
  }

  @override
  String get debugDescription => 'pull down to close';
}

/// Tracks whether the page's own vertical scrollable is at its top.
///
/// The gesture may only start there (spec 2). A page with no scrollable at all
/// never reports, and stays "at top" — which is the right answer for it.
class _AtTop {
  bool value = true;

  bool onNotification(ScrollNotification n) {
    if (n.depth != 0) return false;
    final m = n.metrics;
    if (m.axis != Axis.vertical) return false;
    value = m.pixels <= m.minScrollExtent + 0.5;
    return false;
  }
}

/// The app's page transition — and the whole gesture with it.
///
/// [fallback] keeps every denied route (the staff/admin surfaces and the auth
/// pages, named by the backend) on the platform transition it has always had.
class PullClosePageTransitions extends PageTransitionsBuilder {
  const PullClosePageTransitions(this.fallback);

  final PageTransitionsBuilder fallback;

  @override
  Duration get transitionDuration => Ds.pullClose.close;

  /// Deliberately none: "the screen behind stays alive — same scroll, same
  /// rail offsets, same filters" (spec 5) means it must not move either.
  @override
  DelegatedTransitionBuilder? get delegatedTransition => null;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (!Ds.pullClose.allowsRoute(route.settings.name) || route.isFirst) {
      return fallback.buildTransitions(
          route, context, animation, secondaryAnimation, child);
    }
    return _PullClosePage(route: route, animation: animation, child: child);
  }
}

class _PullClosePage extends StatefulWidget {
  const _PullClosePage({
    required this.route,
    required this.animation,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final Animation<double> animation;
  final Widget child;

  @override
  State<_PullClosePage> createState() => _PullClosePageState();
}

class _PullClosePageState extends State<_PullClosePage> {
  final _atTop = _AtTop();

  /// True from the moment the pull is claimed until the page has either sprung
  /// back or finished leaving — it is what tells the paint to follow the finger
  /// rather than fade the page in.
  bool _dragging = false;
  double _pulled = 0;

  // ignore: invalid_use_of_protected_member
  AnimationController? get _controller => widget.route.controller;

  bool _canStart() =>
      Ds.pullClose.enabled &&
      _atTop.value &&
      widget.route.isCurrent &&
      widget.route.isActive &&
      !widget.route.isFirst &&
      widget.route.navigator != null &&
      !widget.route.navigator!.userGestureInProgress;

  void _start() {
    final nav = widget.route.navigator;
    if (nav == null || _controller == null) return;
    _pulled = 0;
    setState(() => _dragging = true);
    nav.didStartUserGesture();
    RenderLog.write('c2170_pull_start', 1);
  }

  void _update(double dy) {
    final c = _controller;
    if (!_dragging || c == null) return;
    final h = context.size?.height ?? MediaQuery.sizeOf(context).height;
    _pulled = dy < 0 ? 0 : dy;
    c.value = PullCloseGeometry.forPull(_pulled, h).t;
  }

  Future<void> _end(double velocity) async {
    final c = _controller;
    final nav = widget.route.navigator;
    if (!_dragging || c == null || nav == null) {
      setState(() => _dragging = false);
      return;
    }
    final close = PullCloseGeometry.shouldClose(_pulled, velocity);
    if (close) {
      RenderLog.write('c2170_pull_close', 1);
      // Pop first: popping is what makes the hero fly back into its card, and
      // it is exactly what the back button does — so both paths are one path.
      nav.pop();
      if (c.isAnimating) {
        await c
            .animateBack(0, duration: Ds.pullClose.close, curve: Ds.motion.curve)
            .orCancel
            .catchError((Object _) {});
      }
    } else {
      await c
          .animateTo(1, duration: Ds.pullClose.spring, curve: Ds.motion.curve)
          .orCancel
          .catchError((Object _) {});
    }
    nav.didStopUserGesture();
    if (mounted) setState(() => _dragging = false);
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c2170_pull_ready', 1);
    final page = NotificationListener<ScrollNotification>(
      onNotification: _atTop.onNotification,
      child: widget.child,
    );
    return Semantics(
      identifier: 'pull_to_close',
      hint: Ds.pullClose.hint,
      child: RawGestureDetector(
        behavior: HitTestBehavior.deferToChild,
        gestures: <Type, GestureRecognizerFactory>{
          PullDownRecognizer:
              GestureRecognizerFactoryWithHandlers<PullDownRecognizer>(
            () => PullDownRecognizer(
              canStart: _canStart,
              onPullStart: _start,
              onPullUpdate: _update,
              onPullEnd: _end,
              debugOwner: this,
            ),
            (r) => r
              ..canStart = _canStart
              ..onPullStart = _start
              ..onPullUpdate = _update
              ..onPullEnd = _end,
          ),
        },
        child: AnimatedBuilder(
          animation: widget.animation,
          child: page,
          builder: (context, host) => PullCloseSurface(
            t: widget.animation.value,
            // Opening is a fade while the hero grows out of the card; closing —
            // by finger or by back button — is the page sliding away while the
            // hero shrinks into it.
            following: _dragging ||
                widget.animation.status == AnimationStatus.reverse,
            child: host!,
          ),
        ),
      ),
    );
  }
}

/// What a pull LOOKS like: the dim layer over the screen behind, and the page
/// itself offset, scaled and with its top corners rounded off.
///
/// Split out with no gesture and no route so the protected test can render it
/// at any point of the pull.
class PullCloseSurface extends StatelessWidget {
  const PullCloseSurface({
    super.key,
    required this.t,
    required this.following,
    required this.child,
  });

  /// 1.0 = at rest, 0.0 = gone.
  final double t;

  /// True while the page tracks the finger (or slides away after it let go);
  /// false while it is arriving, when the hero does the moving instead.
  final bool following;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // At rest the page is EXACTLY what it was before this command: no clip, no
    // opacity layer, no scrim. The gesture costs nothing until it is used.
    if (t >= 1 && !following) return child;
    return LayoutBuilder(builder: _build);
  }

  Widget _build(BuildContext context, BoxConstraints constraints) {
    final g = PullCloseGeometry(t.clamp(0.0, 1.0));
    // The page travels its OWN height, not the screen's — a tab root sits
    // below the header and above the dock, and a page that moved by the whole
    // viewport would outrun the finger.
    final h = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : MediaQuery.sizeOf(context).height;
    final radius = BorderRadius.vertical(top: Radius.circular(g.radius));
    return Stack(
      // The page keeps the constraints it would have had without the Stack.
      fit: StackFit.passthrough,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(
              color: Ds.pullClose.scrim.withValues(alpha: g.scrimOpacity),
            ),
          ),
        ),
        Transform.translate(
          offset: Offset(0, following ? g.offset(h) : 0),
          child: Transform.scale(
            scale: g.scale,
            child: Opacity(
              opacity: following ? 1.0 : g.t,
              child: ClipRRect(borderRadius: radius, child: child),
            ),
          ),
        ),
      ],
    );
  }
}

/// The tab roots: Catalogue, Bulk, Orders and Profile pull back to the Home
/// tab. Which indices do it — and that Home is not one of them, because Home's
/// pull is its refresh — is the backend's list, not this file's.
class PullToHomeTab extends StatefulWidget {
  const PullToHomeTab({
    super.key,
    required this.page,
    required this.onHome,
    required this.child,
  });

  final int page;
  final VoidCallback onHome;
  final Widget child;

  @override
  State<PullToHomeTab> createState() => _PullToHomeTabState();
}

class _PullToHomeTabState extends State<PullToHomeTab>
    with SingleTickerProviderStateMixin {
  final _atTop = _AtTop();
  late final AnimationController _c = AnimationController(
    vsync: this,
    value: 1,
    duration: Ds.pullClose.close,
  );
  bool _dragging = false;
  double _pulled = 0;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  bool _canStart() => Ds.pullClose.pullsHome(widget.page) && _atTop.value;

  void _start() {
    _pulled = 0;
    setState(() => _dragging = true);
  }

  void _update(double dy) {
    if (!_dragging) return;
    final h = context.size?.height ?? MediaQuery.sizeOf(context).height;
    _pulled = dy < 0 ? 0 : dy;
    _c.value = PullCloseGeometry.forPull(_pulled, h).t;
  }

  Future<void> _end(double velocity) async {
    if (!_dragging) return;
    if (PullCloseGeometry.shouldClose(_pulled, velocity)) {
      RenderLog.write('c2170_tab_home', widget.page);
      await _c
          .animateBack(0, duration: Ds.pullClose.close, curve: Ds.motion.curve)
          .orCancel
          .catchError((Object _) {});
      widget.onHome();
      _c.value = 1;
    } else {
      await _c
          .animateTo(1, duration: Ds.pullClose.spring, curve: Ds.motion.curve)
          .orCancel
          .catchError((Object _) {});
    }
    if (mounted) setState(() => _dragging = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!Ds.pullClose.pullsHome(widget.page)) return widget.child;
    RenderLog.write('c2170_tab_ready', widget.page);
    final page = NotificationListener<ScrollNotification>(
      onNotification: _atTop.onNotification,
      child: widget.child,
    );
    return Semantics(
      identifier: 'pull_to_home',
      hint: Ds.pullClose.hint,
      child: RawGestureDetector(
        behavior: HitTestBehavior.deferToChild,
        gestures: <Type, GestureRecognizerFactory>{
          PullDownRecognizer:
              GestureRecognizerFactoryWithHandlers<PullDownRecognizer>(
            () => PullDownRecognizer(
              canStart: _canStart,
              onPullStart: _start,
              onPullUpdate: _update,
              onPullEnd: _end,
              debugOwner: this,
            ),
            (r) => r
              ..canStart = _canStart
              ..onPullStart = _start
              ..onPullUpdate = _update
              ..onPullEnd = _end,
          ),
        },
        child: AnimatedBuilder(
          animation: _c,
          child: page,
          builder: (context, host) => PullCloseSurface(
            t: _c.value,
            // At rest this is false, so PullCloseSurface hands the tab
            // straight back: no scrim, no clip, no extra layer on a tab
            // nobody is pulling.
            following: _dragging,
            child: host!,
          ),
        ),
      ),
    );
  }
}
