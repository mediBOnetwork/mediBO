import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/product.dart';
import '../models/storefront_p3.dart' show WishlistResult;
import 'card_layout.dart';
import 'compact_product_card.dart';

/// CMD #2044 — THE product grid, and the only one in the app.
///
/// Om: search results and every catalogue inner page (Company, Salt, Use,
/// Category, the A–Z lists) answered with horizontal list ROWS while Home
/// answered with cards. Same product, two shapes, two prices to keep in step.
/// CMD #1903's `ProductRowCard` is deleted and every product surface now draws
/// [CompactProductCard] through this one widget, so a surface cannot pick its
/// own card, its own column count or its own spacing.
///
/// CMD #2167 — and it no longer reserves a HEIGHT. A grid row is an
/// [IntrinsicHeight] row of cards: every card in that row is as tall as the
/// tallest one in it, and no card carries dead space under its price. The
/// column count and the gap come from the backend's `card.layout`
/// (min_card_w / grid_gap / max_cols), so re-shaping the grid is an
/// app_settings update.
/// No gap under the LAST row — a named zero, because a bare number inside an
/// EdgeInsets is what the design-literal gate is there to catch.
const double _noGap = 0;

class ProductCardGrid extends StatelessWidget {
  const ProductCardGrid({
    super.key,
    required this.items,
    required this.onOpen,
    this.onPeek,
    this.shrinkWrap = true,
    this.physics = const NeverScrollableScrollPhysics(),
    this.padding,
  });

  final List<Product> items;

  /// The grid owns routing so the card stays free of route literals.
  final void Function(Product product) onOpen;

  /// The catalogue's long-press peek. Absent on the surfaces that do not offer
  /// it, which is why it is nullable rather than a flag.
  final void Function(Product product)? onPeek;

  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry? padding;

  /// The layout the FIRST card in this list carries, for the screen it is
  /// being drawn on. An empty list falls back to the last layout seen.
  static CardLayout layoutFor(BuildContext context, List<Product> items) =>
      CardLayout.of(items.isEmpty ? null : items.first.card,
          screen: CardSurface.of(context));

  /// 2 up on a phone, 3 on a tablet, 4–6 on a desktop — measured from the
  /// backend's minimum card width rather than from breakpoints someone has to
  /// remember to keep in step. [width] is the grid's own maxWidth, i.e. AFTER
  /// the page padding.
  static int columnsFor(double width, [CardLayout? layout]) =>
      (layout ?? CardLayout.latest('')).columnsFor(width);

  /// The width of ONE card across [width]. THE number: a rail asks for the
  /// same one, which is what makes a home card and a catalogue card identical.
  static double cardWidth(double width, [CardLayout? layout]) =>
      (layout ?? CardLayout.latest('')).cardWidth(width);

  /// The delegate the SKELETONS use — a real grid no longer needs one, since
  /// its rows measure themselves. The reserved height is the square plate plus
  /// the body the card draws under it, so a skeleton is the size of the card
  /// that replaces it.
  static SliverGridDelegate delegateFor(double width, [CardLayout? layout]) {
    final l = layout ?? CardLayout.latest('');
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: l.columnsFor(width),
      mainAxisExtent: l.cardWidth(width) + CompactProductCard.bodyV6,
      crossAxisSpacing: l.gridGap,
      mainAxisSpacing: l.gridGap,
    );
  }

  /// One row of the grid, every card in it the height of the tallest.
  static Widget row({
    required BuildContext context,
    required List<Product> items,
    required int start,
    required int columns,
    required CardLayout layout,
    required void Function(Product) onOpen,
    void Function(Product)? onPeek,
  }) {
    final children = <Widget>[];
    for (var i = 0; i < columns; i++) {
      final idx = start + i;
      if (i > 0) children.add(SizedBox(width: layout.gridGap));
      children.add(
        Expanded(
          child: idx < items.length
              ? CompactProductCard(
                  key: ValueKey(items[idx].id),
                  product: items[idx],
                  onTap: () => onOpen(items[idx]),
                  onPeek: onPeek == null ? null : () => onPeek(items[idx]),
                )
              : const SizedBox.shrink(),
        ),
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  /// The sliver form, for the screens that build their page as slivers. Same
  /// rows, same shared height, lazily built.
  static Widget sliverRows({
    required List<Product> items,
    required double width,
    required CardLayout layout,
    required void Function(Product) onOpen,
    void Function(Product)? onPeek,
  }) {
    final cols = layout.columnsFor(width);
    final rows = (items.length + cols - 1) ~/ cols;
    final last = rows - 1;
    return SliverList.builder(
      itemCount: rows,
      itemBuilder: (context, r) => Padding(
        padding: EdgeInsets.only(bottom: r == last ? _noGap : layout.gridGap),
        child: row(
          context: context,
          items: items,
          start: r * cols,
          columns: cols,
          layout: layout,
          onOpen: onOpen,
          onPeek: onPeek,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          final layout = layoutFor(context, items);
          final cols = layout.columnsFor(c.maxWidth);
          final rows = (items.length + cols - 1) ~/ cols;
          final last = rows - 1;
          Widget rowAt(BuildContext context, int r) => Padding(
                padding: EdgeInsets.only(
                    bottom: r == last ? _noGap : layout.gridGap),
                child: row(
                  context: context,
                  items: items,
                  start: r * cols,
                  columns: cols,
                  layout: layout,
                  onOpen: onOpen,
                  onPeek: onPeek,
                ),
              );
          if (shrinkWrap) {
            return Padding(
              padding: padding ?? EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var r = 0; r < rows; r++) rowAt(context, r),
                ],
              ),
            );
          }
          return ListView.builder(
            physics: physics,
            padding: padding ?? EdgeInsets.zero,
            itemCount: rows,
            itemBuilder: rowAt,
          );
        },
      );
}

/// The loading state for [ProductCardGrid]: the CARD's own footprint, in the
/// columns the real grid will use, at the height the last real card measured.
/// A skeleton, never a bare spinner — the design QA gate's rule six.
class ProductCardGridSkeleton extends StatelessWidget {
  const ProductCardGridSkeleton({super.key, this.tiles = 6, this.padding});

  final int tiles;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final layout = CardLayout.latest(CardSurface.of(context));
    return LayoutBuilder(
      builder: (context, c) => GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: padding ?? EdgeInsets.zero,
        gridDelegate: ProductCardGrid.delegateFor(c.maxWidth, layout),
        itemCount: tiles,
        itemBuilder: (_, _) => DecoratedBox(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: BorderRadius.circular(layout.radius),
            border: Border.all(color: Ds.c.divider),
          ),
        ),
      ),
    );
  }
}

/// CMD #2167 — the horizontal rail, and the only one in the app.
///
/// Its cards are the width [ProductCardGrid] would give them on the SAME page,
/// so the home feed and the catalogue draw the same card at the same size, and
/// the next card peeks past the right edge instead of a third fitting. Every
/// card in the rail is as tall as the tallest one in it.
class ProductCardRail extends StatelessWidget {
  const ProductCardRail({
    super.key,
    required this.items,
    required this.onOpen,
    this.onPeek,
    this.wishlistToggle,
    this.controller,
    this.compareLabel = '',
    this.onCompare,
  });

  final List<Product> items;
  final void Function(Product product) onOpen;
  final void Function(Product product)? onPeek;
  final Future<WishlistResult> Function(String productId)? wishlistToggle;
  final ScrollController? controller;
  final String compareLabel;
  final void Function(Product product)? onCompare;

  /// The width one rail card takes on a page [width] wide (the FULL page
  /// width — the rail subtracts the backend's own page padding itself).
  static double cardWidth(BuildContext context, double width,
      [List<Product> items = const []]) {
    final l = items.isEmpty
        ? CardLayout.latest(CardSurface.of(context))
        : CardLayout.of(items.first.card, screen: CardSurface.of(context));
    return l.cardWidth(width - l.pagePad * 2);
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final layout =
        CardLayout.of(items.first.card, screen: CardSurface.of(context));
    return LayoutBuilder(
      builder: (context, c) {
        final page = c.maxWidth.isFinite
            ? c.maxWidth
            : MediaQuery.sizeOf(context).width;
        final w = layout.cardWidth(page - layout.pagePad * 2);
        // A horizontal scroll has no width to measure a child against, so the
        // rail asks the LAYOUT how tall this card is at this width rather
        // than reserving a constant — one answer for every card in the rail,
        // which is what "one row, one height" means here.
        return SizedBox(
          height: layout.cardHeight(w),
          child: SingleChildScrollView(
            controller: controller,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: layout.pagePad),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) SizedBox(width: layout.gridGap),
                  SizedBox(
                    width: w,
                    child: CompactProductCard(
                      key: ValueKey(items[i].id),
                      product: items[i],
                      onTap: () => onOpen(items[i]),
                      wishlistToggle: wishlistToggle,
                      onPeek:
                          onPeek == null ? null : () => onPeek!(items[i]),
                      compareLabel: onCompare == null ? '' : compareLabel,
                      onCompare: onCompare == null
                          ? null
                          : () => onCompare!(items[i]),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
