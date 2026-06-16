import 'package:flutter/material.dart';

/// Opens a scrollable, safe-area-aware bottom sheet that caps at 90% of the
/// viewport height. Items are ALWAYS reachable regardless of screen size.
///
/// Usage:
///   showResponsiveSheet(context: context, builder: (ctx) => MyContent());
Future<T?> showResponsiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color backgroundColor = Colors.white,
  BorderRadius? borderRadius,
}) {
  final br = borderRadius ??
      const BorderRadius.vertical(top: Radius.circular(20));
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    shape: RoundedRectangleBorder(borderRadius: br),
    backgroundColor: backgroundColor,
    builder: (ctx) {
      final mq = MediaQuery.of(ctx);
      final maxH = mq.size.height * 0.90;
      final bottomPad =
          mq.viewInsets.bottom + mq.viewPadding.bottom;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: bottomPad),
          child: builder(ctx),
        ),
      );
    },
  );
}

/// Centers content up to [maxWidth] on wide screens; full-width on small ones.
class ResponsiveCenter extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const ResponsiveCenter({
    super.key,
    required this.child,
    this.maxWidth = 840,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Wraps a screen body in SafeArea + SingleChildScrollView that also pads for
/// the on-screen keyboard so fields are never obscured.
class ScrollableSafePage extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const ScrollableSafePage({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: SingleChildScrollView(
        padding: padding.copyWith(bottom: padding.bottom + bottom),
        child: child,
      ),
    );
  }
}
