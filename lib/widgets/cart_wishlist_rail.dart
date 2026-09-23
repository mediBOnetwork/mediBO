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

import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../models/product.dart';
import '../models/storefront_p3.dart' show WishlistResult;
import 'product_card_grid.dart';

class CartWishlistRail extends StatelessWidget {
  final String title;
  final List<Product> items;

  /// Injected so the rail owns no route literal — the cart screen decides
  /// where a card goes, exactly as the home feed's rails do.
  final void Function(Product product) onOpen;

  /// CMD #2152 — called after a heart tap on a rail card lands, so the cart
  /// re-reads its payload and the rail shows the backend's new wishlist.
  final VoidCallback? onWishChanged;

  const CartWishlistRail({
    super.key,
    required this.title,
    required this.items,
    required this.onOpen,
    this.onWishChanged,
  });

  Future<WishlistResult> _toggle(String productId) async {
    final res = await MedicineRepository().wishlistToggle(productId);
    if (res.ok) onWishChanged?.call();
    return res;
  }

  /// Builds the rail from the `rail` object of cart_render(). Returns null
  /// when the backend says there is nothing to suggest, so the cart omits the
  /// block rather than drawing an empty band.
  ///
  /// CMD #2167 — `cards` first: "You may also like" now sends the SAME full
  /// card block the storefront grid reads (wish heart, v6 layout and all),
  /// and `items` is the same array under its older name.
  static CartWishlistRail? fromPayload(
      Object? raw, void Function(Product product) onOpen,
      {VoidCallback? onWishChanged}) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    if (m['has'] != true) return null;
    final list = (m['cards'] as List?) ?? (m['items'] as List?) ?? const [];
    final items = list
        .whereType<Map>()
        .map((e) => Product.fromHomeCard(Map<String, dynamic>.from(e)))
        .toList();
    if (items.isEmpty) return null;
    return CartWishlistRail(
      title: (m['title'] ?? '').toString(),
      items: items,
      onOpen: onOpen,
      onWishChanged: onWishChanged,
    );
  }

  // CMD #2087 — the rail's own gaps, as named constants.
  // CMD #2167 — but NOT a height. The card is measured, not reserved: the
  // rail is as tall as the tallest card it drew, at the same card width the
  // catalogue uses. A band sized from a constant was how a taller card got
  // clipped and a shorter one left a hole under the price.
  static const double _topGap = 8;
  static const double _titleH = 24;
  static const double _titleGap = 12;
  static const double _bottomGap = 16;

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
        // CMD #2167 — the ONE rail, drawn out of the ONE card. There is no
        // second card design and no second width in this file.
        ProductCardRail(
          items: items,
          onOpen: onOpen,
          wishlistToggle: onWishChanged == null ? null : _toggle,
        ),
        SizedBox(height: _bottomGap),
      ],
    );
  }
}
