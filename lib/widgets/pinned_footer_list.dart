import 'package:flutter/material.dart';

/// Renders [items] as a Column followed by [footer].
/// When total content height is less than [minHeight], a [Spacer] pushes
/// [footer] to the bottom — "sticky footer" effect without a floating overlay.
/// When content is tall (items exceed [minHeight]), [footer] follows the last
/// item and the caller's outer scroll handles overflow.
///
/// IMPORTANT: [items] must NOT be scrollable widgets — [IntrinsicHeight]
/// is used to establish a finite column height.
class PinnedFooterList extends StatelessWidget {
  final List<Widget> items;
  final Widget footer;
  final double minHeight;
  final EdgeInsetsGeometry itemsPadding;
  final double itemSpacing;
  final EdgeInsetsGeometry footerPadding;

  const PinnedFooterList({
    super.key,
    required this.items,
    required this.footer,
    required this.minHeight,
    this.itemsPadding = const EdgeInsets.fromLTRB(16, 8, 16, 0),
    this.itemSpacing = 4,
    this.footerPadding = const EdgeInsets.fromLTRB(16, 12, 16, 12),
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: IntrinsicHeight(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: itemsPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < items.length; i++) ...[
                    items[i],
                    if (i < items.length - 1) SizedBox(height: itemSpacing),
                  ],
                ],
              ),
            ),
            const Spacer(),
            Padding(padding: footerPadding, child: footer),
          ],
        ),
      ),
    );
  }
}
