import 'product.dart';

/// CMD #1906 — the ONE search payload, for Home and for Catalogue.
///
/// `search_page(q, filters, page)` answers both screens, so everything a
/// search surface prints arrives here already worded, already ordered and
/// already decided: the placeholder in the box, the header line above the
/// list, the filter groups in the order they are drawn, the empty state with
/// its buttons, the paging labels and the idle rail.
///
/// Nothing in this file computes. There is no pluralising, no counting, no
/// "N results" built in Dart, no client-side sort and no default filter — a
/// string this file invents is a bug.
class SearchOption {
  /// The key handed back to the backend, untouched.
  final String key;
  final String label;

  /// The backend's own count for this option, or null when it sent none.
  final int? n;
  final bool selected;

  const SearchOption({
    required this.key,
    required this.label,
    required this.n,
    required this.selected,
  });

  factory SearchOption.fromMap(Map<String, dynamic> m) => SearchOption(
        key: (m['key'] ?? '').toString(),
        label: (m['label'] ?? '').toString(),
        n: m['n'] is num ? (m['n'] as num).toInt() : null,
        selected: m['selected'] == true,
      );
}

/// One filter group — category, pack type, Rx, product flags, sort.
///
/// [chipRow] is the BACKEND saying "draw this group's options inline as a chip
/// row" (the category row both screens have always shown). Every other group
/// draws as a single chip that opens its own sheet. The app never decides
/// which group that is.
class SearchFilterGroup {
  final String key;
  final String label;

  /// 'single' or 'multi', verbatim.
  final String mode;
  final bool chipRow;
  final List<SearchOption> options;

  const SearchFilterGroup({
    required this.key,
    required this.label,
    required this.mode,
    required this.chipRow,
    required this.options,
  });

  bool get isMulti => mode == 'multi';

  /// The options the viewer picked, in the backend's own order.
  List<SearchOption> get selected =>
      options.where((o) => o.selected).toList(growable: false);

  factory SearchFilterGroup.fromMap(Map<String, dynamic> m) =>
      SearchFilterGroup(
        key: (m['key'] ?? '').toString(),
        label: (m['label'] ?? '').toString(),
        mode: (m['mode'] ?? 'single').toString(),
        chipRow: m['chip_row'] == true,
        options: ((m['options'] as List?) ?? const [])
            .whereType<Map>()
            .map((o) => SearchOption.fromMap(Map<String, dynamic>.from(o)))
            .toList(growable: false),
      );
}

class SearchFilters {
  final String title;
  final String clearLabel;
  final String applyLabel;

  /// In the order the backend sent them. Never re-sorted here.
  final List<SearchFilterGroup> groups;

  const SearchFilters({
    required this.title,
    required this.clearLabel,
    required this.applyLabel,
    required this.groups,
  });

  static const empty = SearchFilters(
      title: '', clearLabel: '', applyLabel: '', groups: <SearchFilterGroup>[]);

  /// The group the backend marked as a chip row, or null when it sent none.
  SearchFilterGroup? get chipRowGroup {
    for (final g in groups) {
      if (g.chipRow) return g;
    }
    return null;
  }

  /// Every other group, still in payload order.
  List<SearchFilterGroup> get sheetGroups =>
      groups.where((g) => !g.chipRow).toList(growable: false);

  factory SearchFilters.fromMap(Map<String, dynamic> m) => SearchFilters(
        title: (m['title'] ?? '').toString(),
        clearLabel: (m['clear_label'] ?? '').toString(),
        applyLabel: (m['apply_label'] ?? '').toString(),
        groups: ((m['groups'] as List?) ?? const [])
            .whereType<Map>()
            .map((g) => SearchFilterGroup.fromMap(Map<String, dynamic>.from(g)))
            .toList(growable: false),
      );
}

/// A button on the empty state. `kind` is the backend's word for what it does
/// ('clear_filters', 'request'); `tone` is the backend's word for how it looks.
class SearchEmptyButton {
  final String kind;
  final String tone;
  final String label;

  const SearchEmptyButton(
      {required this.kind, required this.tone, required this.label});

  factory SearchEmptyButton.fromMap(Map<String, dynamic> m) => SearchEmptyButton(
        kind: (m['kind'] ?? '').toString(),
        tone: (m['tone'] ?? '').toString(),
        label: (m['label'] ?? '').toString(),
      );
}

class SearchEmpty {
  final String label;
  final String hint;
  final List<SearchEmptyButton> buttons;

  const SearchEmpty(
      {required this.label, required this.hint, required this.buttons});

  static const empty =
      SearchEmpty(label: '', hint: '', buttons: <SearchEmptyButton>[]);

  factory SearchEmpty.fromMap(Map<String, dynamic> m) => SearchEmpty(
        label: (m['label'] ?? '').toString(),
        hint: (m['hint'] ?? '').toString(),
        buttons: ((m['buttons'] as List?) ?? const [])
            .whereType<Map>()
            .map((b) => SearchEmptyButton.fromMap(Map<String, dynamic>.from(b)))
            .toList(growable: false),
      );
}

/// CMD #2010 — the idle rail: what the search surface offers when the box is
/// focused and nothing has been typed.
///
/// WHICH rail this is (`kind`) and what it is CALLED (`title`) are the
/// backend's answers, from `search_idle_rail()`: this customer's previously
/// ordered products when there are any, the zone's top sellers when there are
/// none. Nothing here decides either, and `has:false` draws nothing rather
/// than an empty heading.
class SearchRail {
  final bool has;

  /// 'last_ordered' or 'top_sellers'. Carried for the render-log and for
  /// tests — never branched on to change a label.
  final String kind;
  final String title;

  /// Home-card maps, the same shape every other rail in the app renders.
  final List<Map<String, dynamic>> items;

  const SearchRail(
      {required this.has,
      required this.kind,
      required this.title,
      required this.items});

  static const empty = SearchRail(
      has: false, kind: '', title: '', items: <Map<String, dynamic>>[]);

  factory SearchRail.fromMap(Map<String, dynamic> m) => SearchRail(
        has: m['has'] == true,
        kind: (m['kind'] ?? '').toString(),
        title: (m['title'] ?? '').toString(),
        items: ((m['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false),
      );
}

class SearchPaging {
  final int page;
  final int pageSize;
  final int returned;
  final bool hasMore;
  final int nextPage;
  final String moreLabel;
  final String endLabel;

  const SearchPaging({
    required this.page,
    required this.pageSize,
    required this.returned,
    required this.hasMore,
    required this.nextPage,
    required this.moreLabel,
    required this.endLabel,
  });

  static const empty = SearchPaging(
      page: 0,
      pageSize: 0,
      returned: 0,
      hasMore: false,
      nextPage: 0,
      moreLabel: '',
      endLabel: '');

  factory SearchPaging.fromMap(Map<String, dynamic> m) => SearchPaging(
        page: (m['page'] as num?)?.toInt() ?? 0,
        pageSize: (m['page_size'] as num?)?.toInt() ?? 0,
        returned: (m['returned'] as num?)?.toInt() ?? 0,
        hasMore: m['has_more'] == true,
        nextPage: (m['next_page'] as num?)?.toInt() ?? 0,
        moreLabel: (m['more_label'] ?? '').toString(),
        endLabel: (m['end_label'] ?? '').toString(),
      );
}

/// One `search_page()` answer.
class SearchPagePayload {
  final bool ok;
  final String query;
  final bool hasQuery;
  final String placeholder;
  final String headerLabel;
  final int total;
  final SearchFilters filters;
  final bool filtersActive;
  final SearchEmpty empty;
  final SearchRail rail;
  final SearchPaging paging;
  final List<Product> items;

  /// CMD #2011 — WHICH surfaces draw the inline category chip row under the
  /// search box. `search_page()` sends it from
  /// app_settings.search_chip_row_surfaces, so the row moves between screens
  /// with an UPDATE and no deploy. The Catalogue tab is not in the list: its
  /// Therapeutic class list further down the page is the way in. A payload
  /// with no such key at all (an old cache) draws the row everywhere, which is
  /// what every surface did before this change.
  final List<String>? chipRowSurfaces;

  /// True when [surface] is one the backend named. Absent list = every surface.
  bool drawsChipRow(String surface) =>
      chipRowSurfaces == null || chipRowSurfaces!.contains(surface);

  const SearchPagePayload({
    required this.ok,
    required this.query,
    required this.hasQuery,
    required this.placeholder,
    required this.headerLabel,
    required this.total,
    required this.filters,
    required this.filtersActive,
    required this.empty,
    required this.rail,
    required this.paging,
    required this.items,
    this.chipRowSurfaces,
  });

  static const failed = SearchPagePayload(
    ok: false,
    query: '',
    hasQuery: false,
    placeholder: '',
    headerLabel: '',
    total: 0,
    filters: SearchFilters.empty,
    filtersActive: false,
    empty: SearchEmpty.empty,
    rail: SearchRail.empty,
    paging: SearchPaging.empty,
    items: <Product>[],
  );

  factory SearchPagePayload.fromMap(Map<String, dynamic> m) => SearchPagePayload(
        ok: m['ok'] == true,
        query: (m['query'] ?? '').toString(),
        hasQuery: m['has_query'] == true,
        placeholder: (m['placeholder'] ?? '').toString(),
        headerLabel: (m['header_label'] ?? '').toString(),
        total: (m['total'] as num?)?.toInt() ?? 0,
        filters:
            SearchFilters.fromMap(Map<String, dynamic>.from((m['filters'] as Map?) ?? const {})),
        filtersActive: m['filters_active'] == true,
        empty: SearchEmpty.fromMap(
            Map<String, dynamic>.from((m['empty'] as Map?) ?? const {})),
        rail: SearchRail.fromMap(
            Map<String, dynamic>.from((m['rail'] as Map?) ?? const {})),
        paging: SearchPaging.fromMap(
            Map<String, dynamic>.from((m['paging'] as Map?) ?? const {})),
        items: ((m['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((r) => Product.fromHomeCard(Map<String, dynamic>.from(r)))
            .toList(growable: false),
        chipRowSurfaces: (m['chip_row_surfaces'] as List?)
            ?.map((e) => e.toString())
            .toList(growable: false),
      );

  /// The same payload with another page's rows appended. Used by "Load more":
  /// the LATER payload wins for every label and count, because the backend
  /// recomputed them for the page it just answered.
  SearchPagePayload appended(SearchPagePayload next) => SearchPagePayload(
        ok: next.ok,
        query: next.query,
        hasQuery: next.hasQuery,
        placeholder: next.placeholder,
        headerLabel: next.headerLabel,
        total: next.total,
        filters: next.filters,
        filtersActive: next.filtersActive,
        empty: next.empty,
        rail: next.rail,
        paging: next.paging,
        items: [...items, ...next.items],
        chipRowSurfaces: next.chipRowSurfaces,
      );

}

/// The search STATE — query, filters, page — as one value.
///
/// CMD #1906 item 4: this is what lives in the URL, so moving between Home and
/// Catalogue keeps the search. Both screens read and write the SAME parameter
/// names through this one codec; neither owns a private spelling.
class SearchQueryState {
  final String query;
  final String category;
  final List<String> packTypes;
  final String rx;
  final List<String> flags;
  final String sort;
  final int page;

  const SearchQueryState({
    this.query = '',
    this.category = 'All',
    this.packTypes = const [],
    this.rx = '',
    this.flags = const [],
    this.sort = 'relevance',
    this.page = 0,
  });

  static const blank = SearchQueryState();

  bool get hasQuery => query.trim().isNotEmpty;

  /// What goes to `search_page(p_filters)`. Absent keys mean "not narrowed" —
  /// the backend's own default, never a value invented here.
  Map<String, dynamic> toFilters() => <String, dynamic>{
        if (category.isNotEmpty && category != 'All') 'category': category,
        if (packTypes.isNotEmpty) 'pack_type': packTypes,
        if (rx.isNotEmpty) 'rx': rx,
        for (final f in flags) f: 'true',
        if (sort.isNotEmpty) 'sort': sort,
      };

  SearchQueryState copy({
    String? query,
    String? category,
    List<String>? packTypes,
    String? rx,
    List<String>? flags,
    String? sort,
    int? page,
  }) =>
      SearchQueryState(
        query: query ?? this.query,
        category: category ?? this.category,
        packTypes: packTypes ?? this.packTypes,
        rx: rx ?? this.rx,
        flags: flags ?? this.flags,
        sort: sort ?? this.sort,
        // Any change to what is being searched starts at page 0; only an
        // explicit page move keeps a page.
        page: page ?? 0,
      );

  /// Everything cleared except the query itself — what the empty state's
  /// "Clear all" button does on both screens.
  SearchQueryState cleared() => SearchQueryState(query: query);

  /// Applies one option tap, using the group's OWN mode. Multi toggles,
  /// single replaces, and tapping a selected single option clears it — except
  /// for the two groups whose backend default is a real value.
  SearchQueryState withOption(SearchFilterGroup g, SearchOption o) {
    switch (g.key) {
      case 'category':
        return copy(category: o.key);
      case 'sort':
        return copy(sort: o.key);
      case 'rx':
        return copy(rx: rx == o.key ? '' : o.key);
      case 'pack_type':
        final next = [...packTypes];
        if (!next.remove(o.key)) next.add(o.key);
        return copy(packTypes: next);
      case 'flags':
        final next = [...flags];
        if (!next.remove(o.key)) next.add(o.key);
        return copy(flags: next);
      default:
        return this;
    }
  }

  /// The URL both screens share: `?q=&category=&pack=&rx=&flags=&sort=&page=`.
  Map<String, String> toParams() => <String, String>{
        if (query.trim().isNotEmpty) 'q': query.trim(),
        if (category.isNotEmpty && category != 'All') 'category': category,
        if (packTypes.isNotEmpty) 'pack': packTypes.join(','),
        if (rx.isNotEmpty) 'rx': rx,
        if (flags.isNotEmpty) 'flags': flags.join(','),
        if (sort.isNotEmpty && sort != 'relevance') 'sort': sort,
        if (page > 0) 'page': page.toString(),
      };

  String toQueryString() {
    final p = toParams();
    if (p.isEmpty) return '';
    return p.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  static List<String> _csv(String? v) => (v ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);

  /// Reads the state back out of a URL's parameters. Unknown parameters are
  /// ignored rather than guessed at, so a link from a newer build still opens.
  factory SearchQueryState.fromParams(Map<String, String> p) => SearchQueryState(
        query: (p['q'] ?? '').trim(),
        category: (p['category'] ?? '').trim().isEmpty
            ? 'All'
            : (p['category'] ?? '').trim(),
        packTypes: _csv(p['pack']),
        rx: (p['rx'] ?? '').trim(),
        flags: _csv(p['flags']),
        sort: (p['sort'] ?? '').trim().isEmpty ? 'relevance' : p['sort']!.trim(),
        page: int.tryParse(p['page'] ?? '') ?? 0,
      );

  /// Reads it out of a whole location string (`/search?q=…`, `/catalogue?q=…`).
  factory SearchQueryState.fromLocation(String location) {
    final qm = location.indexOf('?');
    if (qm < 0) return SearchQueryState.blank;
    return SearchQueryState.fromParams(
        Uri.splitQueryString(location.substring(qm + 1)));
  }
}
