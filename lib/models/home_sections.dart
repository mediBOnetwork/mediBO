import 'product.dart';

/// CHANGE #637 — the `storefront_home_v2(p_items)` payload.
///
/// The home feed is ONE RPC that returns an ordered list of sections, each
/// naming its own layout. The app renders them in the order given and decides
/// nothing: it does not sort, group, re-title, or choose which sections a
/// viewer sees. Adding a section, reordering the feed or retiring a rail is a
/// backend change with no deploy.
///
/// Forward-compatibility is the point of [HomeSectionLayout.unknown]: a layout
/// this build has never heard of is DROPPED here, at parse time, so the
/// renderer cannot accidentally half-render it. Same for a section that
/// arrives with no items. Both are silent — a future backend can ship a new
/// layout to old clients safely.
enum HomeSectionLayout { rail, iconGrid, brandGrid, unknown }

HomeSectionLayout _layoutOf(String raw) {
  switch (raw) {
    case 'rail':
      return HomeSectionLayout.rail;
    case 'icon_grid':
      return HomeSectionLayout.iconGrid;
    case 'brand_grid':
      return HomeSectionLayout.brandGrid;
    default:
      return HomeSectionLayout.unknown;
  }
}

/// Where a section's "See all" goes. Absent when the backend sent none — the
/// pill is then simply not rendered.
class SeeAll {
  final String type;
  final String key;
  const SeeAll({required this.type, required this.key});

  static SeeAll? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type']?.toString() ?? '';
    final key = raw['key']?.toString() ?? '';
    // A See-all with no destination is not a See-all.
    if (type.isEmpty || key.isEmpty) return null;
    return SeeAll(type: type, key: key);
  }
}

/// One tile in an icon_grid or brand_grid.
class HomeTile {
  final String label;
  final String countLabel;

  /// The value handed back to the app when tapped — a category name for
  /// icon_grid, a normalised company name for brand_grid. Empty means the
  /// backend gave no destination, and the tile is rendered non-tappable.
  final String key;

  const HomeTile({
    required this.label,
    required this.countLabel,
    required this.key,
  });

  bool get tappable => key.isNotEmpty;

  static HomeTile fromMap(Map<String, dynamic> m) => HomeTile(
        label: m['label']?.toString() ?? '',
        countLabel: m['count_label']?.toString() ?? '',
        key: m['key']?.toString() ?? '',
      );
}

class HomeSection {
  final String id;
  final HomeSectionLayout layout;
  final String title;

  /// The substring of [title] to paint in the brand colour. Empty means paint
  /// the whole title normally — the split is never guessed from word position.
  final String accentWord;
  final String subtitle;
  final SeeAll? seeAll;

  /// Populated for [HomeSectionLayout.rail]; empty otherwise.
  final List<Product> cards;

  /// Populated for the grid layouts; empty otherwise.
  final List<HomeTile> tiles;

  const HomeSection({
    required this.id,
    required this.layout,
    required this.title,
    required this.accentWord,
    required this.subtitle,
    required this.seeAll,
    required this.cards,
    required this.tiles,
  });

  bool get isEmpty => cards.isEmpty && tiles.isEmpty;

  /// Splits [title] around [accentWord] into (before, accent, after).
  ///
  /// Returns an empty accent when the word is absent or blank, so the header
  /// renders one plain title rather than inventing an emphasis.
  (String, String, String) get titleParts {
    if (accentWord.isEmpty) return (title, '', '');
    final i = title.indexOf(accentWord);
    if (i < 0) return (title, '', '');
    return (
      title.substring(0, i),
      title.substring(i, i + accentWord.length),
      title.substring(i + accentWord.length),
    );
  }

  static HomeSection? fromMap(Map<String, dynamic> m) {
    final layout = _layoutOf(m['layout']?.toString() ?? '');
    // Rule 1: a layout this build does not know is skipped, silently.
    if (layout == HomeSectionLayout.unknown) return null;

    final rawItems = (m['items'] as List?) ?? const [];
    // Rule 2: no items, no section.
    if (rawItems.isEmpty) return null;

    final maps = rawItems
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    if (maps.isEmpty) return null;

    final cards = layout == HomeSectionLayout.rail
        ? maps.map(Product.fromHomeCard).toList(growable: false)
        : const <Product>[];
    final tiles = layout == HomeSectionLayout.rail
        ? const <HomeTile>[]
        : maps.map(HomeTile.fromMap).toList(growable: false);

    final section = HomeSection(
      id: m['id']?.toString() ?? '',
      layout: layout,
      title: m['title']?.toString() ?? '',
      accentWord: m['accent_word']?.toString() ?? '',
      subtitle: m['subtitle']?.toString() ?? '',
      seeAll: SeeAll.fromMap(m['see_all']),
      cards: cards,
      tiles: tiles,
    );
    return section.isEmpty ? null : section;
  }
}

class HomeSections {
  final bool ok;
  final List<HomeSection> sections;

  const HomeSections({required this.ok, required this.sections});

  static const HomeSections failed =
      HomeSections(ok: false, sections: <HomeSection>[]);

  bool get isEmpty => sections.isEmpty;

  factory HomeSections.fromMap(Map<String, dynamic> m) {
    if (m['ok'] != true) return failed;
    final raw = (m['sections'] as List?) ?? const [];
    final parsed = raw
        .whereType<Map>()
        .map((e) => HomeSection.fromMap(Map<String, dynamic>.from(e)))
        .whereType<HomeSection>()
        .toList(growable: false);
    return HomeSections(ok: true, sections: parsed);
  }
}
