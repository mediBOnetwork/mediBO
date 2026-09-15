import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/product.dart';
import 'product_card_grid.dart';
import 'product_image.dart';

/// CMD #2044 — the Catalogue tab draws the SAME product card as Home and as
/// search, through [ProductCardGrid]. CMD #1903's row card is deleted: one row
/// per product made the catalogue and the storefront two different-looking
/// lists of the same products, which is the thing #1903 set out to fix and the
/// thing it left behind.
///
/// What is left in this file is what a LIST still needs and the card does not
/// own: the loading skeleton at the grid's own footprint, and the long-press
/// peek sheet.

/// The grid's loading state: the CARD's own footprint, at the card's own
/// extent, in the columns the real grid will use. A skeleton, never a spinner —
/// the design QA gate's rule six.
///
/// CMD #2044 — it draws [ProductCardGridSkeleton] because the list it stands in
/// for is now the shared product grid, not a row list.
class CatalogueCardSkeleton extends StatelessWidget {
  const CatalogueCardSkeleton({super.key, this.tiles = 4});

  final int tiles;

  @override
  Widget build(BuildContext context) => ProductCardGridSkeleton(tiles: tiles);
}

class CataloguePeekSheet extends StatelessWidget {
  final Product product;
  final String title;
  final String openLabel;
  final VoidCallback onOpen;

  const CataloguePeekSheet({
    super.key,
    required this.product,
    required this.title,
    required this.openLabel,
    required this.onOpen,
  });

  static const double _plate = 96;

  @override
  Widget build(BuildContext context) {
    final rx = product.rx;
    final rxLabel =
        (rx != null && rx['has'] == true) ? (rx['label'] ?? '').toString() : '';
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty) ...[
              Text(title, style: Ds.t.caption),
              SizedBox(height: Ds.space.x12),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: _plate,
                  width: _plate,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Ds.c.surface,
                    borderRadius: Ds.r.rCard,
                    border: Border.all(color: Ds.c.divider),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(Ds.space.x8),
                    child: ProductImage(
                        url: product.imageUrl,
                        width: _plate,
                        height: _plate,
                        radius: Ds.r.rChip),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(product.name, style: Ds.t.subtitle),
                      SizedBox(height: Ds.space.x4),
                      Text(product.manufacturer, style: Ds.t.caption),
                      if (product.genericName.isNotEmpty) ...[
                        SizedBox(height: Ds.space.x4),
                        Text(product.genericName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Ds.t.caption),
                      ],
                      if (rxLabel.isNotEmpty) ...[
                        SizedBox(height: Ds.space.x4),
                        Text(rxLabel, style: Ds.t.caption),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (openLabel.isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.touch.minTarget,
                width: double.infinity,
                child: FilledButton(
                  onPressed: onOpen,
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.brand,
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  child: Text(openLabel),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
