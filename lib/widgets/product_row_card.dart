import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../design_tokens.dart';
import '../models/product.dart';
import 'compact_product_card.dart' show showPriceLockedSheet;
import 'product_image.dart';

/// CMD #1903 — ONE row per product, and the one card every list draws.
///
/// Om's direction: searching "monticope" must answer with Monticope Tablet as
/// the first ROW — image, name, company, pack, the printed ceiling, the rate,
/// and an ADD — not with a brand-family card whose actual packs are hidden
/// behind chips. So the family card is gone, the chips are gone from every
/// list, and search and the catalogue now draw this same widget: two surfaces
/// that show the same product cannot look like two different products.
///
/// Left to right, exactly as drawn:
///
///  1. **A 72pt image**, square, on the row's leading edge.
///  2. **The name** (two lines), **the company**, **the pack** — the middle
///     column, which takes whatever width is left.
///  3. **The MRP, struck**, then **`price_display`** (the trade amount, or the
///     literal word "PTR" when the backend locked it), then **ADD** — a
///     fixed-width trailing column, so a list of rows keeps one price gutter
///     rather than a ragged one.
///
/// It invents nothing. Every string here — the name, the company, both pack
/// strings, the MRP, the sale line and the ADD word — arrived on the payload,
/// and `price_locked` (not an approval check written here) is what makes the
/// sale line tappable.
class ProductRowCard extends StatefulWidget {
  final Product product;

  /// Opens the product page — where the pack family now lives.
  final VoidCallback onTap;

  /// Long-press → the quick peek sheet. Null disables the gesture.
  final VoidCallback? onPeek;

  /// The toast the backend words for a successful add, and its undo word.
  /// Both empty → no snackbar at all rather than one worded here.
  final String addedLabel;
  final String undoLabel;

  const ProductRowCard({
    super.key,
    required this.product,
    required this.onTap,
    this.onPeek,
    this.addedLabel = '',
    this.undoLabel = '',
  });

  // ── Fixed geometry, on the 4-point rhythm ────────────────────────────────
  /// The image, and the tallest thing in the row.
  static const double imageSize = 72;

  /// The trailing column: MRP over the sale line over the ADD control. Wide
  /// enough for "MRP ₹1,174.38" struck and for −/qty/+ at the same width, so
  /// the gutter does not move when the first tap lands.
  static const double priceColW = 116;

  /// The add control's height. With the gaps around it the whole trailing
  /// column clears the 44pt touch minimum.
  static const double addH = 34;

  static const double _mrpH = 15;
  static const double _priceH = 20;

  /// The middle column, line by line: two lines of name, the company, the
  /// pack. It is TALLER than the image, so it — not the image — is what the
  /// row reserves height for.
  static const double _nameH = 38;
  static const double _metaH = 16;

  /// The row's tallest column.
  static double get contentHeight =>
      _nameH + Ds.space.x4 + _metaH + Ds.space.x4 + _metaH;

  /// The row's own laid-out height: the tallest column plus the card's
  /// padding.
  static double get rowHeight => contentHeight + Ds.space.x12 * 2;

  /// The height a list reserves per row — the row plus the gap under it.
  /// Summed from the parts below it, never a number copied into the list
  /// (#636's lesson), so a taller row can never overflow its container.
  static double get extent => rowHeight + Ds.space.x12;

  @override
  State<ProductRowCard> createState() => _ProductRowCardState();
}

class _ProductRowCardState extends State<ProductRowCard> {
  /// The tick that replaces the ADD word for one beat — the only animation on
  /// this row, and it means "the tap landed".
  bool _ticked = false;

  void _add(BuildContext context) {
    final cart = AppState.of(context);
    if (cart.isPending(widget.product.id)) return;
    cart.addId(widget.product.id);
    HapticFeedback.selectionClick();
    setState(() => _ticked = true);
    Future<void>.delayed(Ds.motion.standard * 3, () {
      if (mounted) setState(() => _ticked = false);
    });

    if (widget.addedLabel.isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(widget.addedLabel,
            style: Ds.t.body.copyWith(color: Ds.c.surface)),
        backgroundColor: Ds.c.text,
        behavior: SnackBarBehavior.floating,
        duration: Ds.motion.standard * 20,
        action: widget.undoLabel.isEmpty
            ? null
            : SnackBarAction(
                label: widget.undoLabel,
                textColor: Ds.c.surface,
                onPressed: () => cart.decrementId(widget.product.id),
              ),
      ));
  }

  /// The pack line: the two pack strings the backend already worded, joined by
  /// the one separator this app uses. Either being empty is an absence the
  /// payload declared, so it simply is not printed.
  static String _packLine(Product p) {
    final parts = <String>[
      if (p.packTypeLabel.isNotEmpty) p.packTypeLabel,
      if (p.packQtyLabel.isNotEmpty) p.packQtyLabel,
    ];
    return parts.join(' · ');
  }

  static String _addLabel(Product p) {
    final a = p.availability;
    if (a == null) return '';
    return a.ctaShort.isNotEmpty ? a.ctaShort : a.ctaLabel;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final cart = AppState.of(context);
    final qty = cart.quantityOf(p.id);
    final canAdd = p.availability?.canAdd ?? true;
    final pack = _packLine(p);

    return Semantics(
      button: true,
      label: p.name,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onPeek,
        borderRadius: Ds.r.rCard,
        child: Ink(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1,
          ),
          padding: EdgeInsets.all(Ds.space.x12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: ProductRowCard.imageSize,
                height: ProductRowCard.contentHeight,
                child: Center(
                  child: ClipRRect(
                    borderRadius: Ds.r.rCard,
                    child: ProductImage(
                      url: p.imageUrl,
                      width: ProductRowCard.imageSize,
                      height: ProductRowCard.imageSize,
                      radius: Ds.r.rCard,
                    ),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: SizedBox(
                  height: ProductRowCard.contentHeight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: ProductRowCard._nameH,
                        child: Text(
                          p.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Ds.t.bodyStrong,
                        ),
                      ),
                      SizedBox(height: Ds.space.x4),
                      SizedBox(
                        height: ProductRowCard._metaH,
                        child: Text(
                          p.manufacturer,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                        ),
                      ),
                      SizedBox(height: Ds.space.x4),
                      SizedBox(
                        height: ProductRowCard._metaH,
                        child: pack.isEmpty
                            ? const SizedBox.shrink()
                            : Text(
                                pack,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Ds.t.caption
                                    .copyWith(color: Ds.c.textSecondary),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              SizedBox(
                width: ProductRowCard.priceColW,
                height: ProductRowCard.contentHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _RowPrice(price: p.pricing?.cardPrice),
                    SizedBox(
                      height: ProductRowCard.addH,
                      width: ProductRowCard.priceColW,
                      child: qty > 0
                          ? _RowQtyBar(
                              qty: qty,
                              onMinus: () => cart.decrementId(p.id),
                              onPlus: () => cart.incrementId(p.id),
                            )
                          : _RowAddButton(
                              label: _addLabel(p),
                              enabled: canAdd,
                              ticked: _ticked,
                              onTap: () => _add(context),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The two price lines, right-aligned: the struck ceiling, then the sale line.
/// Both are backend strings and this widget divides nothing — `price_display`
/// is already either the trade amount or the word "PTR".
class _RowPrice extends StatelessWidget {
  final CardPrice? price;
  const _RowPrice({required this.price});

  @override
  Widget build(BuildContext context) {
    final p = price;
    if (p == null) {
      return SizedBox(
          height: ProductRowCard._mrpH + ProductRowCard._priceH + Ds.space.x4);
    }
    final sale = Text(
      p.priceDisplay,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
      style: Ds.t.bodyStrong.copyWith(
        color: p.priceLocked ? Ds.c.brand : Ds.c.text,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: ProductRowCard._mrpH,
          child: !p.hasMrp
              ? const SizedBox.shrink()
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    p.mrpLabel.isEmpty
                        ? p.mrpDisplay
                        : '${p.mrpLabel} ${p.mrpDisplay}',
                    maxLines: 1,
                    style: Ds.t.caption.copyWith(
                      color: Ds.c.textSecondary,
                      decoration: p.strikeMrp
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                      decorationColor: Ds.c.textSecondary,
                    ),
                  ),
                ),
        ),
        SizedBox(height: Ds.space.x4),
        SizedBox(
          height: ProductRowCard._priceH,
          child: p.priceDisplay.isEmpty
              ? const SizedBox.shrink()
              : (p.priceLocked
                  ? InkWell(
                      onTap: () => showPriceLockedSheet(context, p),
                      borderRadius: Ds.r.rChip,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(child: sale),
                          SizedBox(width: Ds.space.x4),
                          Icon(Icons.lock_outline_rounded,
                              size: Ds.space.x12, color: Ds.c.brand),
                        ],
                      ),
                    )
                  : Align(alignment: Alignment.centerRight, child: sale)),
        ),
      ],
    );
  }
}

/// One green ADD, and its word is the backend's. Disabled is the backend's
/// verdict too (`availability.can_add`), never a stock number read here.
class _RowAddButton extends StatelessWidget {
  final String label;
  final bool enabled;
  final bool ticked;
  final VoidCallback onTap;
  const _RowAddButton({
    required this.label,
    required this.enabled,
    required this.ticked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final on = enabled && !ticked;
    return Material(
      color: enabled ? Ds.c.brand : Ds.c.divider,
      borderRadius: Ds.r.rButton,
      child: InkWell(
        onTap: on ? onTap : null,
        borderRadius: Ds.r.rButton,
        child: Center(
          child: ticked
              ? Icon(Icons.check_rounded,
                  size: Ds.space.x16, color: Ds.c.surface)
              : Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption.copyWith(
                    color: enabled ? Ds.c.surface : Ds.c.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
  }
}

/// −/qty/+ at the ADD control's own size, so the row does not reflow when the
/// first unit lands in the cart.
class _RowQtyBar extends StatelessWidget {
  final int qty;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _RowQtyBar(
      {required this.qty, required this.onMinus, required this.onPlus});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.brand,
        borderRadius: Ds.r.rButton,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _Step(icon: Icons.remove_rounded, onTap: onMinus),
          Text('$qty',
              style: Ds.t.caption.copyWith(
                color: Ds.c.surface,
                fontWeight: FontWeight.w700,
              )),
          _Step(icon: Icons.add_rounded, onTap: onPlus),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _Step({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rButton,
      child: SizedBox(
        width: ProductRowCard.addH,
        height: ProductRowCard.addH,
        child: Icon(icon, size: Ds.space.x16, color: Ds.c.surface),
      ),
    );
  }
}
