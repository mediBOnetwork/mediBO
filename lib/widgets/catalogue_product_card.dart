import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../design_tokens.dart';
import '../models/catalogue.dart';
import '../models/product.dart';
import 'product_image.dart';

/// CHANGE #799 — the Catalogue tab's card.
///
/// Om's direction, verbatim: "Image, name, company, pack, one green Add. No
/// MRP row, no compare, no margin. Variant chips on the card (10s · 15s ·
/// Syrup) instead of duplicate cards."
///
/// So this is NOT [CompactProductCard] with things hidden. That card is the
/// storefront's B2B card and it stays exactly as it is — MRP struck above the
/// trade rate, scheme ribbon, purchase overlay — because the home rails and
/// the product page are still that shop. This one is the browse card: five
/// elements, one green action, and the pack family it belongs to.
///
/// What survived the cut and why:
///  * The TRADE RATE stays. It is the only number a pharmacy buys on
///    (`legal_get_page('about')`: MRP is the printed ceiling, never the selling
///    price), and it is the payload's own `pricing.ptr_display` string. What
///    went is the MRP row above it, the margin chip and the compare affordance
///    — the three consumer-shop devices Om named.
///  * Variant chips arrive from `catalogue_variants()` AFTER the grid paints,
///    so a card with no chips yet is a card that is still correct. The row is
///    reserved either way, so chips landing never reflows the grid.
///
/// Two rules, the same two every card in this app keeps: it invents no string,
/// and every size is a constant summed into [extent] so the grid's reserved
/// height and the widget's laid-out height cannot drift apart.
class CatalogueProductCard extends StatefulWidget {
  final Product product;

  /// The pack family this card belongs to. Empty until
  /// `catalogue_variants()` answers — and empty forever for a one-pack family,
  /// because the BACKEND said `has:false`.
  final List<CatVariant> variants;

  /// Opens the full product page.
  final VoidCallback onTap;

  /// Opens another pack of the same family.
  final ValueChanged<String>? onVariant;

  /// Long-press → the quick peek sheet. Null disables the gesture.
  final VoidCallback? onPeek;

  /// The toast the backend words for a successful add, and its undo word.
  /// Both empty → no snackbar at all rather than one worded here.
  final String addedLabel;
  final String undoLabel;

  const CatalogueProductCard({
    super.key,
    required this.product,
    required this.onTap,
    this.variants = const <CatVariant>[],
    this.onVariant,
    this.onPeek,
    this.addedLabel = '',
    this.undoLabel = '',
  });

  // ── Fixed geometry, on the 4-point rhythm ────────────────────────────────
  static const double plateH = 132;
  static const double _chipsH = 26; // the variant chip row, always reserved
  static const double _nameH = 36; // exactly two lines
  static const double _metaH = 16; // company, one line
  static const double _packH = 16; // pack, one line
  static const double _priceH = 20;
  static const double _addH = 40;

  static const double _gapS = 4;
  static const double _gapM = 8;
  static const double _pad = 8;

  /// The grid's mainAxisExtent, summed from the parts below it.
  static const double extent = plateH +
      _gapM +
      _chipsH +
      _gapS +
      _nameH +
      _gapS +
      _metaH +
      _packH +
      _gapS +
      _priceH +
      _gapM +
      _addH +
      _pad * 2;

  @override
  State<CatalogueProductCard> createState() => _CatalogueProductCardState();
}

class _CatalogueProductCardState extends State<CatalogueProductCard> {
  /// The tick that replaces the ADD word for one beat. Motion with a meaning:
  /// it confirms the tap landed, and it is the only animation on this card.
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

    // An undo snackbar, never a confirm dialog — the design contract's rule and
    // Om's ninth line. Both words are the backend's; with neither, nothing is
    // shown rather than a sentence invented here.
    if (widget.addedLabel.isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(widget.addedLabel, style: Ds.t.body.copyWith(color: Ds.c.surface)),
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

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final cart = AppState.of(context);
    final qty = cart.quantityOf(p.id);
    final canAdd = p.availability?.canAdd ?? true;

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
          padding: const EdgeInsets.all(CatalogueProductCard._pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Plate(product: p),
              const SizedBox(height: CatalogueProductCard._gapM),
              SizedBox(
                height: CatalogueProductCard._chipsH,
                child: _VariantChips(
                  variants: widget.variants,
                  onPick: widget.onVariant,
                ),
              ),
              const SizedBox(height: CatalogueProductCard._gapS),
              SizedBox(
                height: CatalogueProductCard._nameH,
                child: Text(
                  p.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.bodyStrong,
                ),
              ),
              const SizedBox(height: CatalogueProductCard._gapS),
              SizedBox(
                height: CatalogueProductCard._metaH,
                child: Text(
                  p.manufacturer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                ),
              ),
              SizedBox(
                height: CatalogueProductCard._packH,
                child: Text(
                  // The pack sentence the backend stored, verbatim, with its
                  // one-word form as the fallback. Nothing is shortened here.
                  p.packQtyLabel.isNotEmpty ? p.packQtyLabel : p.packTypeLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                ),
              ),
              const SizedBox(height: CatalogueProductCard._gapS),
              SizedBox(
                height: CatalogueProductCard._priceH,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    // The TRADE rate, already rendered. No MRP row above it, no
                    // margin chip beside it — Om's cut, kept here.
                    _rate(p),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.bodyStrong.copyWith(color: Ds.c.text),
                  ),
                ),
              ),
              const SizedBox(height: CatalogueProductCard._gapM),
              SizedBox(
                height: CatalogueProductCard._addH,
                child: qty > 0
                    ? _QtyBar(
                        qty: qty,
                        onMinus: () => cart.decrementId(p.id),
                        onPlus: () => cart.incrementId(p.id),
                      )
                    : _AddButton(
                        // One green Add, and its word is the backend's.
                        label: _addLabel(p),
                        enabled: canAdd,
                        ticked: _ticked,
                        onTap: () => _add(context),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The rate the pharmacy pays, taken from the payload's own rendered string.
  /// Absent is absent: no dash, no zero, no "Price on request" written here.
  static String _rate(Product p) {
    final pr = p.pricing;
    if (pr == null) return '';
    if (pr.hasPtr && pr.ptrDisplay.isNotEmpty) return pr.ptrDisplay;
    if (pr.hasPrice && pr.priceDisplay.isNotEmpty) return pr.priceDisplay;
    return '';
  }

  static String _addLabel(Product p) {
    final a = p.availability;
    if (a == null) return '';
    return a.ctaShort.isNotEmpty ? a.ctaShort : a.ctaLabel;
  }
}

/// A square white plate: same crop, white pad, never stretched. An absent image
/// is an absence the backend declared (empty string), so the placeholder is a
/// state of the card and not an error in it.
class _Plate extends StatelessWidget {
  final Product product;
  const _Plate({required this.product});

  @override
  Widget build(BuildContext context) => Container(
        height: CatalogueProductCard.plateH,
        width: double.infinity,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(CatalogueProductCard._gapM),
          child: ProductImage(
            url: product.imageUrl,
            width: CatalogueProductCard.plateH,
            height: CatalogueProductCard.plateH - CatalogueProductCard._gapM * 2,
            fit: BoxFit.contain,
            radius: Ds.r.rChip,
          ),
        ),
      );
}

/// "250mg DT Tablet · JR Oral Suspension · 5D Tablet" — the family's other
/// packs, so the grid shows one card per brand instead of five near-identical
/// ones. Every word is the backend's slice of the stored product name.
class _VariantChips extends StatelessWidget {
  final List<CatVariant> variants;
  final ValueChanged<String>? onPick;
  const _VariantChips({required this.variants, required this.onPick});

  @override
  Widget build(BuildContext context) {
    if (variants.isEmpty) return const SizedBox.shrink();
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      itemCount: variants.length,
      separatorBuilder: (_, _) => SizedBox(width: Ds.space.x4),
      itemBuilder: (context, i) {
        final v = variants[i];
        return Center(
          child: InkWell(
            onTap: v.selected || onPick == null ? null : () => onPick!(v.productId),
            borderRadius: Ds.r.rChip,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: v.selected ? Ds.c.brand : Ds.c.bg,
                borderRadius: Ds.r.rChip,
                border: Border.all(color: v.selected ? Ds.c.brand : Ds.c.divider),
              ),
              child: Text(
                v.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.caption.copyWith(
                    color: v.selected ? Ds.c.surface : Ds.c.textSecondary),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The one green action. Full width, 40 high inside a 44 tap row, and it says
/// what the backend told it to say.
class _AddButton extends StatelessWidget {
  final String label;
  final bool enabled;
  final bool ticked;
  final VoidCallback onTap;
  const _AddButton({
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
      color: enabled ? Ds.c.brand : Ds.c.bg,
      borderRadius: Ds.r.rButton,
      child: InkWell(
        onTap: on ? onTap : null,
        borderRadius: Ds.r.rButton,
        child: Center(
          child: ticked
              ? Icon(Icons.check_rounded, color: Ds.c.surface, size: Ds.t.bodySize)
              : Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.bodyStrong.copyWith(
                      color: enabled ? Ds.c.surface : Ds.c.textSecondary),
                ),
        ),
      ),
    );
  }
}

/// −  qty  + , in the same box the Add button occupied, so nothing moves when
/// the first tap lands.
class _QtyBar extends StatelessWidget {
  final int qty;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _QtyBar({required this.qty, required this.onMinus, required this.onPlus});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Ds.c.brand,
          borderRadius: Ds.r.rButton,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Step(icon: Icons.remove_rounded, onTap: onMinus),
            Text('$qty', style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface)),
            _Step(icon: Icons.add_rounded, onTap: onPlus),
          ],
        ),
      );
}

class _Step extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _Step({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: Ds.r.rButton,
        child: SizedBox(
          width: CatalogueProductCard._addH,
          height: CatalogueProductCard._addH,
          child: Icon(icon, color: Ds.c.surface, size: Ds.t.bodySize),
        ),
      );
}

/// The grid's loading state: the card's own boxes, at the card's own heights.
/// A skeleton, never a spinner — the design QA gate's rule six.
class CatalogueCardSkeleton extends StatelessWidget {
  const CatalogueCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(CatalogueProductCard._pad),
        decoration: BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _bone(CatalogueProductCard.plateH),
            const SizedBox(height: CatalogueProductCard._gapM),
            _bone(CatalogueProductCard._nameH),
            const SizedBox(height: CatalogueProductCard._gapS),
            _bone(CatalogueProductCard._metaH),
            const Spacer(),
            _bone(CatalogueProductCard._addH),
          ],
        ),
      );

  Widget _bone(double h) => Container(
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
  final List<CatVariant> variants;
  final String title;
  final String openLabel;
  final VoidCallback onOpen;
  final ValueChanged<String> onVariant;

  const CataloguePeekSheet({
    super.key,
    required this.product,
    required this.variants,
    required this.title,
    required this.openLabel,
    required this.onOpen,
    required this.onVariant,
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
            if (variants.isNotEmpty) ...[
              SizedBox(height: Ds.space.x16),
              Wrap(
                spacing: Ds.space.x8,
                runSpacing: Ds.space.x8,
                children: [
                  for (final v in variants)
                    InkWell(
                      onTap: v.selected ? null : () => onVariant(v.productId),
                      borderRadius: Ds.r.rChip,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: Ds.space.x12, vertical: Ds.space.x8),
                        decoration: BoxDecoration(
                          color: v.selected ? Ds.c.brand : Ds.c.bg,
                          borderRadius: Ds.r.rChip,
                          border: Border.all(
                              color: v.selected ? Ds.c.brand : Ds.c.divider),
                        ),
                        child: Text(v.label,
                            style: Ds.t.caption.copyWith(
                                color: v.selected ? Ds.c.surface : Ds.c.text)),
                      ),
                    ),
                ],
              ),
            ],
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
