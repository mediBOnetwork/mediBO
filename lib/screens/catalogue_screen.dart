// CHANGE #747 — the Catalogue tab.
//
// Om: "the Catalogue bottom-nav button is dead." It has been since #630, which
// built the bottom bar from `customer_nav_slot` and gave the Catalogue row
// page_index 0 — a registry entry aimed at Home, because there was no screen
// to aim it at. This is the screen.
//
// WHAT THIS FILE IS ALLOWED TO DO: ask and paint. Every word on it — the tab
// names, the breadcrumbs, the counts, the filter chips, the sort names, the
// zone switch's own label and note, every empty state — arrives already worded
// from `catalogue_home` / `catalogue_tree` / `catalogue_companies` /
// `catalogue_salts` / `catalogue_list`. There is not one `'...'` of display
// text below, no count is formatted here and no plural is decided here. The
// one thing this file owns is the deep link, because the URL is the browser's
// and not the database's.
//
// The grid is [CompactProductCard] verbatim, fed by [Product.fromHomeCard],
// because `_cat_cards()` returns the same card `_sf_cards()` returns. A
// catalogue row and a home rail row are the same product, so they must be the
// same widget reading the same parser — otherwise the two surfaces eventually
// disagree about a price.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../models/catalogue.dart';
import '../models/product.dart';
import '../services/ui_copy.dart';
import '../url_sync.dart';
import '../utils/render_log.dart';
import '../widgets/catalogue_alphabet_rail.dart';
import '../widgets/catalogue_product_card.dart';
import '../widgets/product_image.dart';
import '../widgets/search_typeahead.dart';
import 'admin/nav_registry_view.dart' show NavGlyph;
import 'catalogue_extras.dart'; // CHANGE #748

/// Test seam: production goes to Supabase, a test hands back a payload.
typedef CatalogueRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> args);

/// Where the catalogue currently is. One immutable value, so the URL, the
/// fetch and the back stack are three readings of the SAME thing rather than
/// three pieces of state that have to be kept in agreement.
class CatalogueRoute {
  /// 'browse' | 'companies' | 'salts' | a tab key the backend sent.
  final String tab;

  /// The browse trail: [] | [therapeutic] | [therapeutic, chemical].
  final List<String> path;

  /// Set when a product LIST is open: the scope the backend lists by.
  final String? listKind;
  final String? listKey;

  final CatFilterState filters;
  final String sort;
  final bool zoneOn;
  final String query;

  const CatalogueRoute({
    this.tab = 'browse',
    this.path = const [],
    this.listKind,
    this.listKey,
    this.filters = const CatFilterState(),
    this.sort = 'name',
    this.zoneOn = true,
    this.query = '',
  });

  bool get showsList => listKind != null;

  CatalogueRoute copy({
    String? tab,
    List<String>? path,
    Object? listKind = _keep,
    Object? listKey = _keep,
    CatFilterState? filters,
    String? sort,
    bool? zoneOn,
    String? query,
  }) =>
      CatalogueRoute(
        tab: tab ?? this.tab,
        path: path ?? this.path,
        listKind: identical(listKind, _keep) ? this.listKind : listKind as String?,
        listKey: identical(listKey, _keep) ? this.listKey : listKey as String?,
        filters: filters ?? this.filters,
        sort: sort ?? this.sort,
        zoneOn: zoneOn ?? this.zoneOn,
        query: query ?? this.query,
      );

  static const Object _keep = Object();

  /// The URL this state is. Restoring is [parse]'s job and the two are
  /// deliberately adjacent: a link that cannot be read back is not a deep link.
  String get url {
    final q = <String>[];
    if (tab != 'browse') q.add('tab=$tab');
    if (path.isNotEmpty) q.add('p=${path.map(Uri.encodeComponent).join('/')}');
    if (listKind != null) q.add('lk=$listKind');
    if (listKey != null) q.add('k=${Uri.encodeComponent(listKey!)}');
    if (sort != 'name') q.add('sort=$sort');
    if (!zoneOn) q.add('zone=0');
    if (query.isNotEmpty) q.add('q=${Uri.encodeComponent(query)}');
    final f = filters.toQuery();
    if (f.isNotEmpty) q.add(f);
    return q.isEmpty ? '/catalogue' : '/catalogue?${q.join('&')}';
  }

  /// True for any URL this screen owns, so the shell's one route check stays
  /// one line no matter how many parameters the catalogue grows.
  static bool matches(String path) =>
      path == '/catalogue' || path.startsWith('/catalogue?') || path.startsWith('/catalogue/');

  static CatalogueRoute parse(String search) {
    final q = Uri.splitQueryString(search.startsWith('?') ? search.substring(1) : search);
    final raw = q['p'] ?? '';
    return CatalogueRoute(
      tab: (q['tab'] ?? 'browse'),
      path: raw.isEmpty
          ? const []
          : raw.split('/').where((s) => s.isNotEmpty).map(Uri.decodeComponent).toList(),
      listKind: q['lk'],
      listKey: q['k'] == null ? null : Uri.decodeComponent(q['k']!),
      filters: CatFilterState.fromQuery(q),
      sort: q['sort'] == 'newest' ? 'newest' : 'name',
      zoneOn: q['zone'] != '0',
      query: q['q'] == null ? '' : Uri.decodeComponent(q['q']!),
    );
  }
}

class CatalogueScreen extends StatefulWidget {
  /// True while this is the visible shell page. The screen lives inside an
  /// IndexedStack, so it is BUILT whether or not anyone is looking at it —
  /// firing five RPCs for a visitor who tapped Orders is the mistake #633
  /// fixed for the admin pages, and this screen does not repeat it.
  final bool active;

  /// Test seam.
  final CatalogueRpc? rpc;

  /// The initial deep link. Null in production means "read the browser URL".
  final CatalogueRoute? initialRoute;

  const CatalogueScreen({super.key, this.active = false, this.rpc, this.initialRoute});

  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  late CatalogueRoute _route;

  CatHome? _home;
  CatBrowse? _browse;
  CatList? _list;
  // CHANGE #748 — Recently added / Missing product / Export. The payload says
  // whether each is offered at all, so an empty map simply draws none of them.
  Map<String, dynamic> _extras = const {};

  bool _booted = false;
  bool _loading = false;
  bool _loadingMore = false;
  String _error = '';

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  // CHANGE #799 — the typeahead panel under the hero search. The controller
  // owns the debounce and the last payload; the panel renders it verbatim.
  final _suggest = SearchSuggestController();

  /// Pack families for the ids currently on screen. Asked for AFTER the grid
  /// paints (`catalogue_variants`), so first paint never waits on it.
  CatVariantMap _variants = CatVariantMap.empty;
  final Set<String> _variantsAsked = <String>{};

  final List<CatRow> _rows = [];
  int _nextOffset = 0;
  bool _rowsHaveMore = false;
  String? _cursor;

  static const int _pageSize = 24;
  static const int _rowPage = 40;

  @override
  void initState() {
    super.initState();
    // initialSearch(), not currentSearch(): boot's usePathUrlStrategy rewrite
    // has already erased the live query string by the time this runs.
    _route = widget.initialRoute ?? CatalogueRoute.parse(initialSearch());
    _searchCtrl.text = _route.query;
    _scroll.addListener(_onScroll);
    _suggest.addListener(_onSuggest);
    if (widget.active) _boot();
  }

  @override
  void didUpdateWidget(covariant CatalogueScreen old) {
    super.didUpdateWidget(old);
    // First time the tab is actually opened — not at shell boot.
    if (widget.active && !old.active && !_booted) _boot();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _suggest.removeListener(_onSuggest);
    _suggest.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> args) async {
    if (widget.rpc != null) return widget.rpc!(fn, args);
    final raw = await Supabase.instance.client.rpc(fn, params: args);
    final m = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{};
  }

  Future<void> _boot() async {
    _booted = true;
    setState(() => _loading = true);
    try {
      final home = CatHome.fromMap(await _call('catalogue_home', {'p_zone': _route.zoneOn}));
      if (!mounted) return;
      setState(() => _home = home);
      // CHANGE #748 — best-effort: the three extras must never be able to stop
      // the catalogue itself from booting.
      try {
        final ex = await _call('catalogue_extras', {'p_zone': _route.zoneOn});
        if (mounted) setState(() => _extras = ex);
      } catch (_) {}
      RenderLog.write('c747_catalogue_tabs',
          '${home.tabs.map((t) => t.key).join('>')};'
          'zone=${home.zone.has ? (home.zone.on ? 'on' : 'off') : 'none'}');
      await _fetch();
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  /// Load whatever the current route points at. Every navigation in this screen
  /// is "change the route, then call this" — there is no second code path.
  Future<void> _fetch() async {
    setState(() { _loading = true; _error = ''; });
    try {
      if (_route.showsList) {
        final p = await _call('catalogue_list', {
          'p_kind': _route.listKind,
          'p_key': _route.listKey,
          'p_path': _route.path,
          'p_filters': _route.filters.toRpc(),
          'p_sort': _route.sort,
          'p_zone': _route.zoneOn,
          'p_cursor': null,
          'p_limit': _pageSize,
        });
        if (!mounted) return;
        final list = CatList.fromMap(p);
        setState(() {
          _list = list;
          _cursor = list.nextCursor;
          _loading = false;
        });
        RenderLog.write('c747_catalogue_list',
            '${_route.listKind}:${_route.listKey ?? _route.path.join('/')};'
            'items=${list.items.length};more=${list.hasMore};filters=${list.filtersActive}');
        unawaited(_loadVariants(list.items));
      } else {
        final fn = switch (_route.tab) {
          'companies' => 'catalogue_companies',
          'salts' => 'catalogue_salts',
          _ => 'catalogue_tree',
        };
        final args = switch (_route.tab) {
          'companies' => {
              'p_letter': _route.query.isEmpty ? _letter : null,
              'p_q': _route.query.isEmpty ? null : _route.query,
              'p_offset': 0, 'p_limit': _rowPage, 'p_zone': _route.zoneOn,
            },
          'salts' => {
              'p_q': _route.query.isEmpty ? null : _route.query,
              'p_offset': 0, 'p_limit': _rowPage, 'p_zone': _route.zoneOn,
            },
          _ => {'p_path': _route.path, 'p_zone': _route.zoneOn},
        };
        final b = CatBrowse.fromMap(await _call(fn, args));
        if (!mounted) return;
        setState(() {
          _browse = b;
          _rows
            ..clear()
            ..addAll(b.rows);
          _rowsHaveMore = b.hasMore;
          _nextOffset = b.nextOffset;
          _loading = false;
        });
        RenderLog.write('c747_catalogue_browse',
            '${_route.tab};depth=${_route.path.length};rows=${b.rows.length};more=${b.hasMore}');
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  String? _letter;

  void _onSuggest() { if (mounted) setState(() {}); }

  /// CHANGE #799 — the pack families for a page of cards, asked for once the
  /// cards are already on screen. `catalogue_list` is 190 ms on a warm scope
  /// and the variant join adds 170 ms to it; a buyer should not wait 170 ms
  /// longer for a grid so that a chip row can arrive at the same instant.
  Future<void> _loadVariants(List<Product> items) async {
    final ids = <int>[];
    for (final p in items) {
      if (_variantsAsked.contains(p.id)) continue;
      final n = int.tryParse(p.id);
      if (n != null) { ids.add(n); _variantsAsked.add(p.id); }
    }
    if (ids.isEmpty) return;
    try {
      final v = CatVariantMap.fromMap(await _call('catalogue_variants', {'p_ids': ids}));
      if (!mounted || v.byId.isEmpty) return;
      setState(() => _variants = _variants.merge(v));
      RenderLog.write('c799_catalogue_variants', 'families=${v.byId.length}');
    } catch (_) {
      // A family that never arrives is a card with no chip row — which is
      // exactly what a one-pack product looks like. Never an error line.
    }
  }

  /// The typeahead's own answer: the BACKEND's query for the tapped
  /// suggestion, which for a Hindi word is the salt and not the word.
  void _pickSuggestion(String query) {
    _suggest.close();
    _searchFocus.unfocus();
    _searchCtrl.text = query;
    _letter = null;
    // A search is a PRODUCT search, so it opens the grid — the same scope the
    // full catalogue uses, narrowed by the backend's own query string.
    _go(_route.copy(tab: 'browse', path: const [], listKind: 'search',
        listKey: query, query: query));
  }

  void _go(CatalogueRoute next, {bool push = true}) {
    setState(() {
      _route = next;
      _searchCtrl.text = next.query;
      _rows.clear();
      _cursor = null;
      _list = null;
      _browse = null;
    });
    _suggest.close();
    if (push) pushUrl(next.url);
    _fetch();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 600) return;
    if (_route.showsList) {
      if (_list?.hasMore == true && _cursor != null) _moreProducts();
    } else if (_rowsHaveMore) {
      _moreRows();
    }
  }

  Future<void> _moreProducts() async {
    setState(() => _loadingMore = true);
    try {
      final p = CatList.fromMap(await _call('catalogue_list', {
        'p_kind': _route.listKind,
        'p_key': _route.listKey,
        'p_path': _route.path,
        'p_filters': _route.filters.toRpc(),
        'p_sort': _route.sort,
        'p_zone': _route.zoneOn,
        'p_cursor': _cursor,
        'p_limit': _pageSize,
      }));
      if (!mounted) return;
      final cur = _list;
      setState(() {
        _loadingMore = false;
        if (cur == null || !p.ok) return;
        _list = CatList(
          ok: cur.ok, title: cur.title, subtitle: cur.subtitle,
          countLabel: cur.countLabel, emptyLabel: cur.emptyLabel,
          moreLabel: cur.moreLabel, endLabel: cur.endLabel, sort: cur.sort,
          filtersActive: cur.filtersActive, filtersActiveLabel: cur.filtersActiveLabel,
          zone: cur.zone, filters: cur.filters,
          sentence: cur.sentence, empty: cur.empty,
          items: [...cur.items, ...p.items],
          // Paging stops when the BACKEND says so, never when a page comes back
          // short — that is wrong on an exact boundary.
          hasMore: p.hasMore, nextCursor: p.nextCursor,
        );
        _cursor = p.nextCursor;
      });
      unawaited(_loadVariants(p.items));
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _moreRows() async {
    setState(() => _loadingMore = true);
    try {
      final fn = _route.tab == 'companies' ? 'catalogue_companies' : 'catalogue_salts';
      final args = _route.tab == 'companies'
          ? {
              'p_letter': _route.query.isEmpty ? _letter : null,
              'p_q': _route.query.isEmpty ? null : _route.query,
              'p_offset': _nextOffset, 'p_limit': _rowPage, 'p_zone': _route.zoneOn,
            }
          : {
              'p_q': _route.query.isEmpty ? null : _route.query,
              'p_offset': _nextOffset, 'p_limit': _rowPage, 'p_zone': _route.zoneOn,
            };
      final b = CatBrowse.fromMap(await _call(fn, args));
      if (!mounted) return;
      final seen = _rows.map((r) => r.key).toSet();
      setState(() {
        _loadingMore = false;
        _rows.addAll(b.rows.where((r) => seen.add(r.key)));
        _rowsHaveMore = b.hasMore;
        _nextOffset = b.nextOffset;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  // ── taps ──────────────────────────────────────────────────────────────────

  void _tapTab(CatTab t) {
    _letter = null;
    if (t.kind == 'list') {
      _go(_route.copy(tab: t.key, path: const [], listKind: t.listKind,
          listKey: t.listKey, query: ''));
    } else {
      _go(_route.copy(tab: t.key, path: const [], listKind: null, listKey: null, query: ''));
    }
  }

  void _tapRow(CatRow r) {
    switch (_route.tab) {
      case 'companies':
        _go(_route.copy(listKind: 'company', listKey: r.key));
      case 'salts':
        _go(_route.copy(listKind: 'salt', listKey: r.key));
      default:
        final b = _browse;
        final next = [..._route.path, r.key];
        // WHERE the next tap goes is the BACKEND's answer (`child_opens`), not
        // a depth this screen counts for itself.
        if (b != null && b.childOpens == 'products') {
          _go(_route.copy(path: next, listKind: 'tree', listKey: null));
        } else {
          _go(_route.copy(path: next, listKind: null, listKey: null));
        }
    }
  }

  void _crumbTo(int depth) => _go(_route.copy(
      path: _route.path.take(depth).toList(), listKind: null, listKey: null));

  // ── build ─────────────────────────────────────────────────────────────────

  /// The catalogue's own front page: no tab chosen, no list open, no crumb.
  /// Only here do the doors and the recently-viewed strip appear — inside a
  /// tab they would be furniture in the way of the thing you came for.
  bool get _isHome => !_route.showsList && _route.tab == 'browse' && _route.path.isEmpty;

  @override
  Widget build(BuildContext context) {
    final home = _home;
    if (!_booted || (home == null && _loading)) return const _CatSkeleton();
    if (home == null) return _CatError(message: _error, onRetry: _boot);

    return Container(
      color: Ds.c.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. The search bar IS the screen's hero — one field, at the top,
          //    above everything else, on every state of this tab.
          _SearchHero(
            home: home,
            controller: _searchCtrl,
            focus: _searchFocus,
            zoneOn: _route.zoneOn,
            suggest: _suggest,
            onSubmit: (q) {
              final t = q.trim();
              if (t.isEmpty) return;
              _suggest.close();
              _letter = null;
              _go(_route.copy(tab: 'browse', path: const [], listKind: 'search',
                  listKey: t, query: t));
            },
            onPick: _pickSuggestion,
            onClear: () {
              _searchCtrl.clear();
              _suggest.close();
              if (_route.listKind == 'search') {
                _go(_route.copy(listKind: null, listKey: null, query: ''));
              }
            },
          ),
          // 2. The sentence. Sticky under the search on every state, because a
          //    filter you cannot see is a filter you forget you set.
          _SentenceRow(
            sentence: _route.showsList
                ? (_list?.sentence ?? home.sentence)
                : home.sentence,
            state: _route.filters,
            onToggle: (g, k, single) {
              if (g == 'zone') { _go(_route.copy(zoneOn: !_route.zoneOn)); return; }
              final next = _route.filters.toggle(g, k, single: single);
              // A chip tapped on the front page has to have somewhere to land:
              // it opens the whole-catalogue grid already narrowed by it.
              _go(_route.showsList
                  ? _route.copy(filters: next)
                  : _route.copy(filters: next, listKind: 'tree', listKey: null));
            },
            onClear: () => _go(_route.copy(filters: const CatFilterState())),
          ),
          if (_route.showsList)
            _ListToolbar(
              list: _list,
              route: _route,
              onSort: (k) => _go(_route.copy(sort: k)),
              onToggle: (g, k, single) =>
                  _go(_route.copy(filters: _route.filters.toggle(g, k, single: single))),
              onClear: () => _go(_route.copy(filters: const CatFilterState())),
            ),
          // CHANGE #1362 — the catalogue export ("Make the PDF") is GONE, on
          // purpose: it let anyone bulk-download the product list a competitor
          // would otherwise have to scrape. There is no export widget, no
          // `export` block in catalogue_extras() and no catalogue_export_*
          // RPC left to call. Do not reintroduce one here.
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    // CHANGE #748 — the Recently-added tab is its own body, fetched by its own
    // RPC. It is reached the same way every other tab is: the backend put a tab
    // in the strip whose `kind` this build knows.
    if (_route.tab == 'recent') return const CatalogueRecent();
    if (_loading) return const _CatSkeleton();
    if (_error.isNotEmpty) return _CatError(message: _error, onRetry: _fetch);
    return _route.showsList ? _productGrid() : _rowList();
  }

  /// CHANGE #748 — the request sheet. A sheet, not a dialog, per DESIGN.md, and
  /// it is only ever offered when the payload said `show`.
  void _openRequest() {
    final cfg = _extras['request'];
    if (cfg is! Map) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) =>
          CatalogueRequestSheet(config: Map<String, dynamic>.from(cfg)),
    );
  }

  /// Long-press on a card. Everything the sheet prints is already on the card's
  /// own payload, so a peek costs no round trip — which is the whole point of
  /// it on a slow connection.
  void _openPeek(Product p) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => CataloguePeekSheet(
        product: p,
        variants: _variants.of(p.id),
        title: _peek('title'),
        openLabel: _peek('open_label'),
        onOpen: () {
          Navigator.of(context).pop();
          Navigator.of(context).pushNamed('/product/${p.id}');
        },
        onVariant: (id) {
          Navigator.of(context).pop();
          Navigator.of(context).pushNamed('/product/$id');
        },
      ),
    );
  }

  Widget _rowList() {
    final b = _browse;
    if (b == null) return const _CatSkeleton();

    final searchable = _route.tab == 'companies' || _route.tab == 'salts';
    final list = CustomScrollView(
      controller: _scroll,
      slivers: [
        // The front page: recently viewed, then the three doors, then the tree.
        if (_isHome && (_home?.hasRecentViewed ?? false))
          SliverToBoxAdapter(
            child: _RecentStrip(
              title: _home!.recentViewedTitle,
              items: _home!.recentViewed,
              onTap: (p) => Navigator.of(context).pushNamed('/product/${p.id}'),
            ),
          ),
        if (_isHome && (_home?.doors.isNotEmpty ?? false))
          SliverToBoxAdapter(
            child: _Doors(
              title: _home!.doorsTitle,
              doors: _home!.doors,
              onTap: (d) {
                _letter = null;
                _go(_route.copy(tab: d.tab, path: const [], listKind: null,
                    listKey: null, query: ''));
              },
            ),
          ),
        if (_isHome) SliverToBoxAdapter(child: _tabStrip()),
        // The zone control keeps a place of its own on the front page. The
        // sentence chip above is the quick toggle; this is the SETTING, and
        // only it carries the backend's sentence explaining what the switch
        // does — a chip cannot say "Showing what suppliers in your zone can
        // send." and stay a chip.
        if (_isHome && (_home?.zone.has ?? false))
          SliverToBoxAdapter(
            child: _ZoneSwitch(
              zone: _home!.zone,
              on: _route.zoneOn,
              onChanged: (on) => _go(_route.copy(zoneOn: on)),
            ),
          ),
        if (searchable && _route.tab == 'salts')
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x4),
              child: TextField(
                controller: TextEditingController(text: _route.query),
                onSubmitted: (v) => _go(_route.copy(query: v.trim())),
                decoration: InputDecoration(
                  hintText: b.searchHint,
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                ),
              ),
            ),
          ),
        if (_route.path.isNotEmpty)
          SliverToBoxAdapter(child: _Crumbs(browse: b, path: _route.path, onTap: _crumbTo)),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x8),
            child: Row(
              children: [
                Expanded(child: Text(b.title, style: Ds.t.title)),
                Text(b.countLabel, style: Ds.t.caption),
              ],
            ),
          ),
        ),
        if (b.leadLabel.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(Ds.space.x16, 0, Ds.space.x16, Ds.space.x8),
              child: Text(b.leadLabel, style: Ds.t.caption),
            ),
          ),
        // A level with no children of its own still has products behind it —
        // the backend says so, and this is the way through.
        if (_rows.isEmpty && b.hasProducts)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(Ds.space.x16),
              child: _OpenProducts(
                label: b.productsLabel,
                onTap: () => _go(_route.copy(listKind: 'tree', listKey: null)),
              ),
            ),
          ),
        if (_rows.isEmpty && !b.hasProducts)
          SliverToBoxAdapter(child: _CatEmpty(label: b.emptyLabel)),
        SliverList.separated(
          itemCount: _rows.length,
          separatorBuilder: (_, _) => Divider(height: 1, color: Ds.c.divider),
          itemBuilder: (context, i) => _BrowseRow(row: _rows[i], onTap: () => _tapRow(_rows[i])),
        ),
        if (b.hasProducts && _rows.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(Ds.space.x16),
              child: _OpenProducts(
                label: b.productsLabel,
                onTap: () => _go(_route.copy(listKind: 'tree', listKey: null)),
              ),
            ),
          ),
        SliverToBoxAdapter(child: _Tail(loading: _loadingMore)),
      ],
    );

    // CHANGE #799 — the A–Z rail rides on the RIGHT of the company list, on
    // top of it rather than beside it, so the rows keep the full width.
    if (_route.tab != 'companies' || b.rail.isEmpty) return list;
    return Stack(
      children: [
        Positioned.fill(child: list),
        Positioned(
          top: Ds.space.x24,
          bottom: Ds.space.x24,
          right: 0,
          child: CatalogueAlphabetRail(
            rail: b.rail,
            active: _letter,
            onPick: (l) { _letter = l; _go(_route.copy(query: '')); },
          ),
        ),
      ],
    );
  }

  /// The tabs #747/#748 shipped — Schemes, Cold chain, Recently added — now a
  /// quiet chip row under the doors instead of the screen's main navigation.
  Widget _tabStrip() {
    final home = _home;
    if (home == null) return const SizedBox.shrink();
    const known = {'list', 'recent'};
    final tabs = home.tabs.where((t) => known.contains(t.kind)).toList();
    final recent = _extras['recent'];
    if (recent is Map && recent['show'] == true) {
      tabs.add(CatTab.fromMap(Map<String, dynamic>.from(recent)));
    }
    if (tabs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x24),
      child: SizedBox(
        height: Ds.touch.minTarget,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          itemCount: tabs.length,
          separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
          itemBuilder: (context, i) => Center(
            // Label and count are two payload strings and stay two Texts.
            // Joining them into one is the app writing a sentence.
            child: _Chip(
              label: tabs[i].label,
              count: tabs[i].countLabel,
              selected: tabs[i].key == _route.tab,
              onTap: () => _tapTab(tabs[i]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _productGrid() {
    final l = _list;
    if (l == null) return const _CatSkeleton();
    if (l.items.isEmpty) {
      return CustomScrollView(controller: _scroll, slivers: [
        SliverToBoxAdapter(
          child: _CatEmptyState(
            empty: l.empty,
            onAction: _openRequest,
            onClear: () => _go(_route.copy(filters: const CatFilterState())),
          ),
        ),
      ]);
    }
    return LayoutBuilder(builder: (context, c) {
      final cross = c.maxWidth >= 900 ? 4 : c.maxWidth >= 600 ? 3 : 2;
      return CustomScrollView(
        controller: _scroll,
        // The grid is a sliver list: only the cards on screen are built, so a
        // 5.6-lakh scope costs the same as a 24-row one on a low-end phone.
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.title, style: Ds.t.title),
                  if (l.subtitle.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x4),
                    Text(l.subtitle, style: Ds.t.caption),
                  ],
                  SizedBox(height: Ds.space.x4),
                  Text(l.countLabel, style: Ds.t.caption),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cross,
                mainAxisExtent: CatalogueProductCard.extent,
                crossAxisSpacing: Ds.space.x12,
                mainAxisSpacing: Ds.space.x12,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => CatalogueProductCard(
                  product: l.items[i],
                  variants: _variants.of(l.items[i].id),
                  addedLabel: _addedLabel,
                  undoLabel: _undoLabel,
                  onTap: () => Navigator.of(context).pushNamed('/product/${l.items[i].id}'),
                  onPeek: () => _openPeek(l.items[i]),
                  onVariant: (id) => Navigator.of(context).pushNamed('/product/$id'),
                ),
                childCount: l.items.length,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(Ds.space.x16),
              child: Center(
                child: _loadingMore
                    ? const _MoreSkeleton()
                    : Text(l.hasMore ? l.moreLabel : l.endLabel, style: Ds.t.caption),
              ),
            ),
          ),
        ],
      );
    });
  }

  /// The add toast and its undo word, from the payload the extras call
  /// returned. Absent means no snackbar — never a sentence written here.
  String get _addedLabel =>
      (_extras['added'] is Map ? (_extras['added'] as Map)['label'] : '')?.toString() ?? '';
  String get _undoLabel =>
      (_extras['added'] is Map ? (_extras['added'] as Map)['undo_label'] : '')?.toString() ?? '';
  String _peek(String k) =>
      (_extras['peek'] is Map ? (_extras['peek'] as Map)[k] : '')?.toString() ?? '';
}

// ── pieces ────────────────────────────────────────────────────────────────

/// CHANGE #799 — the hero. One field, at the top, on every state of the tab,
/// with the typeahead panel #790 built hanging under it.
class _SearchHero extends StatelessWidget {
  final CatHome home;
  final TextEditingController controller;
  final FocusNode focus;
  final bool zoneOn;
  final SearchSuggestController suggest;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String> onPick;
  final VoidCallback onClear;

  const _SearchHero({
    required this.home,
    required this.controller,
    required this.focus,
    required this.zoneOn,
    required this.suggest,
    required this.onSubmit,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) => Container(
        color: Ds.c.surface,
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: Ds.touch.minTarget,
              child: TextField(
                controller: controller,
                focusNode: focus,
                textInputAction: TextInputAction.search,
                onChanged: (v) => suggest.onQueryChanged(v, zoneOnly: zoneOn),
                onSubmitted: onSubmit,
                decoration: InputDecoration(
                  // The placeholder is the payload's. There is no second
                  // sentence under this field: the field IS the instruction.
                  hintText: home.searchPlaceholder,
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, v, _) => v.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            tooltip: home.searchClearLabel,
                            icon: const Icon(Icons.close),
                            onPressed: onClear,
                          ),
                  ),
                ),
              ),
            ),
            // The panel is part of the header, not an overlay: an overlay over
            // a canvas app is one more layer to composite on a low-end phone,
            // and this list is already the thing under the finger.
            ListenableBuilder(
              listenable: suggest,
              builder: (context, _) => suggest.isOpen
                  ? Padding(
                      padding: EdgeInsets.only(top: Ds.space.x8),
                      child: SearchSuggestions(
                          payload: suggest.payload, onPick: onPick),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      );
}

/// CHANGE #799 — "Showing · Tablets · Rx · In my zone".
///
/// Chips, never a menu. The lead word, the dot between the chips, which chips
/// are worth offering and whether each is on are all `catalogue_sentence()`'s
/// answers — this row lays them out and hands taps back.
class _SentenceRow extends StatelessWidget {
  final CatSentence sentence;
  final CatFilterState state;
  final void Function(String group, String key, bool single) onToggle;
  final VoidCallback onClear;

  const _SentenceRow({
    required this.sentence,
    required this.state,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    if (sentence.isEmpty) return const SizedBox.shrink();
    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: SizedBox(
        height: Ds.touch.minTarget,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          children: [
            if (sentence.lead.isNotEmpty)
              Center(
                child: Padding(
                  padding: EdgeInsets.only(right: Ds.space.x8),
                  child: Text(
                      sentence.hasSelection
                          ? sentence.lead
                          : '${sentence.lead} ${sentence.allLabel}'.trim(),
                      style: Ds.t.caption),
                ),
              ),
            for (final part in sentence.parts)
              _Chip(
                label: part.label,
                selected: part.selected,
                onTap: () => onToggle(part.group, part.key, part.isSingle),
              ),
            if (sentence.hasSelection && sentence.clearLabel.isNotEmpty)
              _Chip(label: sentence.clearLabel, selected: false, onTap: onClear),
          ],
        ),
      ),
    );
  }
}

/// The zone switch. Drawn only when the backend said this viewer HAS one, and
/// worded entirely by it — including the sentence under it, which changes with
/// the switch because the backend changed it, not because this widget did.
class _ZoneSwitch extends StatelessWidget {
  final CatZone zone;
  final bool on;
  final ValueChanged<bool> onChanged;
  const _ZoneSwitch({required this.zone, required this.on, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x24, Ds.space.x8, 0),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(zone.label, style: Ds.t.body),
                  if (zone.note.isNotEmpty) Text(zone.note, style: Ds.t.caption),
                ],
              ),
            ),
            Switch(value: on, activeThumbColor: Ds.c.brand, onChanged: onChanged),
          ],
        ),
      );
}

/// CHANGE #799 — three doors, large and calm: a glyph, a name, a count in
/// grey. Nothing else on the tile, which is the whole instruction.
class _Doors extends StatelessWidget {
  final String title;
  final List<CatDoor> doors;
  final ValueChanged<CatDoor> onTap;
  const _Doors({required this.title, required this.doors, required this.onTap});

  // 120, not 104: the count is a SENTENCE the backend wrote ("1,06,571
  // salts", "3,35,273 products"), and at three tiles across a 390pt phone one
  // line of it ellipsised to "18,563 comp…". A tile that hides the number it
  // exists to show is the truncation the design contract forbids, so the tile
  // grew and the count wraps to two lines instead.
  static const double _tileH = 120;
  static const double _glyphBox = 32;
  static const double _glyph = 20;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x24, Ds.space.x16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty) ...[
              Text(title, style: Ds.t.caption),
              SizedBox(height: Ds.space.x8),
            ],
            Row(
              children: [
                for (var i = 0; i < doors.length; i++) ...[
                  if (i > 0) SizedBox(width: Ds.space.x12),
                  Expanded(
                    child: InkWell(
                      onTap: () => onTap(doors[i]),
                      borderRadius: Ds.r.rCard,
                      child: Ink(
                        height: _tileH,
                        decoration: BoxDecoration(
                          color: Ds.c.surface,
                          borderRadius: Ds.r.rCard,
                          border: Border.all(color: Ds.c.divider),
                        ),
                        padding: EdgeInsets.all(Ds.space.x12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            NavGlyph(
                              row: doors[i].glyphRow,
                              box: _glyphBox,
                              glyph: _glyph,
                              color: Ds.c.brand,
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(doors[i].label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Ds.t.bodyStrong),
                                Text(doors[i].countLabel,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Ds.t.caption),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
}

/// CHANGE #799 — the horizontal strip above the doors. Present only when the
/// BACKEND said this viewer has one (`recent_viewed.has`), so an anonymous
/// visitor and a buyer with no history both simply get no strip.
class _RecentStrip extends StatelessWidget {
  final String title;
  final List<Product> items;
  final ValueChanged<Product> onTap;
  const _RecentStrip({required this.title, required this.items, required this.onTap});

  static const double _tile = 88;
  static const double _row = 132;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(Ds.space.x16, 0, Ds.space.x16, Ds.space.x8),
            child: Text(title, style: Ds.t.caption),
          ),
          SizedBox(
            height: _row,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              itemCount: items.length,
              separatorBuilder: (_, _) => SizedBox(width: Ds.space.x12),
              itemBuilder: (context, i) => InkWell(
                onTap: () => onTap(items[i]),
                borderRadius: Ds.r.rCard,
                child: SizedBox(
                  width: _tile,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: _tile,
                        width: _tile,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Ds.c.surface,
                          borderRadius: Ds.r.rCard,
                          border: Border.all(color: Ds.c.divider),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(Ds.space.x8),
                          child: ProductImage(
                            url: items[i].imageUrl,
                            width: _tile,
                            height: _tile,
                            radius: Ds.r.rChip,
                          ),
                        ),
                      ),
                      SizedBox(height: Ds.space.x4),
                      Expanded(
                        child: Text(items[i].name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Ds.t.caption.copyWith(color: Ds.c.text)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ListToolbar extends StatelessWidget {
  final CatList? list;
  final CatalogueRoute route;
  final ValueChanged<String> onSort;
  final void Function(String group, String key, bool single) onToggle;
  final VoidCallback onClear;

  const _ListToolbar({
    required this.list,
    required this.route,
    required this.onSort,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final f = list?.filters ?? CatFilters.empty;
    if (f.groups.isEmpty && f.sortOptions.isEmpty) return const SizedBox.shrink();
    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: SizedBox(
        height: Ds.touch.minTarget,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          children: [
            for (final s in f.sortOptions)
              _Chip(
                label: s.label,
                selected: route.sort == s.key,
                onTap: () => onSort(s.key),
              ),
            for (final g in f.groups)
              for (final o in g.options)
                _Chip(
                  label: o.label,
                  selected: route.filters.isOn(g.key, o.key),
                  onTap: () => onToggle(g.key, o.key, !g.isMulti),
                ),
            if (route.filters.isEmpty == false)
              _Chip(label: f.clearLabel, selected: false, onTap: onClear),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;

  /// A second payload string beside the label — a tab's count. Two strings,
  /// two Texts: joining them here would be the app writing a sentence.
  final String count;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count = '',
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(right: Ds.space.x8),
        child: Center(
          child: InkWell(
            onTap: onTap,
            borderRadius: Ds.r.rChip,
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x8),
              decoration: BoxDecoration(
                color: selected ? Ds.c.brandSoft : Ds.c.bg,
                borderRadius: Ds.r.rChip,
                border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(label,
                    style: Ds.t.caption
                        .copyWith(color: selected ? Ds.c.brand : Ds.c.text)),
                if (count.isNotEmpty) ...[
                  SizedBox(width: Ds.space.x8),
                  Text(count, style: Ds.t.caption),
                ],
              ]),
            ),
          ),
        ),
      );
}

/// The trail back up the tree. Every word in it is a value the backend sent —
/// the root's name is `home_label`, and each step is the class name itself.
class _Crumbs extends StatelessWidget {
  final CatBrowse browse;
  final List<String> path;
  final ValueChanged<int> onTap;
  const _Crumbs({required this.browse, required this.path, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x12, Ds.space.x16, 0),
        child: Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (browse.homeLabel.isNotEmpty)
              InkWell(
                onTap: () => onTap(0),
                child: Text(browse.homeLabel,
                    style: Ds.t.caption.copyWith(color: Ds.c.brand)),
              ),
            for (var i = 0; i < path.length; i++) ...[
              Icon(Icons.chevron_right,
                  size: Ds.t.captionSize, color: Ds.c.textSecondary),
              InkWell(
                onTap: () => onTap(i + 1),
                child: Text(path[i],
                    style: Ds.t.caption.copyWith(
                        color: i == path.length - 1 ? Ds.c.text : Ds.c.brand)),
              ),
            ],
          ],
        ),
      );
}

class _BrowseRow extends StatelessWidget {
  final CatRow row;
  final VoidCallback onTap;
  const _BrowseRow({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          color: Ds.c.surface,
          constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16, vertical: Ds.space.x12),
          child: Row(
            children: [
              Expanded(child: Text(row.label, style: Ds.t.body)),
              SizedBox(width: Ds.space.x12),
              Text(row.countLabel, style: Ds.t.caption),
              Icon(Icons.chevron_right, color: Ds.c.textSecondary),
            ],
          ),
        ),
      );
}

class _OpenProducts extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _OpenProducts({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: Ds.touch.minTarget,
        width: double.infinity,
        child: FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            backgroundColor: Ds.c.brand,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          child: Text(label),
        ),
      );
}

class _CatEmpty extends StatelessWidget {
  final String label;
  const _CatEmpty({required this.label});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: Center(child: Text(label, textAlign: TextAlign.center, style: Ds.t.bodySecondary)),
      );
}

/// CHANGE #799 — an empty scope names itself, says why it is empty, and offers
/// the two ways out: request the product, or clear the filters. Which of those
/// is offered is the payload's `has` flag, never a guess made here.
class _CatEmptyState extends StatelessWidget {
  final CatEmptyState empty;
  final VoidCallback onAction;
  final VoidCallback onClear;
  const _CatEmptyState({
    required this.empty,
    required this.onAction,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(empty.label,
                textAlign: TextAlign.center, style: Ds.t.bodyStrong),
            if (empty.hint.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(empty.hint, textAlign: TextAlign.center, style: Ds.t.caption),
            ],
            if (empty.action.has) ...[
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.touch.minTarget,
                width: double.infinity,
                child: FilledButton(
                  onPressed: onAction,
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.brand,
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  child: Text(empty.action.label),
                ),
              ),
            ],
            if (empty.clear.has) ...[
              SizedBox(height: Ds.space.x12),
              SizedBox(
                height: Ds.touch.minTarget,
                width: double.infinity,
                child: OutlinedButton(
                    onPressed: onClear, child: Text(empty.clear.label)),
              ),
            ],
          ],
        ),
      );
}

/// One more row of card skeletons while the next page lands. A skeleton, never
/// a spinner — the design QA gate's rule six, and the honest shape of what is
/// arriving.
class _MoreSkeleton extends StatelessWidget {
  const _MoreSkeleton();

  @override
  Widget build(BuildContext context) => SizedBox(
        height: CatalogueProductCard.extent,
        child: Row(
          children: [
            for (var i = 0; i < 2; i++) ...[
              if (i > 0) SizedBox(width: Ds.space.x12),
              const Expanded(child: CatalogueCardSkeleton()),
            ],
          ],
        ),
      );
}

class _Tail extends StatelessWidget {
  final bool loading;
  const _Tail({required this.loading});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: Ds.space.x48,
        child: Center(
          child: loading ? const CircularProgressIndicator(strokeWidth: 2) : null,
        ),
      );
}

/// A skeleton, not a bare spinner — the design QA gate's loading rule.
class _CatSkeleton extends StatelessWidget {
  const _CatSkeleton();

  @override
  Widget build(BuildContext context) => Container(
        color: Ds.c.bg,
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 8; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Container(
                  height: Ds.touch.listRowMinHeight,
                  decoration: BoxDecoration(
                    color: Ds.c.surface,
                    borderRadius: Ds.r.rCard,
                  ),
                ),
              ),
          ],
        ),
      );
}

/// The error state prints the BACKEND's copy plus Retry — never a Dart apology.
///
/// It used to be handed `e.toString()`, and on 4 Sep a cold anon visit painted
/// "PostgrestException(message: canceling statement due to statement timeout,
/// code: 57014, details: , hint: null)" across the middle of the catalogue.
/// The sentence is `catalogue.load_error` and the button is `catalogue.retry`;
/// the exception text is kept for the render log and never shown.
class _CatError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _CatError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (message.isNotEmpty) {
      RenderLog.write('c799_catalogue_error',
          message.length > 120 ? message.substring(0, 120) : message);
    }
    return Container(
      color: Ds.c.bg,
      padding: EdgeInsets.all(Ds.space.x24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(c('catalogue.load_error'),
                key: const Key('c799_catalogue_error_copy'),
                textAlign: TextAlign.center,
                style: Ds.t.bodySecondary),
            SizedBox(height: Ds.space.x16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(c('catalogue.retry')),
            ),
          ],
        ),
      ),
    );
  }
}
