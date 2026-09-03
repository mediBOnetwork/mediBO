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

/// The "Available in my zone" control, exactly as `catalogue_zone_switch()`
/// describes it. [has] false → draw nothing at all; an anonymous visitor is
/// never shown a control that would not change what they see.
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

  const CatHome({
    required this.ok,
    required this.title,
    required this.subtitle,
    required this.searchHint,
    required this.zone,
    required this.tabs,
    required this.filters,
  });

  static CatHome fromMap(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
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
    );
  }
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
      childOpens: (m['child_opens'] ?? '').toString(),
      productsLabel: (m['products_label'] ?? '').toString(),
      hasProducts: m['has_products'] == true,
      hasMore: m['has_more'] == true,
      nextOffset: (m['next_offset'] as num?)?.toInt() ?? 0,
    );
  }
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
  final List<Product> items;
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
    required this.items,
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
      items: ((m['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((i) => Product.fromHomeCard(Map<String, dynamic>.from(i)))
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
