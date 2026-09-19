// CMD #2087 — the cart's RAIL SLOT.
//
// Before this change the suggestion rails and the bill were trailing rows of
// the SAME ListView the cart lines live in, so every add, every remove and
// every quantity tap re-laid the list out and the rails jumped under the
// finger that was still on the screen.
//
// They are now a slot of their own, below a cart-rows list that scrolls
// inside its own box. The rows grow in that list; the slot does not move.
// Each rail inside it reserves a CONSTANT height — [railExtent], summed from
// the card's own constants rather than typed as a number — so a rail that
// comes back with three cards and a rail that comes back with ten occupy
// exactly the same band.
//
// Nothing here is worded or ordered by this file: each rail draws whichever
// `{has, title, items}` block cart_render() sent, in the order the payload
// fixes (Wishlist, then "You may also like").

import 'package:flutter/material.dart';

import '../utils/render_log.dart';
import 'cart_wishlist_rail.dart';

class CartRailSlot extends StatelessWidget {
  /// The rails to draw, already built from their payloads. A null entry is a
  /// rail the backend said it had nothing for — it is skipped, never drawn as
  /// an empty band.
  final List<CartWishlistRail?> rails;

  const CartRailSlot({super.key, required this.rails});

  /// The height ONE rail always occupies. It is the rail's OWN constant, not
  /// a second number typed here: CartWishlistRail.extent is summed from the
  /// gaps it draws and the card it fills, so the slot and the rail cannot
  /// disagree.
  static const double railExtent = CartWishlistRail.extent;

  /// CMD #2090 — the rails as the PAGE's own blocks, in payload order.
  ///
  /// The cart no longer stacks them inside a slot of its own: they are two
  /// children of the one page scroll, each still at its constant height, so
  /// a rail with three cards and one with ten occupy the same band. A rail
  /// the backend had nothing for contributes no block at all.
  static List<Widget> blocks(List<CartWishlistRail?> rails) => [
        for (final r in rails.whereType<CartWishlistRail>())
          SizedBox(height: railExtent, child: ClipRect(child: r)),
      ];

  @override
  Widget build(BuildContext context) {
    final shown = rails.whereType<CartWishlistRail>().toList(growable: false);
    if (shown.isEmpty) return const SizedBox.shrink();
    RenderLog.write(
      'c2087_rail_slot',
      'rails=${shown.length};extent=${railExtent.toStringAsFixed(0)}',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in shown)
          SizedBox(
            height: railExtent,
            child: ClipRect(child: r),
          ),
      ],
    );
  }
}
