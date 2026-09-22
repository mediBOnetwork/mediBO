import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

import '../design_tokens.dart';

/// CMD #2146 — the no-photo artwork on the product card: a pack-type icon,
/// never the grey jar.
///
/// CMD #2166 — and the artwork itself is the BACKEND's. `placeholder.icon_url`
/// (from `app_settings 'card.placeholder_icons'`) names a single-colour SVG and
/// `placeholder.fg` names its tint, so a new drawing or a new colour is one
/// UPDATE and a reload — never a deploy. The KIND still comes from
/// `card_placeholder_kind()` in Postgres.
///
/// The built-in glyph below is the FALLBACK and nothing else: it is drawn only
/// when the payload carried no url, or when that url failed to load. It wears
/// the same [color], so the card never falls back to an unrelated green. An
/// unknown or empty kind draws the carton — the design's "Piece · Other" — so
/// a kind added in SQL still renders.
class CardPackIcon extends StatelessWidget {
  final String kind;
  final double size;

  /// `placeholder.icon_url`, verbatim. Empty = the backend has no drawing for
  /// this kind, so the built-in glyph is used.
  final String iconUrl;

  /// The tint, already resolved from `placeholder.fg`. Null keeps the caller's
  /// own colour (the cart pill's brand circle), which has no placeholder block.
  final Color? color;

  const CardPackIcon({
    super.key,
    required this.kind,
    required this.size,
    this.iconUrl = '',
    this.color,
  });

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

  /// One fetch per url for the whole app, not one per card: a grid of 40 tiles
  /// shares ten drawings. A url that failed caches its failure too, so a dead
  /// entry in `card.placeholder_icons` costs one request, not forty.
  static final Map<String, Future<Uint8List?>> _bytes = {};

  /// The protected suite has no network, so it hands the fetch a client of its
  /// own. Null in every build that ships.
  @visibleForTesting
  static http.Client? httpClient;

  @visibleForTesting
  static void resetCache() => _bytes.clear();

  static Future<Uint8List?> _load(String url) =>
      _bytes.putIfAbsent(url, () async {
        try {
          final res = await (httpClient ?? http.Client()).get(Uri.parse(url));
          if (res.statusCode != 200) return null;
          final body = res.bodyBytes;
          // A 404 page, an error JSON or a truncated body is not a drawing.
          // Sniffing here keeps a bad url on the fallback instead of throwing
          // out of the SVG parser, where nothing can catch it.
          if (body.isEmpty || !String.fromCharCodes(
                  body.take(512)).contains('<svg')) {
            return null;
          }
          return body;
        } catch (_) {
          return null;
        }
      });

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Ds.c.brand;
    final glyph = Icon(glyphFor(kind), size: size, color: tint);
    if (iconUrl.isEmpty) {
      return Semantics(identifier: 'card_pack_icon', child: glyph);
    }
    return Semantics(
      identifier: 'card_pack_icon',
      child: FutureBuilder<Uint8List?>(
        future: _load(iconUrl),
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            // The box is reserved and empty while the bytes are in flight: the
            // glyph is a failure state, not a loading one, so the card never
            // flashes one drawing into another.
            return SizedBox(width: size, height: size);
          }
          final data = snap.data;
          if (data == null) return glyph;
          return SvgPicture.memory(
            data,
            width: size,
            height: size,
            colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
            placeholderBuilder: (_) => SizedBox(width: size, height: size),
            errorBuilder: (_, _, _) => glyph,
          );
        },
      ),
    );
  }
}
