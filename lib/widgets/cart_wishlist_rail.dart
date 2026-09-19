// CMD #2014 — the cart's wishlist / suggested rail.
//
// The rail reuses [CompactProductCard] EXACTLY as the storefront draws it —
// Rx badge, image, pack chip, ADD pill, name, company, struck MRP, sale price
// (PTR) and the availability line. There is deliberately no second card design
// in this file: a card that looked almost like the storefront's would be a
// worse outcome than no rail at all.
//
// What goes in it, what it is called and what order it is in are all
// cart_rail_block()'s decision, carried on cart_render() — read from
// cart_rail_config, laddering the
// viewer's wishlist, then the cart's co-purchase companions, then the widely
// stocked catalogue. This widget renders that list and nothing else.

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/product.dart';
import 'compact_product_card.dart';

class CartWishlistRail extends StatelessWidget {
  final String title;
  final List<Product> items;

  /// Injected so the rail owns no route literal — the cart screen decides
  /// where a card goes, exactly as the home feed's rails do.
  final void Function(Product product) onOpen;

  const CartWishlistRail({
    super.key,
    required this.title,
    required this.items,
    required this.onOpen,
  });

  /// Builds the rail from the `rail` object of cart_render(). Returns null
  /// when the backend says there is nothing to suggest, so the cart omits the
  /// block rather than drawing an empty band.
  static CartWishlistRail? fromPayload(
      Object? raw, void Function(Product product) onOpen) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    if (m['has'] != true) return null;
    final list = (m['items'] as List?) ?? const [];
    final items = list
        .whereType<Map>()
        .map((e) => Product.fromHomeCard(Map<String, dynamic>.from(e)))
        .toList();
    if (items.isEmpty) return null;
    return CartWishlistRail(
      title: (m['title'] ?? '').toString(),
      items: items,
      onOpen: onOpen,
    );
  }

  /// The card width the storefront rails use. Kept as a named constant so the
  /// reserved height below cannot drift from the card that fills it.
  static const double cardW = 156;

  // CMD #2087 — the rail occupies a CONSTANT height. Every gap below is a
  // named constant and [extent] is their sum, so the fixed slot this rail
  // sits in (CartRailSlot) reserves exactly the band the rail draws: a rail
  // with three cards cannot be a different height from one with ten, and the
  // blocks beneath it never move when the payload changes.
  static const double _topGap = 8;
  static const double _titleH = 24;
  static const double _titleGap = 12;
  static const double _bottomGap = 16;

  /// The height one rail always takes: gap, title line, gap, card, gap.
  static const double extent =
      _topGap + _titleH + _titleGap + CompactProductCard.extent + _bottomGap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: _topGap),
        // CMD #2087 — the title sits on the SAME 16px gutter the cart rows
        // use, so the rail reads as one more full-width block of the page
        // rather than an inset card.
        SizedBox(
          height: _titleH,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(title,
                  style: Ds.t.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        SizedBox(height: _titleGap),
        SizedBox(
          height: CompactProductCard.extent,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            itemExtent: cardW + Ds.space.x12,
            itemCount: items.length,
            itemBuilder: (context, i) {
              final p = items[i];
              return Padding(
                padding: EdgeInsets.only(right: Ds.space.x12),
                child: SizedBox(
                  width: cardW,
                  child: CompactProductCard(
                    product: p,
                    onTap: () => onOpen(p),
                  ),
                ),
              );
            },
          ),
        ),
        SizedBox(height: _bottomGap),
      ],
    );
  }
}
