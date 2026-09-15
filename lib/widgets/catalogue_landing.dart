// CMD #2020 — the Catalogue landing's own blocks.
//
// Four gradient tiles, a top-selling rail, a promo banner and the chip row
// under it. Every one of them is a PRINTER: the colours arrive as hex strings
// on the payload (app_settings.catalogue_landing), the preview rows were
// ranked and worded in SQL, the rail was ordered by the zone's own 30-day
// quantity and the banner exists only because the backend said `has`. Nothing
// here ranks, tints, shortens or writes a sentence.
//
// They live in their own file rather than inside catalogue_screen.dart so the
// screen stays the state machine it is and these stay four small widgets that
// can be rendered from a fixture in a test with no RPC at all.

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/catalogue.dart';
import '../models/product.dart';
import '../screens/admin/nav_registry_view.dart';
import 'compact_product_card.dart';

/// A payload colour. `#RRGGBB` or `#AARRGGBB`, and anything else is an absence
/// rather than a guess — the caller falls back to a token.
Color? catHex(String raw) {
  var s = raw.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 6) s = 'FF$s';
  if (s.length != 8) return null;
  final v = int.tryParse(s, radix: 16);
  return v == null ? null : Color(v);
}

/// CMD #2020 — the four Browse-by tiles: Company · Salt · Use · Category.
///
/// Two across and two down, each one a rounded gradient card with a large
/// glyph, its name, its count and the preview the backend attached to it. The
/// height is fixed for all four so the grid is a grid — and the count line is
/// allowed to wrap inside it rather than ellipsise, because a tile that hides
/// the number it exists to show is the truncation DESIGN.md forbids.
class CatalogueTiles extends StatelessWidget {
  final String title;
  final List<CatDoor> doors;
  final ValueChanged<CatDoor> onTap;

  const CatalogueTiles({
    super.key,
    required this.title,
    required this.doors,
    required this.onTap,
  });

  static const double _glyphBox = 40;
  static const double _glyph = 24;
  static const double _disc = 26;
  static const int _perRow = 2;

  /// The tile height, DERIVED from the type tokens and the viewer's own text
  /// scale rather than frozen at a number. Every tile in the grid is given
  /// exactly this height, so the 2×2 is a grid at any width and at any
  /// accessibility text size — and because each block inside the tile is given
  /// its own share of it, nothing inside can overflow it either.
  static double lineOf(BuildContext context, double size) =>
      MediaQuery.textScalerOf(context).scale(size) * Ds.t.lineHeight;

  static double previewHeight(BuildContext context) {
    final cap = lineOf(context, Ds.t.captionSize);
    return [_disc, cap * 2, cap + Ds.space.x8]
        .reduce((a, b) => a > b ? a : b);
  }

  static double tileHeight(BuildContext context) =>
      Ds.space.x16 * 2 +
      _glyphBox +
      Ds.space.x8 +
      lineOf(context, Ds.t.subtitleSize) +
      Ds.space.x4 +
      lineOf(context, Ds.t.captionSize) * 2 +
      Ds.space.x8 +
      previewHeight(context);

  @override
  Widget build(BuildContext context) {
    if (doors.isEmpty) return const SizedBox.shrink();
    final h = tileHeight(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x24, Ds.space.x16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) ...[
            Text(title, style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
          ],
          for (var r = 0; r * _perRow < doors.length; r++) ...[
            if (r > 0) SizedBox(height: Ds.space.x12),
            SizedBox(
              height: h,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = r * _perRow;
                      i < (r + 1) * _perRow && i < doors.length;
                      i++) ...[
                    if (i > r * _perRow) SizedBox(width: Ds.space.x12),
                    Expanded(child: _tile(context, doors[i])),
                  ],
                  // An odd last row keeps the grid: the missing tile is an
                  // empty half, never a stretched one.
                  if (doors.length - r * _perRow == 1) ...[
                    SizedBox(width: Ds.space.x12),
                    const Expanded(child: SizedBox.shrink()),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, CatDoor d) {
    final from = catHex(d.gradient.from) ?? Ds.c.brand;
    final to = catHex(d.gradient.to) ?? Ds.c.brand;
    final on = catHex(d.gradient.on) ?? Ds.c.surface;
    return Material(
      color: Colors.transparent,
      borderRadius: Ds.r.rCard,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: Ds.r.rCard,
          gradient: LinearGradient(
            colors: [from, to],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: InkWell(
          onTap: () => onTap(d),
          borderRadius: Ds.r.rCard,
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NavGlyph(row: d.glyphRow, box: _glyphBox, glyph: _glyph, color: on),
                SizedBox(height: Ds.space.x8),
                // The backend's words, printed whole. The name is scaled down
                // rather than cut when a tile is too narrow for it — an
                // ellipsis on a one-word title is the truncation DESIGN.md
                // forbids, and so is a count that hides its own number.
                SizedBox(
                  height: lineOf(context, Ds.t.subtitleSize),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(d.label, style: Ds.t.subtitle.copyWith(color: on)),
                    ),
                  ),
                ),
                SizedBox(height: Ds.space.x4),
                SizedBox(
                  height: lineOf(context, Ds.t.captionSize) * 2,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(d.countLabel,
                        maxLines: 2,
                        style:
                            Ds.t.caption.copyWith(color: on.withValues(alpha: 0.86))),
                  ),
                ),
                SizedBox(height: Ds.space.x8),
                SizedBox(
                  height: previewHeight(context),
                  child: _preview(context, d.preview, from, on),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 'logos' → letter discs · 'chips' → tinted pills · 'names' → plain lines.
  /// A kind this build cannot draw renders nothing, the same silence the home
  /// feed gives an unknown layout. Each shape SCROLLS rather than overflowing:
  /// a narrow phone shortens the preview, it never breaks the tile.
  Widget _preview(BuildContext context, CatPreview p, Color from, Color on) {
    if (p.isEmpty) return const SizedBox.shrink();
    switch (p.kind) {
      case 'logos':
        return ListView(
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          children: [
            for (final it in p.items)
              Container(
                width: _disc,
                height: _disc,
                margin: EdgeInsets.only(right: Ds.space.x4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: catHex(it.tone) ?? on,
                  shape: BoxShape.circle,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(it.letter, style: Ds.t.caption.copyWith(color: from)),
                ),
              ),
          ],
        );
      case 'chips':
        return ListView(
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          children: [
            for (final it in p.items)
              Container(
                margin: EdgeInsets.only(right: Ds.space.x4),
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x8, vertical: Ds.space.x4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: catHex(it.tone) ?? on,
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(it.label,
                    maxLines: 1, style: Ds.t.caption.copyWith(color: from)),
              ),
          ],
        );
      case 'names':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            for (final it in p.items)
              SizedBox(
                height: lineOf(context, Ds.t.captionSize),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(it.label,
                      maxLines: 1,
                      style: Ds.t.caption.copyWith(color: on.withValues(alpha: 0.86))),
                ),
              ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

/// CMD #2020 — the top-selling rail.
///
/// The card is [CompactProductCard], unchanged: the same storefront card the
/// home feed and the back-in-stock strip draw, so a shopper meets one product
/// card in this app and not three. Everything this widget adds is the title,
/// the backend's note about WHICH ranking this is, and the scroll.
class CatalogueTopSellingRail extends StatelessWidget {
  final CatTopSelling block;
  final ValueChanged<Product> onTap;

  const CatalogueTopSellingRail({
    super.key,
    required this.block,
    required this.onTap,
  });

  static const double _gutter = 16;
  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    if (block.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(Ds.space.x16, 0, Ds.space.x16, Ds.space.x8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(block.title, style: Ds.t.subtitle),
                if (block.note.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(block.note, style: Ds.t.caption),
                ],
              ],
            ),
          ),
          SizedBox(
            height: CompactProductCard.extent,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: _gutter),
              itemExtent: CompactProductCard.railWidth + _gap,
              itemCount: block.items.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(right: _gap),
                child: CompactProductCard(
                  product: block.items[i],
                  onTap: () => onTap(block.items[i]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// CMD #2020 — the Schemes banner: full width, its own gradient, a title, a
/// subtitle and an arrow. It is drawn only when the payload said `has`, so a
/// zone running no scheme at all gets no banner rather than an empty one.
class CataloguePromoBanner extends StatelessWidget {
  final CatPromo promo;
  final VoidCallback onTap;

  const CataloguePromoBanner({super.key, required this.promo, required this.onTap});

  static const double _arrow = 20;

  @override
  Widget build(BuildContext context) {
    if (!promo.has) return const SizedBox.shrink();
    final from = catHex(promo.gradient.from) ?? Ds.c.brand;
    final to = catHex(promo.gradient.to) ?? Ds.c.brand;
    final on = catHex(promo.gradient.on) ?? Ds.c.surface;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x24, Ds.space.x16, 0),
      child: Material(
        color: Colors.transparent,
        borderRadius: Ds.r.rCard,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: Ds.r.rCard,
            gradient: LinearGradient(
              colors: [from, to],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: Ds.r.rCard,
            child: Container(
              constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
              padding: EdgeInsets.all(Ds.space.x16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(promo.title,
                            style: Ds.t.subtitle.copyWith(color: on)),
                        if (promo.subtitle.isNotEmpty) ...[
                          SizedBox(height: Ds.space.x4),
                          Text(promo.subtitle,
                              style: Ds.t.caption
                                  .copyWith(color: on.withValues(alpha: 0.86))),
                        ],
                        if (promo.countLabel.isNotEmpty) ...[
                          SizedBox(height: Ds.space.x4),
                          Text(promo.countLabel,
                              style: Ds.t.caption
                                  .copyWith(color: on.withValues(alpha: 0.86))),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: Ds.space.x12),
                  Icon(Icons.arrow_forward, size: _arrow, color: on),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
