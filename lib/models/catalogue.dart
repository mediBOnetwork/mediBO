// CHANGE #747 — the Catalogue payloads, as models that decide nothing.
//
// Every field here is a value the backend already rendered: a label, a count
// sentence, a tone, an empty state, a cursor. There is no formatting, no
// pluralising, no sorting and no derivation in this file — a parser that
// computed anything would be the app deciding, and the whole catalogue is one
// place where that is easy to slip into (a count is *so* nearly arithmetic).
//
// Absence is carried explicitly rather than defaulted, the way #638 taught:
// `CatZone.has` false means "this viewer gets no zone switch", not "the switch
// is off", and the two must not collapse into one boolean.

import 'product.dart';

/// CMD #1909 — the remains of the "Available in my zone" control. The backend
/// now answers `has:false` for everyone, because catalogue lists no longer
/// filter by zone at all: they show the whole scope and GROUP it. The class
/// stays because the payload key stays, and because `has` is still the only
/// thing allowed to decide whether a control exists — reading it as "off"
/// would be the app inferring, which is what #638 forbade.
class CatZone {
  final bool has;
  final bool on;
  final String label;
  final String zoneLabel;
  final String note;

  const CatZone({
    required this.has,
    required this.on,
    required this.label,
    required this.zoneLabel,
    required this.note,
  });

  static CatZone fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatZone(
      has: m['has'] == true,
      on: m['on'] == true,
      label: (m['label'] ?? '').toString(),
      zoneLabel: (m['zone_label'] ?? '').toString(),
      note: (m['note'] ?? '').toString(),
    );
  }
}

/// One tab of the Catalogue. `kind` says which surface it opens — an unknown
/// kind is skipped in silence so the backend can ship a sixth tab before the
/// app that knows how to draw it, exactly as the home feed does with layouts.
class CatTab {
  final String key;
  final String label;
  final String kind;
  final String countLabel;
  final String listKind;
  final String listKey;
  final String emptyLabel;

  const CatTab({
    required this.key,
    required this.label,
    required this.kind,
    required this.countLabel,
    required this.listKind,
    required this.listKey,
    required this.emptyLabel,
  });

  static CatTab fromMap(Map<String, dynamic> m) => CatTab(
        key: (m['key'] ?? '').toString(),
        label: (m['label'] ?? '').toString(),
        kind: (m['kind'] ?? '').toString(),
        countLabel: (m['count_label'] ?? '').toString(),
        listKind: (m['list_kind'] ?? '').toString(),
        listKey: (m['list_key'] ?? '').toString(),
        emptyLabel: (m['empty_label'] ?? '').toString(),
      );
}

/// One filter option inside a group.
class CatFilterOption {
  final String key;
  final String label;
  final bool selected;
  const CatFilterOption({required this.key, required this.label, required this.selected});
}

/// A filter group: `multi` (chips that add up) or `single` (one of).
class CatFilterGroup {
  final String key;
  final String label;
  final String mode;
  final List<CatFilterOption> options;
  const CatFilterGroup({
    required this.key,
    required this.label,
    required this.mode,
    required this.options,
  });
  bool get isMulti => mode == 'multi';
}

/// The whole filter + sort vocabulary for a list, as the backend defines it.
class CatFilters {
  final String title;
  final String clearLabel;
  final String applyLabel;
  final List<CatFilterGroup> groups;
  final String sortLabel;
  final List<CatFilterOption> sortOptions;

  const CatFilters({
    required this.title,
    required this.clearLabel,
    required this.applyLabel,
    required this.groups,
    required this.sortLabel,
    required this.sortOptions,
  });

  static const CatFilters empty = CatFilters(
    title: '', clearLabel: '', applyLabel: '', groups: [],
    sortLabel: '', sortOptions: [],
  );

  static CatFilters fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    final sort = m['sort'] is Map ? Map<String, dynamic>.from(m['sort'] as Map) : const {};
    return CatFilters(
      title: (m['title'] ?? '').toString(),
      clearLabel: (m['clear_label'] ?? '').toString(),
      applyLabel: (m['apply_label'] ?? '').toString(),
      groups: ((m['groups'] as List?) ?? const [])
          .whereType<Map>()
          .map((g) => CatFilterGroup(
                key: (g['key'] ?? '').toString(),
                label: (g['label'] ?? '').toString(),
                mode: (g['mode'] ?? 'multi').toString(),
                options: ((g['options'] as List?) ?? const [])
                    .whereType<Map>()
                    .map((o) => CatFilterOption(
                          key: (o['key'] ?? '').toString(),
                          label: (o['label'] ?? '').toString(),
                          selected: o['selected'] == true,
                        ))
                    .toList(growable: false),
              ))
          .toList(growable: false),
      sortLabel: (sort['label'] ?? '').toString(),
      sortOptions: ((sort['options'] as List?) ?? const [])
          .whereType<Map>()
          .map((o) => CatFilterOption(
                key: (o['key'] ?? '').toString(),
                label: (o['label'] ?? '').toString(),
                selected: false,
              ))
          .toList(growable: false),
    );
  }
}

/// `catalogue_home()` — the landing payload.
class CatHome {
  final bool ok;
  final String title;
  final String subtitle;
  final String searchHint;
  final CatZone zone;
  final List<CatTab> tabs;
  final CatFilters filters;

  // CHANGE #799 — the visual system's own blocks.
  final String searchPlaceholder;
  final String searchClearLabel;
  final String doorsTitle;
  final List<CatDoor> doors;
  final bool hasRecentViewed;
  final String recentViewedTitle;
  final List<Product> recentViewed;

  /// CMD #2011 — the landing's own breadcrumb, so the one header under the
  /// search bar is a payload rather than a word written here. CMD #2020 sends
  /// it EMPTY on the landing: the crumb appears once a tile is tapped and goes
  /// again on the way back, and that is the backend's decision, not a guard.
  final CatTrail trail;

  /// CMD #2020 — the top-selling rail under the tiles.
  final CatTopSelling topSelling;

  /// CMD #2020 — the full-width Schemes banner, absent at zero products.
  final CatPromo promo;

  /// CMD #2020 — the chip row under the banner (Cold chain). Two payload
  /// strings per chip, exactly as the tab strip carried them.
  final List<CatTab> chips;

  /// CMD #2011 — what the default landing shows, decided by the backend
  /// (app_settings.catalogue_landing). The four Browse-by tiles are the
  /// landing; the class tree moved behind the Category tile, which is why
  /// [showTree] is false. Nothing here is a style — they are the backend's
  /// answer to "is this block part of the landing at all".
  final bool showRecent;
  final bool showTabs;
  final bool showTree;

  const CatHome({
    required this.ok,
    required this.title,
    required this.subtitle,
    required this.searchHint,
    required this.zone,
    required this.tabs,
    required this.filters,
    required this.searchPlaceholder,
    required this.searchClearLabel,
    required this.doorsTitle,
    required this.doors,
    required this.hasRecentViewed,
    required this.recentViewedTitle,
    required this.recentViewed,
    this.trail = CatTrail.empty,
    this.topSelling = CatTopSelling.none,
    this.promo = CatPromo.none,
    this.chips = const [],
    this.showRecent = true,
    this.showTabs = true,
    this.showTree = false,
  });

  static CatHome fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    final search =
        m['search'] is Map ? Map<String, dynamic>.from(m['search'] as Map) : const {};
    final recent = m['recent_viewed'] is Map
        ? Map<String, dynamic>.from(m['recent_viewed'] as Map)
        : const {};
    return CatHome(
      ok: m['ok'] == true,
      title: (m['title'] ?? '').toString(),
      subtitle: (m['subtitle'] ?? '').toString(),
      searchHint: (m['search_hint'] ?? '').toString(),
      zone: CatZone.fromMap(m['zone']),
      tabs: ((m['tabs'] as List?) ?? const [])
          .whereType<Map>()
          .map((t) => CatTab.fromMap(Map<String, dynamic>.from(t)))
          .toList(growable: false),
      filters: CatFilters.fromMap(m['filters']),
      searchPlaceholder: (search['placeholder'] ?? m['search_hint'] ?? '').toString(),
      searchClearLabel: (search['clear_label'] ?? '').toString(),
      doorsTitle: (m['doors_title'] ?? '').toString(),
      doors: ((m['doors'] as List?) ?? const [])
          .whereType<Map>()
          .map((d) => CatDoor.fromMap(Map<String, dynamic>.from(d)))
          .toList(growable: false),
      hasRecentViewed: recent['has'] == true,
      recentViewedTitle: (recent['title'] ?? '').toString(),
      recentViewed: ((recent['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((i) => Product.fromHomeCard(Map<String, dynamic>.from(i)))
          .toList(growable: false),
      trail: CatTrail.fromMap(m['trail']),
      topSelling: CatTopSelling.fromMap(m['top_selling']),
      promo: CatPromo.fromMap(m['promo']),
      chips: ((m['chips'] as List?) ?? const [])
          .whereType<Map>()
          .map((t) => CatTab.fromMap(Map<String, dynamic>.from(t)))
          .toList(growable: false),
      showRecent: _landing(m)['show_recent'] != false,
      showTabs: _landing(m)['show_tabs'] != false,
      showTree: _landing(m)['show_tree'] == true,
    );
  }

  static Map<String, dynamic> _landing(Map<String, dynamic> m) =>
      m['landing'] is Map ? Map<String, dynamic>.from(m['landing'] as Map) : const {};
}

/// One row of any browse list: a class, a company or a salt. `key` is what the
/// next call is made with; `label` and `countLabel` are what the row prints.
class CatRow {
  final String key;
  final String label;
  final String countLabel;
  final String letter;
  const CatRow({
    required this.key,
    required this.label,
    required this.countLabel,
    required this.letter,
  });

  static CatRow fromMap(Map<String, dynamic> m) => CatRow(
        key: (m['key'] ?? '').toString(),
        label: (m['label'] ?? '').toString(),
        countLabel: (m['count_label'] ?? '').toString(),
        letter: (m['letter'] ?? '').toString(),
      );
}

/// `catalogue_tree()`, `catalogue_companies()` and `catalogue_salts()` all
/// answer in this shape: a titled page of [CatRow]s with its own empty state
/// and its own paging verdict. One model, because they are one screen.
class CatBrowse {
  final bool ok;
  final String title;
  final String countLabel;
  final String emptyLabel;
  final String moreLabel;
  final String searchHint;
  final String leadLabel;
  final CatZone zone;
  final List<CatRow> rows;
  final List<String> crumbs;
  final String homeLabel;
  final List<CatRow> letters;
  final String allLabel;

  /// CHANGE #799 — the fixed A–Z track. CMD #1908 draws it as a horizontal
  /// strip under the breadcrumb, and companies, salts and classes all send one.
  final CatRail rail;

  /// CMD #1908 — the breadcrumb, worded and routed by the backend.
  final CatTrail trail;

  /// The letter currently applied, or '' for the whole list.
  final String letter;

  /// 'level' → the next tap opens another level; 'products' → it opens the grid.
  final String childOpens;
  final String productsLabel;
  final bool hasProducts;

  final bool hasMore;
  final int nextOffset;

  const CatBrowse({
    required this.ok,
    required this.title,
    required this.countLabel,
    required this.emptyLabel,
    required this.moreLabel,
    required this.searchHint,
    required this.leadLabel,
    required this.zone,
    required this.rows,
    required this.crumbs,
    required this.homeLabel,
    required this.letters,
    required this.allLabel,
    required this.rail,
    required this.trail,
    required this.letter,
    required this.childOpens,
    required this.productsLabel,
    required this.hasProducts,
    required this.hasMore,
    required this.nextOffset,
  });

  static CatBrowse fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatBrowse(
      ok: m['ok'] == true,
      title: (m['title'] ?? '').toString(),
      countLabel: (m['count_label'] ?? '').toString(),
      emptyLabel: (m['empty_label'] ?? '').toString(),
      moreLabel: (m['more_label'] ?? '').toString(),
      searchHint: (m['search_hint'] ?? '').toString(),
      leadLabel: (m['lead_label'] ?? '').toString(),
      zone: CatZone.fromMap(m['zone']),
      rows: ((m['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => CatRow.fromMap(Map<String, dynamic>.from(r)))
          .toList(growable: false),
      crumbs: ((m['crumbs'] as List?) ?? const [])
          .whereType<Map>()
          .map((c) => (c['label'] ?? '').toString())
          .toList(growable: false),
      homeLabel: (m['home_label'] ?? '').toString(),
      letters: ((m['letters'] as List?) ?? const [])
          .whereType<Map>()
          .map((l) => CatRow(
                key: (l['key'] ?? '').toString(),
                label: (l['label'] ?? '').toString(),
                countLabel: '',
                letter: (l['key'] ?? '').toString(),
              ))
          .toList(growable: false),
      allLabel: (m['all_label'] ?? '').toString(),
      rail: CatRail.fromMap(m['rail']),
      trail: CatTrail.fromMap(m['trail']),
      letter: (m['letter'] ?? '').toString(),
      childOpens: (m['child_opens'] ?? '').toString(),
      productsLabel: (m['products_label'] ?? '').toString(),
      hasProducts: m['has_products'] == true,
      hasMore: m['has_more'] == true,
      nextOffset: (m['next_offset'] as num?)?.toInt() ?? 0,
    );
  }
}

/// CMD #1909 — one of the two availability groups a catalogue list is ordered
/// into. [label] already carries its count ("Available in your zone (5)") and
/// is printed exactly as it arrived; [count] is here for nothing but tests and
/// is never re-rendered into a label by the app.
class CatGroup {
  final String key;
  final String label;
  final int? count;

  const CatGroup({required this.key, required this.label, required this.count});

  static CatGroup fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatGroup(
      key: (m['key'] ?? '').toString(),
      label: (m['label'] ?? '').toString(),
      count: m['count'] is num ? (m['count'] as num).toInt() : null,
    );
  }
}

/// One row of a catalogue PRODUCT list: the card, plus the divider the BACKEND
/// asked to be drawn above it. (Not [CatRow] — that is a browse row, a company
/// or a salt on the way to a list like this one.)
///
/// The divider travels on the row that OPENS a group rather than as a separate
/// list the app has to interleave. That is what makes paging safe: page two of
/// the same group arrives with every [dividerLabel] empty, so a header is
/// never repeated and never lost, and the app never compares one page's last
/// item with the next page's first to work out where a group changed.
class CatListRow {
  final String dividerLabel;

  /// 'in' | 'out', or '' when the list is not grouped at all (anonymous
  /// viewers, and any viewer whose zone has no counts built yet).
  final String group;

  final Product product;

  const CatListRow({
    required this.dividerLabel,
    required this.group,
    required this.product,
  });

  static CatListRow fromMap(Map<String, dynamic> m) => CatListRow(
        dividerLabel: (m['divider_label'] ?? '').toString(),
        group: (m['group'] ?? '').toString(),
        product: Product.fromHomeCard(m),
      );
}

/// `catalogue_list()` — one page of products for any scope.
///
/// [nextCursor] is OPAQUE. It is the backend's keyset position, handed straight
/// back on the next call; the app never reads inside it and never builds one.
class CatList {
  final bool ok;
  final String title;
  final String subtitle;
  final String countLabel;
  final String emptyLabel;
  final String moreLabel;
  final String endLabel;
  final String sort;
  final bool filtersActive;
  final String filtersActiveLabel;
  final CatZone zone;
  final CatFilters filters;

  /// CHANGE #799 — the empty state that names the scope and offers a way out
  /// of it.
  final CatEmptyState empty;

  /// CMD #1908 — the breadcrumb for this scope.
  final CatTrail trail;

  /// CMD #2020 — the A–Z strip a PRODUCT list gets, exactly the one companies
  /// and salts already draw. Empty on a search: what narrowed it was the word
  /// that was typed.
  final CatRail rail;

  /// The letter currently applied, or '' for the whole scope.
  final String letter;

  /// CMD #1909 — true when the backend split this list into the two zone
  /// groups. False is not "no zone": it is "this list is one flat run", which
  /// is what an anonymous visitor gets.
  final bool grouped;

  /// The two groups, in the order they appear. Empty when [grouped] is false.
  final List<CatGroup> groups;

  final List<CatListRow> rows;
  final bool hasMore;
  final String? nextCursor;

  const CatList({
    required this.ok,
    required this.title,
    required this.subtitle,
    required this.countLabel,
    required this.emptyLabel,
    required this.moreLabel,
    required this.endLabel,
    required this.sort,
    required this.filtersActive,
    required this.filtersActiveLabel,
    required this.zone,
    required this.filters,
    required this.empty,
    required this.trail,
    this.rail = CatRail.empty,
    this.letter = '',
    required this.grouped,
    required this.groups,
    required this.rows,
    required this.hasMore,
    required this.nextCursor,
  });

  static CatList fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatList(
      ok: m['ok'] == true,
      title: (m['title'] ?? '').toString(),
      subtitle: (m['subtitle'] ?? '').toString(),
      countLabel: (m['count_label'] ?? '').toString(),
      emptyLabel: (m['empty_label'] ?? '').toString(),
      moreLabel: (m['more_label'] ?? '').toString(),
      endLabel: (m['end_label'] ?? '').toString(),
      sort: (m['sort'] ?? 'name').toString(),
      filtersActive: m['filters_active'] == true,
      filtersActiveLabel: (m['filters_active_label'] ?? '').toString(),
      zone: CatZone.fromMap(m['zone']),
      filters: CatFilters.fromMap(m['filters']),
      empty: CatEmptyState.fromMap(m['empty'],
          fallbackLabel: (m['empty_label'] ?? '').toString()),
      trail: CatTrail.fromMap(m['trail']),
      rail: CatRail.fromMap(m['rail']),
      letter: (m['letter'] ?? '').toString(),
      grouped: m['grouped'] == true,
      groups: ((m['groups'] as List?) ?? const [])
          .map(CatGroup.fromMap)
          .toList(growable: false),
      rows: ((m['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((i) => CatListRow.fromMap(Map<String, dynamic>.from(i)))
          .toList(growable: false),
      hasMore: m['has_more'] == true,
      nextCursor: (m['next_cursor'] as String?),
    );
  }
}

/// The filter selection the app holds and hands back. It is a bag of the
/// backend's own option keys — this class knows what a key IS, never what it
/// MEANS, and it is the one thing the catalogue serialises into the URL.
class CatFilterState {
  final Set<String> packTypes;
  final String? rx;
  final Set<String> flags;

  const CatFilterState({
    this.packTypes = const {},
    this.rx,
    this.flags = const {},
  });

  bool get isEmpty => packTypes.isEmpty && rx == null && flags.isEmpty;

  bool isOn(String group, String key) => switch (group) {
        'pack_type' => packTypes.contains(key),
        'rx' => rx == key,
        _ => flags.contains(key),
      };

  CatFilterState toggle(String group, String key, {required bool single}) {
    if (single) {
      return CatFilterState(
        packTypes: packTypes, flags: flags, rx: rx == key ? null : key);
    }
    if (group == 'pack_type') {
      final s = {...packTypes};
      s.contains(key) ? s.remove(key) : s.add(key);
      return CatFilterState(packTypes: s, rx: rx, flags: flags);
    }
    final s = {...flags};
    s.contains(key) ? s.remove(key) : s.add(key);
    return CatFilterState(packTypes: packTypes, rx: rx, flags: s);
  }

  /// The `p_filters` argument. Only what is actually set is sent: an absent key
  /// and a false one mean different things to the backend's WHERE builder.
  Map<String, dynamic> toRpc() => {
        if (packTypes.isNotEmpty) 'pack_type': packTypes.toList()..sort(),
        if (rx != null) 'rx': rx,
        for (final f in flags) f: 'true',
      };

  /// The deep-link form: `pt=Strip,Vial|rx=Rx|f=cold_chain,has_image`.
  String toQuery() {
    final parts = <String>[];
    if (packTypes.isNotEmpty) parts.add('pt=${(packTypes.toList()..sort()).join(',')}');
    if (rx != null) parts.add('rx=$rx');
    if (flags.isNotEmpty) parts.add('f=${(flags.toList()..sort()).join(',')}');
    return parts.join('&');
  }

  static CatFilterState fromQuery(Map<String, String> q) {
    Set<String> split(String? v) => (v == null || v.isEmpty)
        ? <String>{}
        : v.split(',').where((s) => s.isNotEmpty).toSet();
    final rx = q['rx'];
    return CatFilterState(
      packTypes: split(q['pt']),
      rx: (rx == 'Rx' || rx == 'OTC') ? rx : null,
      flags: split(q['f']),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CHANGE #799 — the visual system's payloads.
//
// Same rule as everything above: these classes carry, they never decide. A
// door's letter, a chip's word, the separator between chips, the sentence an
// empty scope prints and the label on a pack variant are all backend strings.
// ═══════════════════════════════════════════════════════════════════════════

/// One of the three entry doors under the search bar: Company · Salt ·
/// Category. `iconKey`/`iconLetter` follow the nav-registry convention (#349)
/// — a key this build can draw wins, the letter is the honest fallback, and
/// neither is chosen here.
class CatDoor {
  final String key;
  final String kind;
  final String tab;
  final String label;
  final String iconKey;
  final String iconLetter;
  final String countLabel;

  /// CMD #2020 — the tile's own two-stop gradient and the colour its words are
  /// printed in. Absent means the flat surface tile: a payload from before this
  /// change draws exactly what it drew before.
  final CatGradient gradient;

  /// CMD #2020 — the four logos / three chips / two names under the title. The
  /// backend ranked them and worded them; [CatPreview.kind] says which of the
  /// three shapes to draw, and an unknown kind draws nothing rather than
  /// guessing.
  final CatPreview preview;

  const CatDoor({
    required this.key,
    required this.kind,
    required this.tab,
    required this.label,
    required this.iconKey,
    required this.iconLetter,
    required this.countLabel,
    this.gradient = CatGradient.none,
    this.preview = CatPreview.none,
  });

  static CatDoor fromMap(Map<String, dynamic> m) => CatDoor(
        key: (m['key'] ?? '').toString(),
        kind: (m['kind'] ?? '').toString(),
        tab: (m['tab'] ?? m['key'] ?? '').toString(),
        label: (m['label'] ?? '').toString(),
        iconKey: (m['icon_key'] ?? '').toString(),
        iconLetter: (m['icon_letter'] ?? '').toString(),
        countLabel: (m['count_label'] ?? '').toString(),
        gradient: CatGradient.fromMap(m['gradient']),
        preview: CatPreview.fromMap(m['preview']),
      );

  /// The map [NavGlyph] reads. Handing it the payload's own keys keeps the
  /// glyph rule in ONE place for the whole app.
  Map<String, dynamic> get glyphRow =>
      {'icon_key': iconKey, 'icon_letter': iconLetter, 'label': label};
}

/// One action offered by an empty scope. `has` false draws nothing — an empty
/// state with a dead button teaches worse than one with no button at all.
class CatEmptyAction {
  final bool has;
  final String kind;
  final String label;

  /// CMD #1905 — 'primary' | 'secondary', the backend's own word for how
  /// loudly this way out should be offered. It is never inferred from the
  /// kind: when filters are on, Clear is the primary and Request the quiet
  /// one, and only the payload knows that.
  final String tone;

  const CatEmptyAction({
    required this.has,
    required this.kind,
    required this.label,
    this.tone = 'primary',
  });

  static CatEmptyAction fromMap(Object? raw, {String tone = 'primary'}) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatEmptyAction(
      has: m['has'] == true,
      kind: (m['kind'] ?? '').toString(),
      label: (m['label'] ?? '').toString(),
      tone: (m['tone'] ?? tone).toString(),
    );
  }
}

/// "No Cold chain in Raipur yet." plus the two ways out of it.
class CatEmptyState {
  final String label;
  final String hint;
  final CatEmptyAction action;
  final CatEmptyAction clear;

  /// CMD #1905 — the ways out IN THE ORDER THEY ARE DRAWN. "Clear filters"
  /// comes first when filters are on, because the shopper's own filter is the
  /// likelier reason the scope is blank; the screen does not re-decide that.
  /// A payload from before this change carries no `buttons`, so the list is
  /// rebuilt as `action` then `clear` — exactly the order that payload was
  /// drawn in. A compat shim reproduces the old behaviour; it never invents
  /// the new one on a payload that did not ask for it.
  final List<CatEmptyAction> buttons;

  const CatEmptyState({
    required this.label,
    required this.hint,
    required this.action,
    required this.clear,
    this.buttons = const [],
  });

  static const CatEmptyState none = CatEmptyState(
    label: '', hint: '',
    action: CatEmptyAction(has: false, kind: '', label: ''),
    clear: CatEmptyAction(has: false, kind: '', label: ''),
  );

  static CatEmptyState fromMap(Object? raw, {String fallbackLabel = ''}) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    final label = (m['label'] ?? '').toString();
    final action = CatEmptyAction.fromMap(m['action']);
    final clear = CatEmptyAction.fromMap(m['clear'], tone: 'secondary');
    final sent = (m['buttons'] as List<dynamic>?)
        ?.whereType<Map>()
        .map((e) => CatEmptyAction.fromMap(
            {...Map<String, dynamic>.from(e), 'has': true}))
        .where((b) => b.label.isNotEmpty)
        .toList(growable: false);
    return CatEmptyState(
      label: label.isEmpty ? fallbackLabel : label,
      hint: (m['hint'] ?? '').toString(),
      action: action,
      clear: clear,
      buttons: sent ??
          [
            if (action.has) action,
            if (clear.has) clear,
          ],
    );
  }
}

/// One letter of the drag-to-jump rail. The track is EVERY letter, always —
/// `enabled` says whether anything sits behind it. A rail that changes length
/// is a rail nobody can learn the shape of.
class CatRailLetter {
  final String key;
  final String label;
  final bool enabled;
  const CatRailLetter({required this.key, required this.label, required this.enabled});
}

class CatRail {
  final String label;
  final String allLabel;
  final List<CatRailLetter> letters;
  const CatRail({required this.label, required this.allLabel, required this.letters});

  static const CatRail empty = CatRail(label: '', allLabel: '', letters: []);
  bool get isEmpty => letters.isEmpty;

  static CatRail fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatRail(
      label: (m['label'] ?? '').toString(),
      allLabel: (m['all_label'] ?? '').toString(),
      letters: ((m['letters'] as List?) ?? const [])
          .whereType<Map>()
          .map((l) => CatRailLetter(
                key: (l['key'] ?? '').toString(),
                label: (l['label'] ?? '').toString(),
                enabled: l['enabled'] == true,
              ))
          .toList(growable: false),
    );
  }
}

/// One pack of a brand family — "250mg DT Tablet", "JR Oral Suspension".
class CatVariant {
  final String productId;
  final String label;
  final bool selected;
  const CatVariant({required this.productId, required this.label, required this.selected});
}

/// `catalogue_variants(ids)` — asked for AFTER a page of cards has painted, so
/// the grid never waits on it. An id that is not in the map simply has no
/// chips; that is an absence, not a failure.
class CatVariantMap {
  final String title;
  final Map<String, List<CatVariant>> byId;

  const CatVariantMap({required this.title, required this.byId});
  static const CatVariantMap empty = CatVariantMap(title: '', byId: {});

  List<CatVariant> of(String productId) => byId[productId] ?? const <CatVariant>[];

  CatVariantMap merge(CatVariantMap other) => CatVariantMap(
        title: other.title.isNotEmpty ? other.title : title,
        byId: {...byId, ...other.byId},
      );

  static CatVariantMap fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    final map = m['map'] is Map ? Map<String, dynamic>.from(m['map'] as Map) : const {};
    final out = <String, List<CatVariant>>{};
    map.forEach((id, blk) {
      if (blk is! Map) return;
      // `has` is the BACKEND's verdict on whether this pack has siblings worth
      // showing. A one-pack family arrives has:false and draws no chip row.
      if (blk['has'] != true) return;
      out[id] = ((blk['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((v) => CatVariant(
                productId: (v['product_id'] ?? '').toString(),
                label: (v['label'] ?? '').toString(),
                selected: v['selected'] == true,
              ))
          .where((v) => v.label.isNotEmpty)
          .toList(growable: false);
    });
    return CatVariantMap(title: (m['title'] ?? '').toString(), byId: out);
  }
}

/// CMD #1908 — one step of the breadcrumb.
///
/// The label is a word the backend chose, and [route] is the FOUR values the
/// catalogue's route is made of, sent as data. Tapping a crumb is "copy this
/// object into the route" — the app never works out where "Company" goes, and
/// it never joins "Catalogue" to anything.
class CatCrumb {
  final String label;
  final bool current;
  final String tab;
  final List<String> path;
  final String? listKind;
  final String? listKey;

  const CatCrumb({
    required this.label,
    required this.current,
    required this.tab,
    required this.path,
    required this.listKind,
    required this.listKey,
  });

  static CatCrumb fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    final r = m['route'] is Map
        ? Map<String, dynamic>.from(m['route'] as Map)
        : const <String, dynamic>{};
    return CatCrumb(
      label: (m['label'] ?? '').toString(),
      current: m['current'] == true,
      tab: (r['tab'] ?? 'browse').toString(),
      path: ((r['path'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      listKind: r['list_kind']?.toString(),
      listKey: r['list_key']?.toString(),
    );
  }
}

/// The trail every catalogue payload carries. Empty means "the backend sent
/// none" — never "this screen decided there is nothing to show".
class CatTrail {
  final String label;
  final String separator;
  final List<CatCrumb> items;
  const CatTrail({required this.label, required this.separator, required this.items});

  static const CatTrail empty = CatTrail(label: '', separator: '', items: []);
  bool get isEmpty => items.isEmpty;

  static CatTrail fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatTrail(
      label: (m['label'] ?? '').toString(),
      separator: (m['separator'] ?? '').toString(),
      items: ((m['items'] as List?) ?? const [])
          .whereType<Map>()
          .map(CatCrumb.fromMap)
          .toList(growable: false),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════════════
// CMD #2020 — the landing's own payloads.
//
// A gradient, a preview row, a rail of top sellers and a promo banner. Every
// one of them is a value the backend sent: the colours come from
// app_settings.catalogue_landing, the preview rows are the facet table's own
// top rows, the rail is ranked in SQL and the banner's `has` is the backend's
// verdict on whether this zone has a single scheme running. Nothing in this
// file ranks, words, shortens or tints anything.
// ═══════════════════════════════════════════════════════════════════════════

/// A two-stop gradient plus the colour its content is printed in, as the three
/// hex strings the payload carries. [has] false is "this payload sent none" —
/// never "draw it grey".
class CatGradient {
  final String from;
  final String to;
  final String on;

  const CatGradient({required this.from, required this.to, required this.on});
  static const CatGradient none = CatGradient(from: '', to: '', on: '');

  bool get has => from.isNotEmpty && to.isNotEmpty;

  static CatGradient fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatGradient(
      from: (m['from'] ?? '').toString(),
      to: (m['to'] ?? '').toString(),
      on: (m['on'] ?? '').toString(),
    );
  }
}

/// One item of a tile preview: a company, a class, a salt or a use. It carries
/// its label, the letter the backend derived for a logo disc, a tint and its
/// own count sentence — four strings, no arithmetic.
class CatPreviewItem {
  final String key;
  final String label;
  final String letter;
  final String tone;
  final String countLabel;

  const CatPreviewItem({
    required this.key,
    required this.label,
    required this.letter,
    required this.tone,
    required this.countLabel,
  });

  static CatPreviewItem fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatPreviewItem(
      key: (m['key'] ?? '').toString(),
      label: (m['label'] ?? '').toString(),
      letter: (m['letter'] ?? '').toString(),
      tone: (m['tone'] ?? '').toString(),
      countLabel: (m['count_label'] ?? '').toString(),
    );
  }
}

/// The preview block under a tile's title. [kind] is 'logos' | 'chips' |
/// 'names'; a kind this build cannot draw is skipped in silence, the same
/// forward-compatibility the home feed gives an unknown layout.
class CatPreview {
  final String kind;
  final bool has;
  final List<CatPreviewItem> items;

  const CatPreview({required this.kind, required this.has, required this.items});
  static const CatPreview none = CatPreview(kind: '', has: false, items: []);

  bool get isEmpty => !has || items.isEmpty;

  static CatPreview fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatPreview(
      kind: (m['kind'] ?? '').toString(),
      has: m['has'] == true,
      items: ((m['items'] as List?) ?? const [])
          .map(CatPreviewItem.fromMap)
          .where((i) => i.label.isNotEmpty)
          .toList(growable: false),
    );
  }
}

/// `catalogue_home().top_selling` — the horizontal rail under the tiles.
///
/// [note] is the backend saying WHICH ranking the shopper is looking at: the
/// zone's own 30-day order quantity, or — when the zone has no history yet —
/// simply what is available in it. The app never picks between the two and
/// never writes that sentence.
class CatTopSelling {
  final bool has;
  final String title;
  final String note;
  final List<Product> items;

  const CatTopSelling({
    required this.has,
    required this.title,
    required this.note,
    required this.items,
  });

  static const CatTopSelling none =
      CatTopSelling(has: false, title: '', note: '', items: []);

  bool get isEmpty => !has || items.isEmpty;

  static CatTopSelling fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatTopSelling(
      has: m['has'] == true,
      title: (m['title'] ?? '').toString(),
      note: (m['note'] ?? '').toString(),
      items: ((m['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((i) => Product.fromHomeCard(Map<String, dynamic>.from(i)))
          .toList(growable: false),
    );
  }
}

/// `catalogue_home().promo` — the full-width banner that opens a list.
///
/// [has] is the whole visibility rule: a zone running no scheme sends has:false
/// and the banner is not drawn. It carries the route it opens as data
/// ([listKind] / [listKey]), so tapping it is "copy this into the route" and
/// the app never works out where Schemes lives.
class CatPromo {
  final bool has;
  final String key;
  final String listKind;
  final String listKey;
  final String title;
  final String subtitle;
  final String countLabel;
  final String actionLabel;
  final CatGradient gradient;

  const CatPromo({
    required this.has,
    required this.key,
    required this.listKind,
    required this.listKey,
    required this.title,
    required this.subtitle,
    required this.countLabel,
    required this.actionLabel,
    required this.gradient,
  });

  static const CatPromo none = CatPromo(
    has: false, key: '', listKind: '', listKey: '', title: '', subtitle: '',
    countLabel: '', actionLabel: '', gradient: CatGradient.none,
  );

  static CatPromo fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return CatPromo(
      has: m['has'] == true,
      key: (m['key'] ?? '').toString(),
      listKind: (m['list_kind'] ?? '').toString(),
      listKey: (m['list_key'] ?? '').toString(),
      title: (m['title'] ?? '').toString(),
      subtitle: (m['subtitle'] ?? '').toString(),
      countLabel: (m['count_label'] ?? '').toString(),
      actionLabel: (m['action_label'] ?? '').toString(),
      gradient: CatGradient.fromMap(m['gradient']),
    );
  }
}
