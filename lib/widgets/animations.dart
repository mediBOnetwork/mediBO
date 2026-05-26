import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Momentum-carrying scroll physics tuned for Flutter web.
///
/// Flutter's default BouncingScrollSimulation uses a hardcoded friction drag of
/// 0.135/s which stops a 1,000 px/s fling in only ~500 px — about 18× shorter
/// than iOS Safari. This class overrides the ballistic simulation to use
/// ClampingScrollSimulation with 2× velocity amplification and 0.006 friction
/// (vs the default 0.015), giving ~2 seconds of natural deceleration over
/// ~1,500 px per 1,000 px/s flick.
class MomentumScrollPhysics extends ClampingScrollPhysics {
  const MomentumScrollPhysics({super.parent});

  @override
  MomentumScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      MomentumScrollPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    final Tolerance tolerance = toleranceFor(position);
    if (velocity.abs() < tolerance.velocity && !position.outOfRange) {
      return null;
    }
    return ClampingScrollSimulation(
      position: position.pixels,
      velocity: velocity * 2.0, // amplify fling so fast flicks carry further
      friction: 0.006,          // 0.015 default is too aggressive; lower = slower decay
      tolerance: tolerance,
    );
  }
}

/// App-wide scroll behavior: all input devices, no scrollbar.
/// Web gets ClampingScrollPhysics (instant stop — wheel delta is precise);
/// mobile keeps MomentumScrollPhysics (ballistic fling with deceleration).
class SmoothScrollBehavior extends MaterialScrollBehavior {
  const SmoothScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      platformScrollPhysics();

  // Hide the persistent web scrollbar for a cleaner native feel.
  @override
  Widget buildScrollbar(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}

/// Web: ClampingScrollPhysics so the scroll position tracks the wheel delta
/// exactly and stops the instant the wheel stops.
/// Mobile: MomentumScrollPhysics with tuned friction for a native-feel fling.
ScrollPhysics platformScrollPhysics() => kIsWeb
    ? const ClampingScrollPhysics(parent: AlwaysScrollableScrollPhysics())
    : const MomentumScrollPhysics(parent: AlwaysScrollableScrollPhysics());

/// ScrollController that adds momentum to discrete wheel events on web.
///
/// Flutter's [PointerScrollEvent] route bypasses ScrollPhysics entirely —
/// it calls [ScrollPosition.pointerScroll] which just snaps pixels directly.
/// This controller intercepts those calls, accumulates recent wheel deltas,
/// and once the wheel pauses (100 ms silence) fires an [animateTo] that
/// travels the same distance a ballistic simulation would cover.
class MomentumScrollController extends ScrollController {
  MomentumScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _MomentumScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class _MomentumScrollPosition extends ScrollPositionWithSingleContext {
  _MomentumScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  Timer? _wheelTimer;
  final List<({int ms, double delta})> _recent = [];

  @override
  void pointerScroll(double delta) {
    // Let Flutter handle the immediate pixel snap as usual.
    super.pointerScroll(delta);
    if (!kIsWeb) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    // Keep only events within the last 200 ms to measure velocity.
    _recent.removeWhere((e) => now - e.ms > 200);
    _recent.add((ms: now, delta: delta));

    // Reset the "wheel stopped" timer every time a new event arrives.
    _wheelTimer?.cancel();
    _wheelTimer = Timer(const Duration(milliseconds: 100), _onWheelEnd);
  }

  void _onWheelEnd() {
    if (_recent.length < 2) {
      _recent.clear();
      return;
    }
    final totalDelta = _recent.fold<double>(0, (s, e) => s + e.delta);
    final spanMs = max<int>(_recent.last.ms - _recent.first.ms, 16);
    // px/s — positive = scroll down
    final velocity = totalDelta / spanMs * 1000;
    _recent.clear();

    if (velocity.abs() < 150) return; // ignore tiny nudges

    final sim = physics.createBallisticSimulation(this, velocity);
    if (sim == null) return;

    // Walk the simulation to find its natural end point.
    double t = 0;
    while (!sim.isDone(t) && t < 4.0) {
      t += 0.016;
    }
    final target =
        sim.x(t).clamp(minScrollExtent, maxScrollExtent);
    final durationMs = (t * 1000).clamp(200.0, 2500.0).round();
    if ((target - pixels).abs() < 5) return;

    animateTo(
      target,
      duration: Duration(milliseconds: durationMs),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _wheelTimer?.cancel();
    super.dispose();
  }
}

/// Wraps a child with a quick scale-down while pressed. Uses a [Listener] so
/// it never competes with the child's own tap handling (buttons, InkWell).
class PressEffect extends StatefulWidget {
  final Widget child;
  final double scale;
  const PressEffect({super.key, required this.child, this.scale = 0.96});

  @override
  State<PressEffect> createState() => _PressEffectState();
}

class _PressEffectState extends State<PressEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 110),
    reverseDuration: const Duration(milliseconds: 160),
  );
  late final Animation<double> _scale = Tween(begin: 1.0, end: widget.scale)
      .animate(CurvedAnimation(parent: _c, curve: Curves.easeOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _c.forward(),
      onPointerUp: (_) => _c.reverse(),
      onPointerCancel: (_) => _c.reverse(),
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

/// Lifts a card on mouse hover (web/desktop): subtle scale + drop shadow.
class HoverLift extends StatefulWidget {
  final Widget child;
  final double radius;
  const HoverLift({super.key, required this.child, this.radius = 16});

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _hover ? 1.025 : 1.0,
        duration: const Duration(milliseconds: 170),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black
                    .withValues(alpha: _hover ? 0.14 : 0.04),
                blurRadius: _hover ? 22 : 8,
                offset: Offset(0, _hover ? 10 : 3),
              ),
            ],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Plays a one-shot fade + slide-up entrance, optionally after [delay] (used
/// to stagger items as they load into the grid). Driven by an AnimationController.
class EntranceAnimator extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;
  const EntranceAnimator({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 380),
  });

  @override
  State<EntranceAnimator> createState() => _EntranceAnimatorState();
}

class _EntranceAnimatorState extends State<EntranceAnimator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween(
    begin: const Offset(0, 0.14),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// A continuously animating shimmer used for skeleton placeholders. Masks its
/// child (a set of opaque grey shapes) with a moving highlight band.
class Shimmer extends StatefulWidget {
  final Widget child;
  const Shimmer({super.key, required this.child});

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = _c.value;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [
                Color(0xFFE8EBEE),
                Color(0xFFF4F6F8),
                Color(0xFFE8EBEE),
              ],
              stops: [
                (t - 0.3).clamp(0.0, 1.0),
                t.clamp(0.0, 1.0),
                (t + 0.3).clamp(0.0, 1.0),
              ],
            ).createShader(bounds);
          },
          child: child,
        );
      },
    );
  }
}

/// An opaque grey rounded box for building skeleton layouts inside [Shimmer].
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;
  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.radius = 8,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Brand.border,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
