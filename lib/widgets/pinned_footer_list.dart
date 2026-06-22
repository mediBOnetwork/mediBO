import 'package:flutter/material.dart';

/// Scrollable content area with a footer that pins to the bottom when
/// content is short, and follows the last item naturally when content is long.
///
/// Requires a bounded-height parent (e.g. [Expanded], [SizedBox] with height).
/// When the parent provides finite height [LayoutBuilder] detects it and:
///   • short content → [Expanded] spacer pushes [footer] to the bottom.
///   • long content  → [SingleChildScrollView] scrolls; [footer] is the last
///     element; bottom padding provides the sole clearance above the nav.
///
/// [padding] is the scroll view's padding and is the SINGLE source of bottom
/// clearance — do NOT add extra SafeArea / Padding below this widget.
class PinnedFooterList extends StatelessWidget {
  final List<Widget> children;
  final Widget footer;
  final EdgeInsets padding;
  final double footerGap;
  final ScrollController? controller;

  const PinnedFooterList({
    super.key,
    required this.children,
    required this.footer,
    this.padding = const EdgeInsets.only(bottom: 12),
    this.footerGap = 16,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final double available = constraints.maxHeight;
      final bool bounded = available.isFinite;

      final content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...children,
          // Collapses to 0 on overflow (IntrinsicHeight resolves Expanded);
          // on short content it eats the slack so footer sinks to bottom.
          if (bounded) const Expanded(child: SizedBox.shrink()),
          SizedBox(height: footerGap),
          footer,
        ],
      );

      // Bottom clearance lives ONLY here — single source, no extra gap.
      return SingleChildScrollView(
        controller: controller,
        padding: padding,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: bounded ? (available - padding.vertical) : 0,
          ),
          child: IntrinsicHeight(child: content),
        ),
      );
    });
  }
}
