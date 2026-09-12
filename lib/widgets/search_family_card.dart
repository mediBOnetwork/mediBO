import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/product.dart';
import 'compact_product_card.dart';

/// CHANGE #790 — one brand family as ONE card, with a chip per variant.
///
/// Monticope, Monticope-A, Monticope Syrup and Monticope 5 mg are one brand
/// from one company, so a search for "monticope" shows one card and four
/// chips instead of four near-identical cards. The grouping is NOT done here:
/// `storefront_search_page()` folds the rows with `brand_family_key()` and
/// hands the grid a `blocks` list already in render order, so the family a
/// shopper sees can never disagree between two screens.
///
/// Every string is the payload's — the printed brand, the "by <company>"
/// line, the "12 variants" counter and each chip's own label. Each chip is a
/// real product: tapping it opens THAT product, and adding is per variant.
class SearchFamilyCard extends StatelessWidget {
  const SearchFamilyCard({
    super.key,
    required this.block,
    required this.onOpenProduct,
  });

  /// One `blocks[]` entry with `kind: 'family'`.
  final Map<String, dynamic> block;

  /// Opens one variant's product page. The id is the variant's own.
  final void Function(String productId) onOpenProduct;

  /// The grid reserves the same height for a family card as for a product
  /// card, so a row never goes ragged. It is the product card's own constant,
  /// never a number copied here (#636's lesson).
  static double get extent => CompactProductCard.extent;

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  List<Map<String, dynamic>> get _variants =>
      ((block['variants'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final variants = _variants;
    return Container(
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(block, 'title'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Ds.t.body),
          if (_s(block, 'sub_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(block, 'sub_label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x4),
          Text(_s(block, 'count_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: Ds.space.x8,
                runSpacing: Ds.space.x8,
                children: [
                  for (final v in variants)
                    // A chip hugs its label AND sits left: a Container with a
                    // non-null alignment would fill the Wrap's loose
                    // constraints instead (#229's trap), so there is none.
                    InkWell(
                      borderRadius: Ds.r.rChip,
                      onTap: () => onOpenProduct('${v['id'] ?? ''}'),
                      child: Container(
                        constraints:
                            BoxConstraints(minHeight: Ds.touch.minTarget),
                        padding: EdgeInsets.symmetric(
                            horizontal: Ds.space.x12,
                            vertical: Ds.space.x8),
                        decoration: BoxDecoration(
                          color: Ds.c.bg,
                          borderRadius: Ds.r.rChip,
                          border: Border.all(color: Ds.c.divider),
                        ),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            (v['variant_label'] ?? v['product_name'] ?? '')
                                .toString(),
                            style: Ds.t.caption,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders ONE `blocks[]` entry, whichever kind it is.
///
/// A block this build has never heard of renders nothing at all rather than
/// throwing — the same forward-compatibility rule the home feed follows, so
/// the backend can add a block kind without a deploy breaking the grid.
class SearchResultBlock extends StatelessWidget {
  const SearchResultBlock({
    super.key,
    required this.block,
    required this.onOpenProduct,
    this.productFor,
  });

  final Map<String, dynamic> block;
  final void Function(String productId) onOpenProduct;

  /// Builds the product card for a `kind:'product'` block. Injected so a
  /// protected test can pump this widget without the full card and its
  /// images, and so the grid keeps using the SAME card it always did.
  final Widget Function(Map<String, dynamic> item)? productFor;

  @override
  Widget build(BuildContext context) {
    final kind = (block['kind'] ?? '').toString();
    if (kind == 'family') {
      return SearchFamilyCard(block: block, onOpenProduct: onOpenProduct);
    }
    if (kind == 'product') {
      final item = block['item'];
      if (item is! Map) return const SizedBox.shrink();
      final map = Map<String, dynamic>.from(item);
      final build = productFor;
      if (build != null) return build(map);
      return CompactProductCard(
        product: Product.fromMap(map),
        onTap: () => onOpenProduct('${map['id'] ?? ''}'),
      );
    }
    return const SizedBox.shrink();
  }
}
