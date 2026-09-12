import 'package:flutter/material.dart';

import '../app_state.dart';
import '../design_tokens.dart';
import '../models/product_detail.dart' show PdCompanion;
import '../screens/product_detail_screen.dart';
import 'product_image.dart';

/// CMD #791 — "Frequently bought together".
///
/// The ONE rail both the product page and the cart draw, so a companion tile
/// looks and behaves the same on either. Every tile is a payload row:
///
///  * the price is `pricing.price_display` — the exact block a storefront card
///    reads, so a companion and its own card can never quote two prices,
///  * the ADD word is `availability.cta_label` and whether the button works at
///    all is `availability.can_add`, never a stock number counted here,
///  * `support_label` ("6 orders") is the backend's evidence string; this
///    widget prints no number of its own.
///
/// The pairs behind it are same-prescription-class only, enforced where the
/// pair is FORMED in `copurchase_rebuild()`. Nothing here filters, because a
/// second Rx rule written in Dart is a second answer waiting to disagree.
class CompanionRail extends StatelessWidget {
  final List<PdCompanion> items;
  const CompanionRail({super.key, required this.items});

  static const double _tile = 148;
  static const double _img = 96;
  static const double height = 226;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => SizedBox(width: Ds.space.x12),
        itemBuilder: (_, i) => _CompanionTile(item: items[i], width: _tile, imageSize: _img),
      ),
    );
  }
}

class _CompanionTile extends StatelessWidget {
  final PdCompanion item;
  final double width;
  final double imageSize;
  const _CompanionTile({
    required this.item,
    required this.width,
    required this.imageSize,
  });

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final av = item.availability;
    final pr = item.pricing;
    final canAdd = av?.canAdd ?? false;

    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: Ds.r.rCard,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ProductDetailScreen(productId: item.id),
          ),
        ),
        child: Container(
          padding: EdgeInsets.all(Ds.space.x8),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: Ds.c.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: ProductImage(
                  url: item.image,
                  width: imageSize,
                  height: imageSize,
                  radius: Ds.r.rButton,
                ),
              ),
              SizedBox(height: Ds.space.x8),
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.caption.copyWith(color: Ds.c.text),
              ),
              const Spacer(),
              if (pr != null && pr.hasPrice)
                Text(
                  pr.priceDisplay,
                  style: Ds.t.bodyStrong,
                )
              else if (item.supportLabel.isNotEmpty)
                Text(item.supportLabel, style: Ds.t.caption),
              SizedBox(height: Ds.space.x4),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: canAdd ? () => cart.addId(item.id) : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Ds.c.brand,
                    side: BorderSide(color: canAdd ? Ds.c.brand : Ds.c.divider),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  // The backend's own word for this button, in both states.
                  child: Text(
                    av?.ctaLabel ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.caption.copyWith(
                      color: canAdd ? Ds.c.brand : Ds.c.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
