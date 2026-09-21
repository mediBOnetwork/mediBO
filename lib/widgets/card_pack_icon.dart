import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// CMD #2146 — the no-photo artwork on Product card v5: a pack-type icon,
/// never the grey jar.
///
/// The KIND is the backend's (`card.placeholder.kind`, from
/// `card_placeholder_kind()` in Postgres); this widget only maps each kind it
/// knows to a glyph. An unknown or empty kind draws the carton — the design's
/// "Piece · Other" — so a new kind added in SQL still renders.
class CardPackIcon extends StatelessWidget {
  final String kind;
  final double size;

  const CardPackIcon({super.key, required this.kind, required this.size});

  static const Map<String, IconData> _glyphs = {
    'strip': Icons.medication_outlined,
    'bottle': Icons.medication_liquid_outlined,
    'vial': Icons.science_outlined,
    'syringe': Icons.vaccines_outlined,
    'tube': Icons.healing_outlined,
    'jar': Icons.kitchen_outlined,
    'sachet': Icons.local_mall_outlined,
    'drop': Icons.water_drop_outlined,
    'inhaler': Icons.air_rounded,
    'carton': Icons.inventory_2_outlined,
  };

  static IconData glyphFor(String kind) =>
      _glyphs[kind] ?? Icons.inventory_2_outlined;

  @override
  Widget build(BuildContext context) => Semantics(
        identifier: 'card_pack_icon',
        child: Icon(glyphFor(kind), size: size, color: Ds.c.brand),
      );
}
