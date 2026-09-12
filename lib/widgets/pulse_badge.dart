import 'package:flutter/material.dart';
import '../design_tokens.dart';

/// CHANGE #1017 (5) — a badge that PULSES when its count goes up.
///
/// Motion tells state: new work arrived, the badge says so once, then rests.
/// A badge only exists while `count > 0` (spec 4 — badges for work waiting,
/// never decorative). Timing and curve come from the motion tokens.
class PulseBadge extends StatefulWidget {
  const PulseBadge({super.key, required this.count, required this.child});
  final int count;
  final Widget child;

  @override
  State<PulseBadge> createState() => _PulseBadgeState();
}

class _PulseBadgeState extends State<PulseBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  int _prev = 0;

  @override
  void initState() {
    super.initState();
    _prev = widget.count;
    _ctrl = AnimationController(vsync: this, duration: Ds.motion.sheet);
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.3), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.3, end: 0.9), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 0.9, end: 1.0), weight: 40),
    ]).animate(CurvedAnimation(parent: _ctrl, curve: Ds.motion.curve));
  }

  @override
  void didUpdateWidget(PulseBadge old) {
    super.didUpdateWidget(old);
    if (widget.count > _prev) _ctrl.forward(from: 0);
    _prev = widget.count;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.count <= 0) return widget.child;
    return Badge(
      label: ScaleTransition(
        scale: _scale,
        child: Text('${widget.count}'),
      ),
      backgroundColor: Ds.c.danger,
      child: widget.child,
    );
  }
}
