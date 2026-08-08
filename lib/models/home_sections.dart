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

/// CHANGE #673 — the dark header block at the top of the storefront.
///
/// Colours and the search placeholder are backend strings. Recolouring the
/// header, or rewording what the search box invites you to type, is an UPDATE
/// to `storefront_theme` / `storefront_ui_label` — not a deploy.
class HomeHeader {
  final String bgTop;
  final String bgBottom;
  final String fg;
  final String accent;
  final String searchHint;

  const HomeHeader({
    this.bgTop = '',
    this.bgBottom = '',
    this.fg = '',
    this.accent = '',
    this.searchHint = '',
  });

  static const HomeHeader none = HomeHeader();

  static HomeHeader fromMap(Object? raw) {
    if (raw is! Map) return none;
    return HomeHeader(
      bgTop: raw['bg_top']?.toString() ?? '',
      bgBottom: raw['bg_bottom']?.toString() ?? '',
      fg: raw['fg']?.toString() ?? '',
      accent: raw['accent']?.toString() ?? '',
      searchHint: raw['search_hint']?.toString() ?? '',
    );
  }
}

/// One trust prop under the hero, e.g. "75,814+ products".
///
/// [icon] is a backend NAME ("truck"), not a codepoint. The renderer maps a
/// known name to a glyph and falls back to no icon for one it does not know —
/// so the backend can ship a new prop to an old build without breaking it.
class HeroProp {
  final String icon;
  final String label;
  const HeroProp({required this.icon, required this.label});

  static HeroProp fromMap(Map<String, dynamic> m) => HeroProp(
        icon: m['icon']?.toString() ?? '',
        label: m['label']?.toString() ?? '',
      );
}

/// The hero banner. [show] is the backend's decision about whether the viewer
/// sees one at all — the app never infers it from "is the title empty".
class HomeHero {
  final bool show;
  final String eyebrow;
  final String title;
  final String cta;
  final String bgTop;
  final String bgBottom;
  final String accent;
  final List<HeroProp> props;

  const HomeHero({
    this.show = false,
    this.eyebrow = '',
    this.title = '',
    this.cta = '',
    this.bgTop = '',
    this.bgBottom = '',
    this.accent = '',
    this.props = const [],
  });

  static const HomeHero none = HomeHero();

  static HomeHero fromMap(Object? raw) {
    if (raw is! Map) return none;
    return HomeHero(
      show: raw['show'] == true,
      eyebrow: raw['eyebrow']?.toString() ?? '',
      title: raw['title']?.toString() ?? '',
      cta: raw['cta']?.toString() ?? '',
      bgTop: raw['bg_top']?.toString() ?? '',
      bgBottom: raw['bg_bottom']?.toString() ?? '',
      accent: raw['accent']?.toString() ?? '',
      props: ((raw['props'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => HeroProp.fromMap(Map<String, dynamic>.from(e)))
          .where((p) => p.label.isNotEmpty)
          .toList(growable: false),
    );
  }
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

  /// CHANGE #673 — the full-bleed background this section paints behind
  /// itself, as `#RRGGBB`. Empty means "no band, sit on the page background".
  /// Alternating bands are the single biggest reason the feed stopped reading
  /// as one undifferentiated white scroll, and which section gets which colour
  /// is a data decision, not a Dart one.
  final String band;

  /// The section's own accent, used for the accent word and the rule lines.
  /// Empty means fall back to the theme's brand colour.
  final String accent;

  /// CHANGE #673 — the See-all wording, e.g. "See all products". Empty means
  /// render no label; the app no longer holds a hardcoded 'See all'.
  final String seeAllLabel;

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
    this.band = '',
    this.accent = '',
    this.seeAllLabel = '',
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
      band: m['band']?.toString() ?? '',
      accent: m['accent']?.toString() ?? '',
      seeAllLabel: m['see_all_label']?.toString() ?? '',
    );
    return section.isEmpty ? null : section;
  }
}

class HomeSections {
  final bool ok;
  final List<HomeSection> sections;

  /// CHANGE #673 — the chrome that wraps the feed. Both default to their
  /// "nothing to paint" value rather than null, so no caller ever has to
  /// invent a fallback header or decide whether a hero exists.
  final HomeHeader header;
  final HomeHero hero;

  const HomeSections({
    required this.ok,
    required this.sections,
    this.header = HomeHeader.none,
    this.hero = HomeHero.none,
  });

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
    return HomeSections(
      ok: true,
      sections: parsed,
      header: HomeHeader.fromMap(m['header']),
      hero: HomeHero.fromMap(m['hero']),
    );
  }
}
