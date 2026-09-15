import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/product.dart';
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
/// The ONLY thing decided here is geometry — how many columns fit — because
/// that is the width of the device and not a business rule. Everything on the
/// card (price, MRP, PTR, pack chip, ribbon, ADD label, Rx badge) is the
/// backend's string, drawn by the card itself.
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

  /// The gaps between cards. Home's grid numbers, so the two cannot drift.
  static const double crossGap = 12;
  static const double mainGap = 12;

  /// 2 up on a phone, 3 on a tablet, 4–5 on a desktop — measured from the card
  /// the grid is actually laying out (its rail width plus one gap) rather than
  /// from breakpoints someone has to remember to keep in step.
  ///
  /// [width] is the grid's own maxWidth, i.e. AFTER the page padding. 360 px
  /// phone → 2, 412 px → 2, 768 px tablet → 3, 1280 px+ → 5 or 6.
  static int columnsFor(double width) {
    const slot = CompactProductCard.railWidth + crossGap; // 162 + 12
    final n = ((width + crossGap) / slot).floor();
    return n.clamp(2, 6);
  }

  /// The delegate, in one place, so a sliver grid and a box grid cannot
  /// disagree about the extent.
  static SliverGridDelegate delegateFor(double width) =>
      SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columnsFor(width),
        // The card's own constant: a taller card must never be clipped by a
        // number typed into a screen.
        mainAxisExtent: CompactProductCard.extent,
        crossAxisSpacing: crossGap,
        mainAxisSpacing: mainGap,
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => GridView.builder(
          shrinkWrap: shrinkWrap,
          physics: physics,
          padding: padding ?? EdgeInsets.zero,
          addAutomaticKeepAlives: false,
          gridDelegate: delegateFor(c.maxWidth),
          itemCount: items.length,
          itemBuilder: (context, i) => CompactProductCard(
            key: ValueKey(items[i].id),
            product: items[i],
            onTap: () => onOpen(items[i]),
            onPeek: onPeek == null ? null : () => onPeek!(items[i]),
          ),
        ),
      );
}

/// The loading state for [ProductCardGrid]: the CARD's own footprint, at the
/// card's own extent, in the same columns the real grid will use. A skeleton,
/// never a bare spinner — the design QA gate's rule six.
class ProductCardGridSkeleton extends StatelessWidget {
  const ProductCardGridSkeleton({super.key, this.tiles = 6, this.padding});

  final int tiles;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: padding ?? EdgeInsets.zero,
        gridDelegate: ProductCardGrid.delegateFor(c.maxWidth),
        itemCount: tiles,
        itemBuilder: (_, _) => DecoratedBox(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: Ds.c.divider),
          ),
        ),
      ),
    );
  }
}
