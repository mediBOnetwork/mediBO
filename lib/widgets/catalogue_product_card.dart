import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/product.dart';
import 'product_image.dart';
import 'product_row_card.dart';

/// CMD #1903 — the Catalogue tab's grid card is GONE, and with it the variant
/// chips that used to sit on it.
///
/// Om: searching or browsing must answer with ONE ROW PER PRODUCT. A card that
/// folded a brand's packs behind "10s · 15s · Syrup" hid the pack a pharmacy
/// was actually looking for, and it made the Catalogue tab and the search
/// results two different-looking lists of the same products. Both surfaces now
/// draw [ProductRowCard], so they cannot look different, and the pack family
/// lives on the product page as the "Other packs" strip under the price.
///
/// What stayed here is what a LIST still needs and the row card does not own:
/// the loading skeleton at the row's own height, and the long-press peek.

/// The list's loading state: the ROW's own boxes, at the row's own height.
/// A skeleton, never a spinner — the design QA gate's rule six.
class CatalogueCardSkeleton extends StatelessWidget {
  const CatalogueCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Container(
        height: ProductRowCard.rowHeight,
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bone(ProductRowCard.imageSize, ProductRowCard.imageSize),
            SizedBox(width: Ds.space.x12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bone(double.infinity, Ds.space.x16),
                  SizedBox(height: Ds.space.x8),
                  _bone(double.infinity, Ds.space.x12),
                ],
              ),
            ),
            SizedBox(width: Ds.space.x12),
            _bone(ProductRowCard.priceColW, ProductRowCard.addH),
          ],
        ),
      );

  Widget _bone(double w, double h) => Container(
        width: w,
        height: h,
        decoration: BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rChip),
      );
}

/// CHANGE #799 — the quick peek. A long press on a card opens this instead of
/// pushing the product page: same facts, no navigation, no round trip.
///
/// Every line of it is already on the card's own payload — which is exactly
/// why it is worth having on a slow connection. It shows nothing it would have
/// to fetch, and it never invents a heading: an absent salt is an absent row.
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
