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

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../data/medicine_repository.dart';
import '../models/catalogue.dart';
import '../models/product.dart';
import '../models/search_page.dart';
import '../services/ui_copy.dart';
import '../url_sync.dart';
import '../utils/render_log.dart';
import '../widgets/catalogue_alphabet_rail.dart';
import '../widgets/catalogue_landing.dart';
import '../widgets/catalogue_product_card.dart';
import '../widgets/product_row_card.dart';
import '../widgets/product_image.dart';
import '../widgets/search_surface.dart';
import 'catalogue_extras.dart'; // CHANGE #748

/// Test seam: production goes to Supabase, a test hands back a payload.
typedef CatalogueRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> args);

/// Where the catalogue currently is. One immutable value, so the URL, the
/// fetch and the back stack are three readings of the SAME thing rather than
/// three pieces of state that have to be kept in agreement.
class CatalogueRoute {
  /// 'home' (the four Browse-by tiles — the landing) | 'browse' (the class
  /// tree, behind the Category tile) | 'companies' | 'salts' | a tab key the
  /// backend sent.
  ///
  /// CMD #2011 — 'home' and 'browse' used to be the same route, which is why
  /// the class list opened preselected under the tiles and the A–Z strip that
  /// belongs to it was on the default view.
  final String tab;

  /// The browse trail: [] | [therapeutic] | [therapeutic, chemical].
  final List<String> path;

  /// Set when a product LIST is open: the scope the backend lists by.
  final String? listKind;
  final String? listKey;

  final CatFilterState filters;
  final String sort;
  final String query;

  /// CMD #1906 item 4 — THE search, and the same value Home carries.
  ///
  /// [query] narrows a browse LIST (a salt, a company, a class) and is the
  /// catalogue's own idea; this is the shopper's search, filters and page, in
  /// the parameter names `SearchQueryState.toParams` writes. `/?q=dolo&sort=name`
  /// and `/catalogue?q=dolo&sort=name` are therefore the same search on two
  /// screens: moving between them keeps it, and so does a reload or a link.
  final SearchQueryState search;

  /// CMD #1908 — the A–Z letter, or null for the whole list. It lives in the
  /// ROUTE and not in a field beside it, so the back button and a pasted link
  /// land on the same letter the strip was showing.
  final String? letter;

  const CatalogueRoute({
    this.tab = 'home',
    this.path = const [],
    this.listKind,
    this.listKey,
    this.filters = const CatFilterState(),
    this.sort = 'name',
    this.query = '',
    this.letter,
    this.search = SearchQueryState.blank,
  });

  bool get showsList => listKind != null;

  /// True when this route IS a search — the shared surface, not a browse list.
  bool get showsSearch => search.hasQuery;

  CatalogueRoute copy({
    String? tab,
    List<String>? path,
    Object? listKind = _keep,
    Object? listKey = _keep,
    CatFilterState? filters,
    String? sort,
    String? query,
    Object? letter = _keep,
    SearchQueryState? search,
  }) =>
      CatalogueRoute(
        tab: tab ?? this.tab,
        path: path ?? this.path,
        listKind: identical(listKind, _keep) ? this.listKind : listKind as String?,
        listKey: identical(listKey, _keep) ? this.listKey : listKey as String?,
        filters: filters ?? this.filters,
        sort: sort ?? this.sort,
        query: query ?? this.query,
        letter: identical(letter, _keep) ? this.letter : letter as String?,
        search: search ?? this.search,
      );

  static const Object _keep = Object();

  /// The URL this state is. Restoring is [parse]'s job and the two are
  /// deliberately adjacent: a link that cannot be read back is not a deep link.
  String get url {
    // CMD #1906 — a SEARCH serialises as the shared search state and nothing
    // else, so the string after `?` is byte-identical to the one Home writes.
    if (showsSearch) {
      final qs = search.toQueryString();
      return tab == 'home' ? '/catalogue?$qs' : '/catalogue?tab=$tab&$qs';
    }
    final q = <String>[];
    if (tab != 'home') q.add('tab=$tab');
    if (path.isNotEmpty) q.add('p=${path.map(Uri.encodeComponent).join('/')}');
    if (listKind != null) q.add('lk=$listKind');
    if (listKey != null) q.add('k=${Uri.encodeComponent(listKey!)}');
    if (sort != 'name') q.add('sort=$sort');
    if (query.isNotEmpty) q.add('q=${Uri.encodeComponent(query)}');
    if (letter != null) q.add('l=${Uri.encodeComponent(letter!)}');
    final f = filters.toQuery();
    if (f.isNotEmpty) q.add(f);
    return q.isEmpty ? '/catalogue' : '/catalogue?${q.join('&')}';
  }

  /// True for any URL this screen owns, so the shell's one route check stays
  /// one line no matter how many parameters the catalogue grows.
  static bool matches(String path) =>
      path == '/catalogue' || path.startsWith('/catalogue?') || path.startsWith('/catalogue/');

  static CatalogueRoute parse(String location) {
    final q = Uri.splitQueryString(
        location.startsWith('?') ? location.substring(1) : location);
    final raw = q['p'] ?? '';
    // CMD #1906 — `q=` with no list scope beside it is the SHARED search, read
    // back with the same reader Home uses. `q=` WITH a scope (`lk=salt&q=para`)
    // stays what it always was: a browse list narrowed by a word.
    final shared = q['q'] != null && q['lk'] == null
        ? SearchQueryState.fromParams(q)
        : SearchQueryState.blank;
    return CatalogueRoute(
      search: shared,
      tab: (q['tab'] ?? 'home'),
      path: raw.isEmpty
          ? const []
          : raw.split('/').where((s) => s.isNotEmpty).map(Uri.decodeComponent).toList(),
      listKind: q['lk'],
      listKey: q['k'] == null ? null : Uri.decodeComponent(q['k']!),
      filters: CatFilterState.fromQuery(q),
      // CMD #1909 — `zone=0` is read and DROPPED, not honoured: an old link
      // or a bookmark from when the switch existed still opens, it just opens
      // the whole list like every other link does now.
      sort: q['sort'] == 'newest' ? 'newest' : 'name',
      query: q['q'] == null ? '' : Uri.decodeComponent(q['q']!),
      letter: q['l'] == null ? null : Uri.decodeComponent(q['l']!),
    );
  }

  /// CMD #1908 — a breadcrumb tap. The crumb carries the four values this
  /// route is made of; applying it is a copy, never a computation.
  CatalogueRoute applyCrumb(CatCrumb c) => CatalogueRoute(
        tab: c.tab,
        path: c.path,
        listKind: c.listKind,
        listKey: c.listKey,
        filters: filters,
        sort: sort,
        query: '',
        letter: null,
        search: SearchQueryState.blank,
      );
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

  /// CMD #1906 item 4 — the shell's live search state. The Catalogue lives in
  /// an IndexedStack beside Home, so a shopper who searches on Home and taps
  /// Catalogue arrives with the search ALREADY in hand; [onSearchChanged]
  /// carries it back the other way. One value, two screens, one URL.
  final SearchQueryState shellSearch;
  final ValueChanged<SearchQueryState>? onSearchChanged;

  /// Test seam for the shared search RPC.
  final MedicineRepository? repo;

  /// CMD #1906 — a scope the SHARED header opened from another tab. The one
  /// search header lives on Home as well now, and a salt, a use or a class
  /// tapped there has to land on the screen that renders lists, which is this
  /// one. The shell writes the URL; this screen renders it.
  final CatalogueRoute? shellScope;

  const CatalogueScreen({
    super.key,
    this.active = false,
    this.rpc,
    this.initialRoute,
    this.shellSearch = SearchQueryState.blank,
    this.onSearchChanged,
    this.repo,
    this.shellScope,
  });

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

  // CMD #1908 — the breadcrumb and the letter strip are HEADER state: they
  // survive a reload, because a trail that blinks out while the next payload
  // is in flight is a trail that "disappeared after changing a filter".
  CatTrail _trail = CatTrail.empty;
  CatRail _rail = CatRail.empty;

  bool _booted = false;
  bool _loading = false;
  bool _loadingMore = false;
  String _error = '';

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  // CMD #1906 — the shared search surface's state. `search_page()` answers the
  // chips, the rows, the recent strip, the paging labels and the empty state in
  // ONE payload, which is why there is nothing else here.
  /// The shared search RPC, through this screen's OWN seam: a test that hands
  /// in [CatalogueScreen.rpc] gets a repository that answers from the same fake,
  /// so the header and the results need no second seam of their own.
  late final MedicineRepository _repo = widget.repo ??
      MedicineRepository(
        null,
        widget.rpc == null
            ? null
            : (fn, {params}) => widget.rpc!(fn, params ?? const {}),
      );
  SearchPagePayload? _searchPayload;
  bool _searchLoadingMore = false;
  bool _searchFailed = false;

  // CMD #1905's chip moved into SearchChrome with CMD #1906: the box that
  // shows it is the shared one now, so the state belongs with the box rather
  // than being kept a second time here.

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
    // The shell's search wins over the URL only when the URL carried none:
    // a pasted `/catalogue?q=…` is the more specific instruction.
    if (!_route.showsSearch && widget.shellSearch.hasQuery) {
      _route = _route.copy(search: widget.shellSearch, query: widget.shellSearch.query);
    }
    _searchCtrl.text = _route.query;
    _scroll.addListener(_onScroll);
    if (widget.active) _boot();
  }

  @override
  void didUpdateWidget(covariant CatalogueScreen old) {
    super.didUpdateWidget(old);
    // First time the tab is actually opened — not at shell boot.
    if (widget.active && !old.active && !_booted) _boot();
    // CMD #1906 — Home changed the search while this tab was in the stack.
    // Adopting it here is what makes "move between the two screens" keep it.
    if (widget.shellSearch.toQueryString() != old.shellSearch.toQueryString() &&
        widget.shellSearch.toQueryString() != _route.search.toQueryString()) {
      _adoptSearch(widget.shellSearch, report: false, push: widget.active);
    }
    // CMD #1905/#1910 — a suggestion tapped in the header while Home was the
    // visible tab. The shell has already pushed the URL, so this only renders
    // the scope it names.
    final scope = widget.shellScope;
    if (scope != null && !identical(scope, old.shellScope)) {
      // CMD #2021 — the shell hands a scope over on a Catalogue TAB tap too,
      // and a tab is a root: land at the top of it every time, even when the
      // route it names is the one already showing.
      _go(scope, push: false, resetScroll: true);
    }
  }

  /// One entry point for every search change on this screen: the route moves,
  /// the URL moves with it, the shell is told, and the payload is refetched.
  void _adoptSearch(SearchQueryState next,
      {bool report = true, bool push = true, bool replace = false}) {
    _go(
      _route.copy(
        search: next,
        query: next.query,
        // CMD #2011 — clearing a search lands on the LANDING (the tiles), the
        // same place the root crumb goes. 'browse' is the class tree now.
        tab: 'home',
        path: const [],
        listKind: null,
        listKey: null,
        letter: null,
      ),
      push: push,
      replace: replace,
    );
    if (report) widget.onSearchChanged?.call(next);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
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
      final home = CatHome.fromMap(await _call('catalogue_home', const {}));
      if (!mounted) return;
      setState(() => _home = home);
      // CHANGE #748 — best-effort: the three extras must never be able to stop
      // the catalogue itself from booting.
      try {
        final ex = await _call('catalogue_extras', const {});
        if (mounted) setState(() => _extras = ex);
      } catch (_) {}
      RenderLog.write('c747_catalogue_tabs',
          '${home.tabs.map((t) => t.key).join('>')};'
          'zone=${home.zone.has ? 'switch' : 'none'}');
      await _fetch();
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  /// Load whatever the current route points at. Every navigation in this screen
  /// is "change the route, then call this" — there is no second code path.
  Future<void> _fetch() async {
    // CMD #1906 — a search is not a browse list. It is `search_page()`, the
    // same call Home makes, rendered by the same widgets.
    if (_route.showsSearch) return _loadSearch();
    // CMD #2011 — the LANDING has no list to fetch. Clearing the rail here is
    // the whole of "the A–Z strip goes away when you come back": it belongs to
    // the list that sent it, so leaving the last one standing would put a
    // company's alphabet over the tiles.
    if (_isLandingOnly) {
      setState(() {
        _loading = false;
        _error = '';
        _rail = CatRail.empty;
        _browse = null;
        _rows.clear();
        _rowsHaveMore = false;
        // CMD #2020 — the landing's trail is taken WHOLE, empty included. The
        // old guard kept the last list's crumb standing when the landing sent
        // none, which is exactly "the breadcrumb did not go away when I came
        // back". `catalogue_home()` now sends no steps at all, and that
        // absence is the instruction.
        _trail = _home?.trail ?? CatTrail.empty;
      });
      RenderLog.write('c2011_catalogue_landing',
          'doors=${_home?.doors.length ?? 0};tree=${_home?.showTree ?? false};'
          'rail=0');
      RenderLog.write('c2020_catalogue_landing',
          'tiles=${_home?.doors.length ?? 0};'
          'previews=${_home?.doors.where((d) => !d.preview.isEmpty).length ?? 0};'
          'top=${_home?.topSelling.items.length ?? 0};'
          'promo=${(_home?.promo.has ?? false) ? 1 : 0};'
          'chips=${_home?.chips.length ?? 0};'
          'crumbs=${_home?.trail.items.length ?? 0}');
      return;
    }
    setState(() { _loading = true; _error = ''; });
    try {
      if (_route.showsList) {
        final p = await _call('catalogue_list', {
          'p_kind': _route.listKind,
          'p_key': _route.listKey,
          'p_path': _route.path,
          'p_filters': _route.filters.toRpc(),
          'p_sort': _route.sort,
          // CMD #2020 — the A–Z strip narrows a PRODUCT list too, and the
          // letter is part of the route, so it round-trips through the URL and
          // the back button the same way a company key does.
          'p_letter': _route.letter,
          'p_cursor': null,
          'p_limit': _pageSize,
        });
        if (!mounted) return;
        final list = CatList.fromMap(p);
        setState(() {
          _list = list;
          _cursor = list.nextCursor;
          if (!list.trail.isEmpty) _trail = list.trail;
          // CMD #2020 — the strip a product list sends is the strip it gets.
          // A search sends none and still clears the last one.
          _rail = list.rail;
          _loading = false;
        });
        RenderLog.write('c747_catalogue_list',
            '${_route.listKind}:${_route.listKey ?? _route.path.join('/')};'
            'items=${list.rows.length};more=${list.hasMore};filters=${list.filtersActive};'
            'grouped=${list.grouped};'
            'dividers=${list.rows.where((r) => r.dividerLabel.isNotEmpty).length}');
      } else {
        final fn = switch (_route.tab) {
          'companies' => 'catalogue_companies',
          'salts' => 'catalogue_salts',
          // CMD #1910 — the fourth door. Same payload shape as companies and
          // salts, so everything below this line is unchanged.
          'conditions' => 'catalogue_conditions',
          _ => 'catalogue_tree',
        };
        // CMD #1908 — companies, salts and classes all take the same letter,
        // because they all draw the same strip.
        final args = switch (_route.tab) {
          'companies' => {
              'p_letter': _route.query.isEmpty ? _route.letter : null,
              'p_q': _route.query.isEmpty ? null : _route.query,
              'p_offset': 0, 'p_limit': _rowPage,
            },
          'salts' => {
              'p_letter': _route.query.isEmpty ? _route.letter : null,
              'p_q': _route.query.isEmpty ? null : _route.query,
              'p_offset': 0, 'p_limit': _rowPage,
            },
          'conditions' => {
              'p_letter': _route.query.isEmpty ? _route.letter : null,
              'p_q': _route.query.isEmpty ? null : _route.query,
              'p_offset': 0, 'p_limit': _rowPage,
            },
          _ => {
              'p_path': _route.path,
              'p_letter': _route.letter,
            },
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
          if (!b.trail.isEmpty) _trail = b.trail;
          _rail = b.rail;
          _loading = false;
        });
        RenderLog.write('c747_catalogue_browse',
            '${_route.tab};depth=${_route.path.length};rows=${b.rows.length};more=${b.hasMore}');
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  // CMD #1903 — `catalogue_variants` is no longer called from here. The pack
  // family was a chip row on every card in every list; it is now the "Other
  // packs" strip on the PRODUCT PAGE, which is the one place a buyer is
  // choosing between packs rather than scanning for one.

  /// CMD #2010 — [replace] is what live typing uses: the URL still follows the
  /// search, but a five-letter word leaves ONE history entry rather than four
  /// the Back button has to be pressed through.
  void _go(CatalogueRoute next,
      {bool push = true, bool replace = false, bool? resetScroll}) {
    // CMD #2021 — a new PLACE starts at the top.
    //
    // Every _go clears `_rows` and refetches, so the offset the shopper left
    // belonged to a list that no longer exists; keeping it is how tapping the
    // Catalogue tab from deep inside a salt list "returned to the landing" at
    // row 60 of a list that had been replaced. Only a change of PLACE counts —
    // tab, trail, open list, A–Z letter — so a keystroke in the search box
    // does not yank the grid out from under a thumb that is still scrolling
    // (CMD #2010 keeps those rows on screen on purpose). The caller may say so
    // outright, which is what the Catalogue tab does: re-tapping the tab you
    // are already on scrolls to the top, exactly as re-tapping Home does.
    final movedPlace = next.tab != _route.tab ||
        next.listKind != _route.listKind ||
        next.listKey != _route.listKey ||
        next.letter != _route.letter ||
        !listEquals(next.path, _route.path);
    setState(() {
      _route = next;
      // CMD #2026 — THE multi-word bug, and it lived on this line.
      //
      // The query is the TRIMMED text ('telmed' for "telmed "), so the moment a
      // shopper typed the space after the first word this comparison was true
      // and the box was rewritten WITHOUT that space — and `.text =` collapses
      // the selection, so the caret landed back at the start of the word. The
      // next letter went in front of the first word instead of after it, which
      // is exactly "typing a second word drops the first".
      //
      // The box is the shopper's. Sync it only when the search came from
      // somewhere ELSE (a URL, back/forward, a category, a scan, a voice
      // result) — i.e. when the text does not already SAY this query — and when
      // syncing, put the caret after the text instead of at position zero.
      final sync = searchBoxSync(_searchCtrl.value, next.query);
      if (sync != null) _searchCtrl.value = sync;
      _rows.clear();
      _cursor = null;
      _list = null;
      _browse = null;
      _searchLoadingMore = false;
      _searchFailed = false;
      // CMD #2010 — the rows are cleared only when the SEARCH is over. While
      // the shopper is still typing the previous answer stays under the box
      // and is replaced when the next one lands: one grid, filtering, rather
      // than a skeleton flashing on every keystroke.
      if (next.search.page == 0 && !next.search.hasQuery) _searchPayload = null;
    });
    if (push) {
      pushUrl(next.url);
    } else if (replace) {
      replaceUrl(next.url);
    }
    if (resetScroll ?? movedPlace) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients && _scroll.offset != 0) {
          _scroll.jumpTo(0);
        }
      });
    }
    _fetch();
  }

  /// CMD #1906 — THE search, and the same RPC Home calls. Everything drawn
  /// afterwards — the chip row, the header line, the rows, the paging labels,
  /// the empty state — is this one payload.
  Future<void> _loadSearch() async {
    final asked = _route.search.toQueryString();
    setState(() { _loading = true; _error = ''; _searchFailed = false; });
    try {
      final p = await _repo.searchPage(_route.search);
      if (!mounted || _route.search.toQueryString() != asked) return;
      setState(() { _searchPayload = p; _loading = false; });
      RenderLog.write(
        'c1906_search_page',
        'q=${_route.search.query};rows=${p.items.length};total=${p.total};'
        'filters=${p.filtersActive};groups=${p.filters.groups.length};'
        'rail=${p.rail.has ? p.rail.kind : 'none'};'
        'more=${p.paging.hasMore};surface=catalogue',
      );
    } catch (e) {
      if (!mounted || _route.search.toQueryString() != asked) return;
      setState(() { _loading = false; _searchFailed = true; _error = e.toString(); });
    }
  }

  /// The next page of the SAME search. The later payload wins for every label
  /// and count, because the backend recomputed them for the page it answered.
  Future<void> _moreSearch() async {
    final current = _searchPayload;
    if (current == null || _searchLoadingMore || !current.paging.hasMore) return;
    final asked = _route.search.toQueryString();
    setState(() => _searchLoadingMore = true);
    try {
      final next = await _repo
          .searchPage(_route.search.copy(page: current.paging.nextPage));
      if (!mounted || _route.search.toQueryString() != asked) return;
      setState(() {
        _searchPayload = current.appended(next);
        _searchLoadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _searchLoadingMore = false);
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 600) return;
    if (_route.showsSearch) {
      if (_searchPayload?.paging.hasMore == true) _moreSearch();
    } else if (_route.showsList) {
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
        'p_letter': _route.letter,
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
          empty: cur.empty, trail: cur.trail,
          rail: cur.rail, letter: cur.letter,
          // The groups come back on every page — the counts are the SCOPE's,
          // not the page's, so the later payload is as good as the first and
          // taking it keeps a changed count honest.
          grouped: p.grouped, groups: p.groups,
          rows: [...cur.rows, ...p.rows],
          // Paging stops when the BACKEND says so, never when a page comes back
          // short — that is wrong on an exact boundary.
          hasMore: p.hasMore, nextCursor: p.nextCursor,
        );
        _cursor = p.nextCursor;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _moreRows() async {
    setState(() => _loadingMore = true);
    try {
      final fn = switch (_route.tab) {
        'companies' => 'catalogue_companies',
        'conditions' => 'catalogue_conditions',
        _ => 'catalogue_salts',
      };
      final args = {
        'p_letter': _route.query.isEmpty ? _route.letter : null,
        'p_q': _route.query.isEmpty ? null : _route.query,
        'p_offset': _nextOffset, 'p_limit': _rowPage,
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
    if (t.kind == 'list') {
      _go(_route.copy(tab: t.key, path: const [], listKind: t.listKind,
          listKey: t.listKey, query: '', letter: null));
    } else {
      _go(_route.copy(tab: t.key, path: const [], listKind: null,
          listKey: null, query: '', letter: null));
    }
  }

  /// A door opens ITS list — the tab the backend named on the door — with the
  /// A–Z strip and the breadcrumb that list sends. Nothing is decided here.
  /// CMD #2020 — the promo banner opens the list the PAYLOAD named. The word
  /// "schemes" is nowhere in this method: `list_kind` / `list_key` arrived as
  /// data and are copied into the route, exactly as a crumb is.
  void _tapPromo(CatPromo p) {
    if (!p.has) return;
    _go(_route.copy(
      tab: p.key,
      path: const [],
      listKind: p.listKind,
      listKey: p.listKey,
      query: '',
      letter: null,
    ));
  }

  void _tapDoor(CatDoor d) => _go(_route.copy(
        tab: d.tab,
        path: const [],
        listKind: null,
        listKey: null,
        query: '',
        letter: null,
      ));

  void _tapRow(CatRow r) {
    switch (_route.tab) {
      case 'companies':
        _go(_route.copy(listKind: 'company', listKey: r.key));
      case 'salts':
        _go(_route.copy(listKind: 'salt', listKey: r.key));
      case 'conditions':
        _go(_route.copy(listKind: 'condition', listKey: r.key));
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

  // ── build ─────────────────────────────────────────────────────────────────

  /// The catalogue's own front page: the four Browse-by tiles and nothing
  /// that belongs to a chosen list. CMD #2011 gave it its own tab key, because
  /// sharing 'browse' with the class tree is what made the tree open
  /// preselected underneath the tiles — and dragged the tree's A–Z strip onto
  /// the default view with it.
  bool get _isHome =>
      !_route.showsList && !_route.showsSearch && _route.tab == 'home' && _route.path.isEmpty;

  /// The landing WITHOUT a list under it. `show_tree` is the backend's
  /// (app_settings.catalogue_landing): false — the shipped answer — makes the
  /// tiles the whole page, and turning it back on restores the old front page
  /// with one UPDATE and no deploy.
  bool get _isLandingOnly => _isHome && !(_home?.showTree ?? false);

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
          // 1. CMD #1906 — THE search header, the very widget Home mounts:
          //    one field, the backend's filter chips in the backend's order,
          //    and — focused with nothing typed — the backend's idle rail.
          //    There is no second search box in this app any more.
          SearchChrome(
            surface: 'catalogue',
            controller: _searchCtrl,
            focusNode: _searchFocus,
            payload: _searchPayload,
            hasQuery: _route.showsSearch,
            isLoading: _route.showsSearch && _loading,
            repo: _repo,
            // CMD #2010 — this fires on the debounced keystroke as well as on
            // Enter, so the grid below IS the answer to what is in the box.
            // The URL is REPLACED rather than pushed while typing.
            onSubmit: (q) {
              final t = q.trim();
              if (t.isEmpty) {
                _adoptSearch(SearchQueryState.blank);
                return;
              }
              // The filters the shopper already set survive a new query —
              // they narrowed the catalogue, not that one word.
              _adoptSearch(_route.search.copy(query: t, page: 0),
                  push: false, replace: true);
            },
            onFilterPick: (g, o) =>
                _adoptSearch(_route.search.withOption(g, o)),
            onClear: () => _adoptSearch(SearchQueryState.blank),
          ),
          // 2. CMD #1908 — the breadcrumb. Sticky under the search on EVERY
          //    browse state of this tab, outside the scroll view, so it cannot
          //    scroll away, and held across a reload so it cannot blink out
          //    while the next payload is in flight. A SEARCH has no trail:
          //    its only narrowing is the chip row the header already drew.
          if (!_route.showsSearch)
            _TrailBar(
              trail: _trail,
              onTap: (c) => _go(_route.applyCrumb(c)),
            ),
          // 3. The A–Z strip, directly under the breadcrumb. The backend sends
          //    a rail on the company, salt and class lists and none on a
          //    product grid, so there is nothing here to decide.
          if (!_rail.isEmpty && !_route.showsSearch)
            CatalogueAlphabetRail(
              rail: _rail,
              active: _route.letter,
              onPick: (l) => _go(_route.copy(letter: l, query: '')),
            ),
          // 4. CMD #2011 — the narrowing sentence ("Showing everything ·
          //    Bottle · Piece · Strip · Rx only") used to sit here. It is
          //    gone, backend and all: `catalogue_sentence()` is dropped and no
          //    payload carries a `sentence` key. Filtering inside a product
          //    list is the toolbar below, which has its own chips.
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
    // CMD #1906 — the shared result surface. The same rows, the same header
    // line, the same Load more and the same empty state Home draws, because it
    // is the same widget reading the same payload.
    if (_route.showsSearch) return _searchBody();
    // CHANGE #748 — the Recently-added tab is its own body, fetched by its own
    // RPC. It is reached the same way every other tab is: the backend put a tab
    // in the strip whose `kind` this build knows.
    if (_route.tab == 'recent') return const CatalogueRecent();
    // CMD #2011 — the landing. Four tiles, and nothing that belongs to a list
    // the shopper has not chosen yet.
    if (_isLandingOnly) return _landingBody();
    if (_loading) return const _CatSkeleton();
    if (_error.isNotEmpty) return _CatError(message: _error, onRetry: _fetch);
    return _route.showsList ? _productGrid() : _rowList();
  }

  Widget _searchBody() {
    final p = _searchPayload;
    if (p == null && _loading) return const SearchResultsSkeleton();
    if (p == null || (_searchFailed && !p.ok)) {
      return _CatError(message: _error, onRetry: _loadSearch);
    }
    return SingleChildScrollView(
      controller: _scroll,
      child: SearchResultsView(
        surface: 'catalogue',
        payload: p,
        loadingMore: _searchLoadingMore,
        onOpenProduct: (id) => Navigator.of(context).pushNamed('/product/$id'),
        onLoadMore: _moreSearch,
        onEmptyAction: _onSearchEmptyAction,
      ),
    );
  }

  /// CMD #1906 — the empty state's buttons are the backend's, and so is what
  /// they do: `clear_filters` clears exactly what the shopper narrowed, and
  /// `request` opens the request sheet `catalogue_extras()` configured — the
  /// same two behaviours Home gives the same two buttons. Anything else the
  /// backend sends in a later release is ignored rather than guessed at.
  void _onSearchEmptyAction(String kind) {
    if (kind == 'clear_filters') {
      _adoptSearch(_route.search.cleared());
      return;
    }
    if (kind == 'request') _openRequest();
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
        title: _peek('title'),
        openLabel: _peek('open_label'),
        onOpen: () {
          Navigator.of(context).pop();
          Navigator.of(context).pushNamed('/product/${p.id}');
        },
      ),
    );
  }

  /// CMD #2011 — the landing: the Browse-by tiles, the quiet tab chips and
  /// the recently-viewed strip, each one the backend's to show or withhold.
  /// No breadcrumb of its own (the header above draws it), no A–Z strip (it
  /// belongs to a chosen list) and no class list (that is the Category tile).
  Widget _landingBody() {
    final home = _home;
    if (home == null) return const _CatSkeleton();
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        if (home.showRecent && home.hasRecentViewed)
          SliverToBoxAdapter(
            child: _RecentStrip(
              title: home.recentViewedTitle,
              items: home.recentViewed,
              onTap: (p) => Navigator.of(context).pushNamed('/product/${p.id}'),
            ),
          ),
        // CMD #2020 — four rounded gradient tiles, each carrying its own
        // preview. The whole tile is a payload: colours, words, previews and
        // the route it opens.
        if (home.doors.isNotEmpty)
          SliverToBoxAdapter(
            child: CatalogueTiles(
              title: home.doorsTitle,
              doors: home.doors,
              onTap: _tapDoor,
            ),
          ),
        // CMD #2020 — the top-selling rail, ranked by the zone's own 30-day
        // order quantity. The card is the storefront's, unchanged.
        SliverToBoxAdapter(
          child: CatalogueTopSellingRail(
            block: home.topSelling,
            onTap: (p) => Navigator.of(context).pushNamed('/product/${p.id}'),
          ),
        ),
        // CMD #2020 — Schemes, as the one promotional block this page has.
        // `has` is the whole visibility rule.
        SliverToBoxAdapter(
          child: CataloguePromoBanner(
            promo: home.promo,
            onTap: () => _tapPromo(home.promo),
          ),
        ),
        // Cold chain stays a chip, under the banner.
        if (home.showTabs) SliverToBoxAdapter(child: _chipRow()),
        SliverToBoxAdapter(child: SizedBox(height: Ds.space.x24)),
      ],
    );
  }

  Widget _rowList() {
    final b = _browse;
    if (b == null) return const _CatSkeleton();

    final list = CustomScrollView(
      controller: _scroll,
      slivers: [
        // The front page with `show_tree` on: the same blocks, above the tree.
        if (_isHome && (_home?.showRecent ?? true) && (_home?.hasRecentViewed ?? false))
          SliverToBoxAdapter(
            child: _RecentStrip(
              title: _home!.recentViewedTitle,
              items: _home!.recentViewed,
              onTap: (p) => Navigator.of(context).pushNamed('/product/${p.id}'),
            ),
          ),
        if (_isHome && (_home?.doors.isNotEmpty ?? false))
          SliverToBoxAdapter(
            child: CatalogueTiles(
              title: _home!.doorsTitle,
              doors: _home!.doors,
              onTap: _tapDoor,
            ),
          ),
        if (_isHome && (_home?.showTabs ?? true))
          SliverToBoxAdapter(child: _chipRow()),
        // CMD #1909 — the zone SWITCH used to sit here. Nothing replaces it:
        // a catalogue list hides nothing any more, so there is no setting to
        // offer. What was a filter is now the order the list arrives in, and
        // the divider rows inside the list say so in the backend's words.
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

    // CMD #1908 — nothing rides over the rows any more. The A–Z index is the
    // horizontal strip in the header, above this scroll view, where it is the
    // same component on companies, salts and classes.
    return list;
  }

  /// CMD #2020 — the chip row under the promo banner.
  ///
  /// The BACKEND now names the chips (`catalogue_home().chips`): Schemes left
  /// this row to become the banner above it, and Cold chain stayed. The old
  /// behaviour — every `kind:'list'` tab drawn as a chip — is the fallback for
  /// a payload from before this change, so an app that meets the old RPC still
  /// draws exactly what it drew before.
  Widget _chipRow() {
    final home = _home;
    if (home == null) return const SizedBox.shrink();
    const known = {'list', 'recent'};
    final tabs = home.chips.isNotEmpty
        ? [...home.chips]
        : home.tabs.where((t) => known.contains(t.kind)).toList();
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
    if (l.rows.isEmpty) {
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
    // CMD #1903 — a product LIST, one row per product, and the same
    // [ProductRowCard] the search results draw. It is a sliver list, so only
    // the rows on screen are built and a 5.6-lakh scope costs the same as a
    // 24-row one on a low-end phone.
    return CustomScrollView(
        controller: _scroll,
        slivers: [
          // CMD #2020 — the title / subtitle / count block that used to sit
          // here is GONE. "Catalogue › Company › SUN PHARMA" is already
          // pinned two rows above it, so printing "SUN PHARMA" again, with
          // "Products from this company" under it, was the same scope said
          // three times before a single product. The breadcrumb is the title.
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                // CMD #1909 — the divider is drawn from the ROW's own
                // `divider_label`, so it costs no lookahead, no grouping pass
                // and no comparison between pages. An empty label is simply a
                // row with no header above it.
                (context, i) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (l.rows[i].dividerLabel.isNotEmpty)
                      _GroupDivider(label: l.rows[i].dividerLabel, first: i == 0),
                    Padding(
                      padding: EdgeInsets.only(bottom: Ds.space.x12),
                      child: ProductRowCard(
                        product: l.rows[i].product,
                        addedLabel: _addedLabel,
                        undoLabel: _undoLabel,
                        onTap: () => Navigator.of(context)
                            .pushNamed('/product/${l.rows[i].product.id}'),
                        onPeek: () => _openPeek(l.rows[i].product),
                      ),
                    ),
                  ],
                ),
                childCount: l.rows.length,
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

/// CMD #1909 — the grey rule that names an availability group.
///
/// It prints ONE string and decides nothing: the label already carries its own
/// count, because a count assembled here ("Available in your zone" + " (" + n)
/// would be this widget writing a sentence.
///
/// The rule sits ABOVE the label, and only when there is something above to
/// separate from — [first] is the top of the whole list, not the top of a
/// page, so an appended page never draws a stray line under nothing. The label
/// is a left-aligned caption on its own line rather than centred between two
/// rules: "Not available in your zone (2,95,412)" is 34 characters, and
/// squeezed between two Expanded dividers on a 360 px phone it overflowed by
/// 50 px — a header that hides the number it exists to show.
class _GroupDivider extends StatelessWidget {
  final String label;
  final bool first;
  const _GroupDivider({required this.label, required this.first});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(
            top: first ? 0 : Ds.space.x24, bottom: Ds.space.x12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!first) ...[
              Divider(height: 1, color: Ds.c.divider),
              SizedBox(height: Ds.space.x16),
            ],
            Text(label, style: Ds.t.caption, textAlign: TextAlign.left),
          ],
        ),
      );
}

// CMD #2020 — the four Browse-by tiles moved to widgets/catalogue_landing.dart
// (CatalogueTiles) when they became gradient cards with their own previews.
// The screen keeps the state machine; the tile keeps the paint.

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

/// CMD #1908 — the breadcrumb, sticky under the search bar.
///
/// "Catalogue › Company › SUN PHARMA". Every word and every separator is a
/// value `catalogue_trail()` sent, and every step carries the route it goes
/// back to, so this widget neither writes a word nor works out a destination.
/// It scrolls sideways rather than wrapping: a trail that grows to two lines
/// pushes the list down by a row every time you go one level deeper.
class _TrailBar extends StatelessWidget {
  final CatTrail trail;
  final ValueChanged<CatCrumb> onTap;
  const _TrailBar({required this.trail, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (trail.isEmpty) return const SizedBox.shrink();
    final pad = Ds.space.x16;
    return Container(
      color: Ds.c.surface,
      child: Semantics(
        label: trail.label,
        child: SizedBox(
          height: Ds.touch.minTarget,
          // A trail reads left to right, so it is LEFT-aligned whenever it
          // fits — the min-width box is what stops `reverse` from pinning a
          // short trail to the right edge. Only once the trail OVERFLOWS does
          // `reverse` matter, and then it keeps the step you are on in view.
          child: LayoutBuilder(
            builder: (context, c) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    minWidth: (c.maxWidth - pad * 2).clamp(0.0, double.infinity)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    for (var i = 0; i < trail.items.length; i++) ...[
                      if (i > 0 && trail.separator.isNotEmpty)
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
                          child: Text(trail.separator,
                              style: Ds.t.caption
                                  .copyWith(color: Ds.c.textSecondary)),
                        ),
                      InkWell(
                        onTap: () => onTap(trail.items[i]),
                        borderRadius: Ds.r.rChip,
                        child: Container(
                          constraints:
                              BoxConstraints(minHeight: Ds.touch.minTarget),
                          padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
                          alignment: Alignment.center,
                          child: Text(
                            trail.items[i].label,
                            style: Ds.t.caption.copyWith(
                                color: trail.items[i].current
                                    ? Ds.c.text
                                    : Ds.c.brand),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
/// the ways out. WHICH ones, in WHICH order and how loudly are all the
/// payload's `buttons`, never a guess made here — CMD #1905 moved "Clear
/// filters" ahead of "Request this product" when filters are on, and that is
/// a backend edit, not a layout one.
class _CatEmptyState extends StatelessWidget {
  final CatEmptyState empty;
  final VoidCallback onAction;
  final VoidCallback onClear;
  const _CatEmptyState({
    required this.empty,
    required this.onAction,
    required this.onClear,
  });

  /// The button's `kind` is the backend's word for what it does. Two kinds
  /// exist; an unknown one is drawn and does nothing rather than guessing.
  VoidCallback? _onTap(String kind) => switch (kind) {
        'request' => onAction,
        'clear_filters' => onClear,
        _ => null,
      };

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
            for (var i = 0; i < empty.buttons.length; i++) ...[
              SizedBox(height: i == 0 ? Ds.space.x24 : Ds.space.x12),
              SizedBox(
                height: Ds.touch.minTarget,
                width: double.infinity,
                child: empty.buttons[i].tone == 'primary'
                    ? FilledButton(
                        onPressed: _onTap(empty.buttons[i].kind),
                        style: FilledButton.styleFrom(
                          backgroundColor: Ds.c.brand,
                          shape: RoundedRectangleBorder(
                              borderRadius: Ds.r.rButton),
                        ),
                        child: Text(empty.buttons[i].label),
                      )
                    : OutlinedButton(
                        onPressed: _onTap(empty.buttons[i].kind),
                        child: Text(empty.buttons[i].label)),
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
        height: ProductRowCard.extent,
        child: const CatalogueCardSkeleton(),
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
