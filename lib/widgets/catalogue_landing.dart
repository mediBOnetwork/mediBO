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
import 'product_card_grid.dart';

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

/// CMD #2088 — the four Browse-by tiles: Company · Salt · Condition · Category.
///
/// Two across and two down, each one a rounded gradient card carrying a glyph
/// and exactly TWO lines: how many of that entity the viewer's zone can sell,
/// and how many products sit behind them. Both sentences, both numbers and
/// their Indian grouping are `catalogue_browse_tiles()`'s — this widget picks
/// no word and adds up nothing.
///
/// What is NOT here any more (CMD #2088): the four company letter discs, the
/// two sample salts, the two sample uses and the ANTI INFECTIVES chip. They
/// previewed the WHOLE catalogue under a count that is now about one zone, so
/// every one of them was an offer the zone could not keep.
///
/// The height is derived from the type tokens and the viewer's text scale, so
/// the 2×2 stays a grid at 320px and at any accessibility size, and each line
/// is given its own share of it — nothing inside can overflow the tile.
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
  static const int _perRow = 2;

  static double lineOf(BuildContext context, double size) =>
      MediaQuery.textScalerOf(context).scale(size) * Ds.t.lineHeight;

  /// Padding + glyph + gap + the two lines, each allowed to wrap to two rows
  /// so a long word never has to be cut on a 320px phone.
  static double tileHeight(BuildContext context) =>
      Ds.space.x16 * 2 +
      _glyphBox +
      Ds.space.x12 +
      lineOf(context, Ds.t.subtitleSize) * 2 +
      Ds.space.x4 +
      lineOf(context, Ds.t.captionSize) * 2;

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
    return Semantics(
      identifier: 'cat_tile_${d.key}',
      button: true,
      label: d.entityLabel,
      child: Material(
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
                  NavGlyph(
                      row: d.glyphRow, box: _glyphBox, glyph: _glyph, color: on),
                  SizedBox(height: Ds.space.x12),
                  // Line 1 — the entity and its zone count, printed whole.
                  SizedBox(
                    height: lineOf(context, Ds.t.subtitleSize) * 2,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text(d.entityLabel,
                          maxLines: 2,
                          style: Ds.t.subtitle.copyWith(color: on)),
                    ),
                  ),
                  SizedBox(height: Ds.space.x4),
                  // Line 2 — the products behind them.
                  SizedBox(
                    height: lineOf(context, Ds.t.captionSize) * 2,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text(d.productsLabel,
                          maxLines: 2,
                          style: Ds.t.caption
                              .copyWith(color: on.withValues(alpha: 0.86))),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
          // CMD #2167 — the shared rail: the catalogue's own card width, and
          // one height per row rather than one for the whole app.
          ProductCardRail(items: block.items, onOpen: onTap),
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
