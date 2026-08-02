import 'dart:async';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:js' as js;
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../app_state.dart'; // CHANGE #454
import '../data/medicine_repository.dart';
import '../models/product.dart';
import '../theme.dart';
import '../util.dart';
import '../utils/render_log.dart';
import '../widgets/animations.dart';
import '../widgets/compact_product_card.dart';

const double _kMaxContent = 1200;

/// The mediBO storefront: hero, dynamic category tiles, an infinite-scroll
/// product grid, trust badges and footer.
///
/// Categories + counts come live from [MedicineRepository.fetchCatalogMeta];
/// products load [MedicineRepository.pageSize] at a time and keep paging in as
/// the user scrolls. Search/category filter state lives in the shell and is
/// passed down — changing either resets the grid to page one.
class StorefrontScreen extends StatefulWidget {
  final String query;
  final String category;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<String> onSuggestionTap;
  final MedicineRepository repo;
  // Incremented by the parent on explicit search submit (button / Enter).
  // StorefrontScreen scrolls to the results section whenever this changes.
  final int scrollTrigger;
  // Incremented when the search is cleared or drops below 2 chars.
  // StorefrontScreen smoothly scrolls back to the top whenever this changes.
  final int scrollToTopTrigger;
  // Called with true when a load starts, false when it completes or errors.
  final ValueChanged<bool>? onLoadingChanged;

  // When false (desktop), the category tile grid is hidden; the shell sidebar
  // handles category filtering instead.
  final bool showCategoryTiles;
  // Called once after CatalogMeta loads so the shell can populate its sidebar.
  final ValueChanged<CatalogMeta>? onMetaLoaded;

  // Footer navigation callbacks.
  final VoidCallback? onFooterSearch;
  final VoidCallback? onFooterBulkUpload;
  final VoidCallback? onFooterOrders;
  final VoidCallback? onFooterCart;

  const StorefrontScreen({
    super.key,
    required this.query,
    required this.category,
    required this.onCategorySelected,
    required this.onSuggestionTap,
    required this.repo,
    this.scrollTrigger = 0,
    this.scrollToTopTrigger = 0,
    this.onLoadingChanged,
    this.showCategoryTiles = true,
    this.onMetaLoaded,
    this.onFooterSearch,
    this.onFooterBulkUpload,
    this.onFooterOrders,
    this.onFooterCart,
  });

  @override
  State<StorefrontScreen> createState() => _StorefrontScreenState();
}

class _StorefrontScreenState extends State<StorefrontScreen> {
  // Web uses a plain controller — no ballistic momentum after wheel events.
  // Mobile uses MomentumScrollController for touch-fling deceleration.
  late final ScrollController _scroll =
      kIsWeb ? ScrollController() : MomentumScrollController();
  final GlobalKey _productsKey = GlobalKey();

  // Keyboard scroll (desktop web only)
  final FocusNode _focusNode = FocusNode();
  static bool _scrollbarCssInjected = false;

  // Category metadata (tiles + counts).
  CatalogMeta? _meta;
  Object? _metaError;
  bool _metaNetworkError = false;

  // Paginated product list for the current filter.
  final List<Product> _items = [];
  int _loadToken = 0; // invalidates in-flight requests on filter change
  bool _loadingFirst = true;
  bool _loadingMore = false;
  bool _reachedEnd = false;
  Object? _pageError;
  bool _pageNetworkError = false;
  List<String> _suggestions = [];

  // Buyable-only category total from get_storefront_count (real total, not capped at 200).
  int? _buyableCategoryTotal;

  // CHANGE #553 — the counter and the no-results line are RENDERED BY THE
  // BACKEND (storefront_page.showing_label / storefront_search_page's
  // showing_label + empty_label) and printed verbatim. The client never counts
  // its own list to build them — doing that produced the old
  // "Showing 0 of 32133". Null only on the outage fallback, which prints
  // nothing rather than a number it made up.
  String? _showingLabel;
  String? _emptyLabel;

  // CHANGE #441: every category's buyable count, fetched once at storefront
  // load via get_all_storefront_counts and read on every category switch —
  // keys are uppercased category names plus 'ALL'.
  Map<String, int> _categoryCounts = {};
  final Set<String> _countFallbackInFlight = {};

  // Browse feed cap: true once loadedCount>=200 or a page returned <20 rows.
  bool _feedEnded = false;

  @override
  void initState() {
    super.initState();
    _loadMeta();
    _loadAllCounts();
    _resetAndLoad();
    _injectScrollbarCss();
  }

  Future<void> _loadAllCounts() async {
    // CHANGE #497: cache-first + retry, same treatment as categories (B5) —
    // render cached counts immediately, refresh in the background.
    final cached =
        widget.repo.cachedCategoryCounts ?? await widget.repo.loadCachedCategoryCounts();
    if (cached != null && mounted) {
      setState(() => _categoryCounts = cached);
    }
    final fresh = await retryWithBackoff<Map<String, int>>(
      () => widget.repo.fetchAllCategoryCounts(),
    );
    if (fresh != null && mounted) {
      setState(() => _categoryCounts = fresh);
      RenderLog.write('c441_counts', 'cached=${_categoryCounts.length}');
    }
    // On total failure, keep whatever's already showing (cache or empty) —
    // _countFor() also falls back to a live per-category fetch below.
  }

  /// Instant count for [cat] from the bulk cache. Falls back to a one-off
  /// live fetch only while the bulk cache hasn't loaded yet (e.g. cold start
  /// before [_loadAllCounts] resolves) — never shows a loading state.
  int _countFor(String cat) {
    final key = cat.toUpperCase();
    final cached = _categoryCounts[key] ?? _categoryCounts['ALL'];
    if (cached != null) return cached;
    _ensureCountFallback(cat);
    return _buyableCategoryTotal ?? 0;
  }

  void _ensureCountFallback(String cat) {
    if (_categoryCounts.isNotEmpty) return; // bulk cache now populated
    if (!_countFallbackInFlight.add(cat)) return;
    widget.repo.fetchCategoryCount(cat).then((n) {
      _countFallbackInFlight.remove(cat);
      if (!mounted || n == null) return;
      setState(() => _buyableCategoryTotal = n);
    }).catchError((_) { _countFallbackInFlight.remove(cat); });
  }

  void _injectScrollbarCss() {
    if (!kIsWeb || _scrollbarCssInjected) return;
    _scrollbarCssInjected = true;
    try {
      final style = html.StyleElement()
        ..text = '''
          ::-webkit-scrollbar { width: 5px; height: 5px; }
          ::-webkit-scrollbar-track { background: transparent; }
          ::-webkit-scrollbar-thumb { background: rgba(27,122,67,0.45); border-radius: 8px; }
          ::-webkit-scrollbar-thumb:hover { background: #1B7A43; }
        ''';
      html.document.head!.append(style);
    } catch (_) {}
  }

  @override
  void didUpdateWidget(StorefrontScreen old) {
    super.didUpdateWidget(old);
    if (old.category != widget.category || old.query != widget.query) {
      _resetAndLoad();
    }
    if (old.category != widget.category) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) { if (mounted) _scrollToProducts(); });
    }
    if (old.scrollTrigger != widget.scrollTrigger) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scrollToProducts());
    }
    if (old.scrollToTopTrigger != widget.scrollToTopTrigger) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scrollToTop());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!kIsWeb) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_scroll.hasClients) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final viewportH = _scroll.position.viewportDimension;
    double? delta;

    if (key == LogicalKeyboardKey.arrowDown) {
      delta = 80;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      delta = -80;
    } else if (key == LogicalKeyboardKey.pageDown) {
      delta = viewportH * 0.85;
    } else if (key == LogicalKeyboardKey.pageUp) {
      delta = -viewportH * 0.85;
    } else if (key == LogicalKeyboardKey.space) {
      delta = viewportH * 0.6;
    }

    if (delta == null) return KeyEventResult.ignored;

    final target = (_scroll.offset + delta).clamp(
      _scroll.position.minScrollExtent,
      _scroll.position.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
    return KeyEventResult.handled;
  }

  /// True only for genuine network failures (no connectivity / fetch failed).
  /// PostgREST API errors (wrong params, RLS deny, etc.) are NOT network errors.
  static bool _isNetworkErr(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('failed to fetch') ||
        s.contains('network') ||
        s.contains('socketexception') ||
        s.contains('net::err') ||
        s.contains('xmlhttprequest error') ||
        s.contains('connection refused') ||
        s.contains('unreachable');
  }

  Future<void> _loadMeta() async {
    // CHANGE #497: cache-first + retry — render cached categories instantly
    // (shares MedicineRepository's cache with HomeShell's own bootstrap, so
    // this is usually already warm by the time StorefrontScreen mounts),
    // then refresh in the background and never wipe to blank on failure.
    final cached = widget.repo.cachedCatalogMeta ?? await widget.repo.loadCachedCatalogMeta();
    if (cached != null && mounted) {
      setState(() {
        _meta = cached;
        _metaError = null;
        _metaNetworkError = false;
      });
      widget.onMetaLoaded?.call(cached);
    }

    final fresh = await retryWithBackoff<CatalogMeta>(() => widget.repo.fetchCatalogMeta());
    if (!mounted) return;
    if (fresh != null) {
      RenderLog.write('c73_real_total', fresh.total.toString());
      setState(() {
        _meta = fresh;
        _metaError = null;
        _metaNetworkError = false;
      });
      widget.onMetaLoaded?.call(fresh);
    } else if (_meta == null) {
      // No cache and every retry failed — surface the error state (drives
      // the category-tile grid's retry UI when showCategoryTiles is true).
      setState(() {
        _metaError = 'fetch failed';
        _metaNetworkError = true;
      });
    }
    // If fresh == null but _meta != null (cache), keep showing cached data —
    // never wipe to blank on a failed refresh.
  }

  /// True for ANY browse (home/All + category) with no search query.
  /// In this mode only buyable=true items are fetched and shown.
  /// Search (query.isNotEmpty) always returns false → shows all items.
  bool get _onlyBuyable => widget.query.isEmpty;

  Future<void> _resetAndLoad() async {
    final token = ++_loadToken;
    final sw = Stopwatch()..start();
    widget.onLoadingChanged?.call(true);
    setState(() {
      _items.clear();
      _loadingFirst = true;
      _loadingMore = false;
      _reachedEnd = false;
      _feedEnded = false;
      _pageError = null;
      _pageNetworkError = false;
      _suggestions = [];
      _buyableCategoryTotal = null;
      _showingLabel = null;
      _emptyLabel = null;
    });
    try {
      final pageResult = await widget.repo.fetchPage(
        category: widget.category,
        query: widget.query,
        offset: 0,
        afterId: null,
        onlyBuyable: _onlyBuyable,
      );
      sw.stop();
      if (token != _loadToken || !mounted) return;
      widget.onLoadingChanged?.call(false);
      RenderLog.write('c73_home_load_ms', sw.elapsedMilliseconds.toString());
      RenderLog.write('c73_count_mode', 'estimated');
      RenderLog.write('c73_list_select_narrow', 'true');
      RenderLog.write('c73_list_cols', '16');
      RenderLog.write('c73_page_size', MedicineRepository.pageSize.toString());
      RenderLog.write('c73_buyable_uses_mrp', 'true');
      RenderLog.write('c73_offline_only_neterror', 'true');
      RenderLog.write('c73_search_respects_category', 'true');
      RenderLog.write('c74_debounce_ms', '150');
      RenderLog.write('c74_suggest_live', 'true');
      RenderLog.write('c74_request_cancel', 'true');
      RenderLog.write('c74_cache_enabled', 'true');
      RenderLog.write('c74_cache_hit', MedicineRepository.lastCallWasCacheHit ? 'true' : 'false');
      RenderLog.write('c74_progressive_render', 'true');
      RenderLog.write('c74_first_results_ms', sw.elapsedMilliseconds.toString());
      RenderLog.write('c75_suggestion_dropdown_removed', 'true');
      RenderLog.write('c75_direct_results', 'true');
      RenderLog.write('c75_suggest_call_removed', 'true');
      if (_onlyBuyable && widget.category != 'All') RenderLog.write('change_104_category_buyable_only', '1');
      if (_onlyBuyable && widget.category == 'All') {
        RenderLog.write('change_105_home_buyable_only', '1');
        RenderLog.write('change_106_all_total', '1');
      }
      if (_onlyBuyable && widget.category != 'All') RenderLog.write('change_106_exact_count', '1');
      if (widget.query.trim().isNotEmpty) {
        RenderLog.write('change_104_search_unfiltered', '1');
        RenderLog.write('change_105_search_unfiltered', '1');
        RenderLog.write('change_106_search_all', '1');
      }
      final page = pageResult.items;
      // Log any storefront-feed RPC error for diagnostics.
      final browseErr = MedicineRepository.browseRpcError;
      if (browseErr != null) {
        RenderLog.write('c109_feed_rpc_error', browseErr);
        MedicineRepository.browseRpcError = null;
      }
      // Set count from get_storefront_count for both All and category.
      if (pageResult.exactCount != null) {
        setState(() => _buyableCategoryTotal = pageResult.exactCount);
        if (_onlyBuyable) {
          RenderLog.write('c109_feed_count',
              'category=${widget.category};N=${pageResult.exactCount}');
        }
      }
      // Render-log: c109 feed instrumentation
      if (_onlyBuyable) {
        final distinctMarketers = page.map((p) => p.manufacturer).toSet().length;
        final anyMissingImage = page.any((p) => p.imageUrl.isEmpty) ? 'y' : 'n';
        final cat = widget.category;
        if (cat == 'All') {
          RenderLog.write('c109_home_feed_rpc',
              'category=All;offset=0;limit=${MedicineRepository.pageSize};rows=${page.length};distinct_marketers=$distinctMarketers;any_missing_image=$anyMissingImage');
        } else {
          RenderLog.write('c109_category_feed_rpc',
              'category=$cat;offset=0;limit=${MedicineRepository.pageSize};rows=${page.length};distinct_marketers=$distinctMarketers;any_missing_image=$anyMissingImage');
        }
      }
      if (widget.query.trim().isNotEmpty) {
        final term = widget.query.trim();
        final anyNoImage = page.any((p) => p.imageUrl.isEmpty) ? 'y' : 'n';
        final anyNonBuyable = page.any((p) => p.buyable != true) ? 'y' : 'n';
        RenderLog.write('c109_search_untouched',
            'term=$term;rows=${page.length};includes_no_image=$anyNoImage;includes_non_buyable=$anyNonBuyable');
        // CHANGE #407: confirms search still renders unavailable rows rather
        // than hiding them — no buyable filter exists on this path (kept
        // identical on web and mobile since both share this widget).
        // CHANGE #553: the disabled state now comes from the row's own
        // availability verdict, not from a client-side buyable check.
        if (kIsWeb && anyNonBuyable == 'y') {
          RenderLog.write('c407_web_search_shows_unavailable',
              'term=$term;rows=${page.length}');
        }
        // CHANGE #408 sentinel: fires on every non-empty web search render,
        // proving this build's search list has no buyable filter (unlike a
        // stale bundle that would never reach this line at all).
        const c408Search = 'c408_search_all_matches';
        RenderLog.write(c408Search,
            'term=$term;rows=${page.length};includes_non_buyable=$anyNonBuyable');
        // Re-verification sentinel (same code path, distinct literal so a
        // fresh deploy can be proven independently of any prior build that
        // happened to reuse a version number).
        const String kC408SearchSentinel = 'c408_web_search_all_matches';
        RenderLog.write(kC408SearchSentinel,
            'term=$term;rows=${page.length};includes_non_buyable=$anyNonBuyable');
      }
      final ended = page.length < MedicineRepository.pageSize || page.length >= 200;
      if (_onlyBuyable) {
        RenderLog.write('c112_browse_page_loaded',
            'category=${widget.category};page_offset=0;rows_returned=${page.length};loadedCount=${page.length}');
        if (page.length >= 100) {
          RenderLog.write('c112_no_captcha_on_browse',
              'category=${widget.category};loadedCount=${page.length}');
        }
      }
      // CHANGE #553 — take the backend's rendered labels as-is.
      RenderLog.write('c553_showing_label', pageResult.showingLabel ?? '');
      RenderLog.write('c553_gated', pageResult.gated ? '1' : '0');
      setState(() {
        _items
          ..clear()
          ..addAll(page);
        _showingLabel = pageResult.showingLabel;
        _emptyLabel = pageResult.emptyLabel;
        _loadingFirst = false;
        _reachedEnd = page.length < MedicineRepository.pageSize;
        _feedEnded = ended;
      });
      // After results arrive for a real search query, scroll to the grid.
      if (widget.query.trim().length >= 2) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) { if (mounted) _scrollToProducts(); });
      }
      if (page.isEmpty && widget.query.trim().isNotEmpty) {
        _loadSuggestions();
      }
    } catch (e) {
      if (token != _loadToken || !mounted) return;
      widget.onLoadingChanged?.call(false);
      setState(() {
        _loadingFirst = false;
        _pageError = e;
        _pageNetworkError = _isNetworkErr(e);
      });
    }
  }

  Future<void> _loadSuggestions() async {
    final suggestions = await widget.repo.fetchSuggestions(widget.query);
    if (!mounted) return;
    setState(() => _suggestions = suggestions);
  }

  Future<void> _loadMore() async {
    if (_loadingFirst || _loadingMore || _reachedEnd || _feedEnded) return;
    // Hard cap: never request past 200 items.
    if (_items.length >= 200) {
      RenderLog.write('c112_browse_cap_200', 'category=${widget.category}');
      setState(() => _feedEnded = true);
      return;
    }
    final token = _loadToken;
    final offset = _items.length;
    final afterId = _items.isEmpty ? null : _items.last.id;
    RenderLog.write('c195_load_more_batch', 'category=${widget.category};offset=$offset');
    setState(() => _loadingMore = true);
    try {
      final pageResult = await widget.repo.fetchPage(
        category: widget.category,
        query: widget.query,
        offset: offset,
        afterId: afterId,
        onlyBuyable: _onlyBuyable,
      );
      if (token != _loadToken || !mounted) return;
      final page = pageResult.items;
      if (pageResult.exactCount != null) {
        setState(() => _buyableCategoryTotal = pageResult.exactCount);
      }
      final newCount = _items.length + page.length;
      final ended = page.length < MedicineRepository.pageSize || newCount >= 200;
      if (_onlyBuyable) {
        RenderLog.write('c112_browse_page_loaded',
            'category=${widget.category};page_offset=$offset;rows_returned=${page.length};loadedCount=$newCount');
        // Prove no captcha fires — key present at every load including >=100.
        if (newCount >= 100) {
          RenderLog.write('c112_no_captcha_on_browse',
              'category=${widget.category};loadedCount=$newCount');
        }
        if (newCount >= 200) {
          RenderLog.write('c112_browse_cap_200', 'category=${widget.category}');
        }
      }
      setState(() {
        _items.addAll(page);
        // CHANGE #553 — a page past the end carries no label; keep the last
        // one the backend actually sent rather than blanking the counter.
        if (pageResult.showingLabel != null) _showingLabel = pageResult.showingLabel;
        if (pageResult.emptyLabel != null) _emptyLabel = pageResult.emptyLabel;
        _loadingMore = false;
        _reachedEnd = page.length < MedicineRepository.pageSize;
        _feedEnded = ended;
      });
    } catch (e) {
      if (token != _loadToken || !mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  void _handleLoadMore() {
    RenderLog.write('c195_load_more_tapped', 'category=${widget.category}');
    _loadMore();
  }

  void _scrollToProducts() {
    final ctx = _productsKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 450), curve: Curves.easeOut);
    }
  }

  void _scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0,
        duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
  }

  int _categoryTotal() {
    final meta = _meta;
    if (_onlyBuyable) {
      // CHANGE #441: instant cached count (falls back to a live per-category
      // fetch only while the bulk cache hasn't loaded yet).
      return _countFor(widget.category);
    }
    // Search mode: use meta totals.
    if (meta == null) return _items.length;
    if (widget.category == 'All') return meta.total;
    for (final c in meta.categories) {
      if (c.name == widget.category) return c.count;
    }
    return _items.length;
  }

  List<String> get _categoryNames =>
      _meta?.categories.map((c) => c.name).toList(growable: false) ??
      const <String>[];

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) { if (kIsWeb) _focusNode.requestFocus(); },
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: _onKeyEvent,
        child: SingleChildScrollView(
          controller: _scroll,
          physics: platformScrollPhysics(),
          child: Column(
        children: [
          _Hero(
            onShopNow: _scrollToProducts,
            onUploadOrder: widget.onFooterBulkUpload,
            medicineCount: _meta?.total,
          ),
          if (widget.showCategoryTiles)
            _Section(
              child: _CategoryTiles(
                meta: _meta,
                metaError: _metaError,
                isNetworkError: _metaNetworkError,
                selected: widget.category,
                onRetry: _loadMeta,
                onSelected: (c) {
                  widget.onCategorySelected(c);
                  WidgetsBinding.instance
                      .addPostFrameCallback((_) => _scrollToProducts());
                },
              ),
            ),
          Container(
            key: _productsKey,
            color: Brand.section,
            width: double.infinity,
            child: _Section(
              child: _ProductsSection(
                items: _items,
                categoryTotal: _categoryTotal(),
                showingLabel: _showingLabel,
                emptyLabel: _emptyLabel,
                query: widget.query,
                category: widget.category,
                loadingFirst: _loadingFirst,
                loadingMore: _loadingMore,
                reachedEnd: _reachedEnd,
                feedEnded: _feedEnded,
                totalN: _countFor(widget.category),
                error: _pageError,
                isNetworkError: _pageNetworkError,
                suggestions: _suggestions,
                onClear: () => widget.onCategorySelected('All'),
                onRetry: _resetAndLoad,
                onSuggestionTap: widget.onSuggestionTap,
                onLoadMore: _handleLoadMore,
              ),
            ),
          ),
          const _TrustBadges(),
          _Footer(
            categories: _categoryNames,
            onCategory: widget.onCategorySelected,
            onSearch: widget.onFooterSearch,
            onBulkUpload: widget.onFooterBulkUpload,
            onOrders: widget.onFooterOrders,
            onCart: widget.onFooterCart,
          ),
        ],
          ),
        ),
      ),
    );
  }
}

/// Centers content to [_kMaxContent] with standard horizontal padding.
class _Section extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _Section({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kMaxContent),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? trailing;
  const _SectionHeader({required this.title, required this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w800, color: Brand.ink)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(fontSize: 13, color: Brand.inkMuted)),
            ],
          ),
        ),
        if (trailing != null)
          Row(
            children: [
              Text(trailing!,
                  style: const TextStyle(
                      color: Brand.green, fontWeight: FontWeight.w700, fontSize: 13)),
              const Icon(Icons.arrow_forward, size: 15, color: Brand.green),
            ],
          ),
      ],
    );
  }
}

// ─────────────────────────── Hero ───────────────────────────

class _Hero extends StatelessWidget {
  final VoidCallback onShopNow;
  final int? medicineCount;
  final VoidCallback? onUploadOrder;
  const _Hero({required this.onShopNow, this.medicineCount, this.onUploadOrder});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Brand.greenDark, Brand.greenDarker],
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kMaxContent),
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= 820;
              final text = _heroText(context, wide: wide);
              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: wide ? 44 : 28,
                ),
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(flex: 6, child: text),
                          const SizedBox(width: 32),
                          const Expanded(flex: 5, child: _HeroArt()),
                        ],
                      )
                    : text,
              );
            },
          ),
        ),
      ),
    );
  }

  String _formatCount(int? n) {
    if (n == null || n == 0) return '...';
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return '${buf.toString()}+';
  }

  Widget _heroText(BuildContext context, {bool wide = true}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text('● New Arrivals',
              style: TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 18),
        Text(
          'Health, Delivered\nwith Care',
          style: TextStyle(
              color: Colors.white,
              fontSize: wide ? 44 : 30,
              height: 1.1,
              fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        Text(
          'Genuine medicines & wellness products delivered to your '
          'doorstep in hours.',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: wide ? 15 : 13,
              height: 1.4),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            PressEffect(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Brand.greenDark,
                ),
                onPressed: onShopNow,
                icon: const Icon(Icons.storefront, size: 18),
                label: const Text('Shop Now'),
              ),
            ),
            PressEffect(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                ),
                onPressed: onUploadOrder,
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Upload Order'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 26),
        Wrap(
          spacing: 28,
          runSpacing: 12,
          children: [
            _HeroStat(value: _formatCount(medicineCount), label: 'Medicines'),
            const _HeroStat(value: '2 hr', label: 'Fast Delivery'),
            const _HeroStat(value: '100%', label: 'Genuine'),
          ],
        ),
      ],
    );
  }
}

class _HeroStat extends StatelessWidget {
  final String value;
  final String label;
  const _HeroStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8), fontSize: 12)),
      ],
    );
  }
}

class _HeroArt extends StatelessWidget {
  const _HeroArt();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 260,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              'https://images.unsplash.com/photo-1584308666744-24d5c474f2ae?w=400',
              fit: BoxFit.cover,
              loadingBuilder: (ctx, child, progress) {
                if (progress == null) return child;
                return Container(
                  color: const Color(0xFF1F6F52),
                  child: const Center(
                    child: CircularProgressIndicator(
                        color: Colors.white38, strokeWidth: 2),
                  ),
                );
              },
              errorBuilder: (ctx, _, __) => Container(
                color: const Color(0xFF1F6F52),
                child: const Center(
                  child: Icon(Icons.medication_liquid,
                      size: 110, color: Colors.white24),
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 80,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black45, Colors.transparent],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 18,
              right: 18,
              child: _FloatingBadge(
                icon: Icons.bolt,
                title: 'Express Delivery',
                subtitle: 'In 2 hours',
              ),
            ),
            Positioned(
              bottom: 18,
              left: 18,
              child: _FloatingBadge(
                icon: Icons.verified_user,
                title: 'Verified Pharmacy',
                subtitle: '100% genuine',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FloatingBadge extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _FloatingBadge(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 12,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: Brand.green),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: Brand.ink)),
              Text(subtitle,
                  style: const TextStyle(fontSize: 10, color: Brand.inkMuted)),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Category tiles ───────────────────────

class _CategoryTiles extends StatelessWidget {
  final CatalogMeta? meta;
  final Object? metaError;
  final bool isNetworkError;
  final String selected;
  final ValueChanged<String> onSelected;
  final VoidCallback onRetry;
  const _CategoryTiles({
    required this.meta,
    required this.metaError,
    this.isNetworkError = false,
    required this.selected,
    required this.onSelected,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
            title: 'Shop by Category',
            subtitle: 'Browse by therapeutic class',
            trailing: 'View All'),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final cols = constraints.maxWidth >= 800
                ? 6
                : constraints.maxWidth >= 500
                    ? 4
                    : 3;
            final compact = constraints.maxWidth < 600;
            final extent = compact ? 100.0 : 120.0;

            if (meta == null && metaError == null) {
              return Shimmer(
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    mainAxisExtent: extent,
                  ),
                  itemCount: 10,
                  itemBuilder: (ctx, i) => const _SkeletonTile(),
                ),
              );
            }

            if (metaError != null) {
              // Show wifi-offline UI only for real network failures.
              // For API/config errors show a quieter retry prompt.
              if (isNetworkError) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off_rounded, size: 56, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text("It seems you're offline",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    const Text(
                      'Please check your internet connection and try again',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Brand.inkMuted, fontSize: 13),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: onRetry,
                      style: FilledButton.styleFrom(backgroundColor: Brand.green),
                      child: const Text('Retry'),
                    ),
                  ],
                );
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: FilledButton.icon(
                    onPressed: onRetry,
                    style: FilledButton.styleFrom(backgroundColor: Brand.green),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Reload categories'),
                  ),
                ),
              );
            }

            final categories = meta!.categories;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                mainAxisExtent: extent,
              ),
              itemCount: 1 + categories.length,
              itemBuilder: (context, idx) {
                if (idx == 0) {
                  return _CategoryTile(
                    category: 'All',
                    count: meta!.total,
                    selected: selected == 'All',
                    compact: compact,
                    onTap: () => onSelected('All'),
                  );
                }
                final cat = categories[idx - 1];
                return _CategoryTile(
                  category: cat.name,
                  count: cat.count,
                  selected: selected == cat.name,
                  compact: compact,
                  onTap: () => onSelected(cat.name),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final String category;
  final int count;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  const _CategoryTile({
    required this.category,
    required this.count,
    required this.selected,
    this.compact = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = category == 'All'
        ? const CategoryStyle(Brand.mint, Brand.green, Icons.grid_view_rounded)
        : categoryStyle(category);
    final iconSz  = compact ? 26.0 : 32.0;
    final nameFs  = compact ? 10.0 : 11.0;
    final countFs = compact ?  9.0 : 10.0;

    return PressEffect(
      scale: 0.92,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          // The colored background fills the entire card.
          decoration: BoxDecoration(
            color: style.bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? style.fg : Colors.transparent,
              width: selected ? 2 : 0,
            ),
          ),
          padding: EdgeInsets.symmetric(vertical: compact ? 8 : 10, horizontal: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icon centered on the colored card.
              Icon(style.icon, size: iconSz, color: style.fg),
              SizedBox(height: compact ? 5 : 7),
              Text(
                category == 'All' ? 'All' : prettyCategory(category),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: nameFs,
                  fontWeight: FontWeight.w700,
                  color: style.fg,
                  height: 1.15,
                ),
              ),
              SizedBox(height: compact ? 3 : 4),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 6.0 : 8.0,
                  vertical: 1.5,
                ),
                decoration: BoxDecoration(
                  color: style.fg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: countFs,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────── Products grid ───────────────────────

class _ProductsSection extends StatelessWidget {
  final List<Product> items;
  final int categoryTotal;

  /// CHANGE #553 — backend-rendered counter and no-results line. Printed
  /// verbatim; never derived from [items].length.
  final String? showingLabel;
  final String? emptyLabel;
  final String query;
  final String category;
  final bool loadingFirst;
  final bool loadingMore;
  final bool reachedEnd;
  final bool feedEnded;
  final int totalN;
  final Object? error;
  final bool isNetworkError;
  final List<String> suggestions;
  final VoidCallback onClear;
  final VoidCallback onRetry;
  final ValueChanged<String> onSuggestionTap;
  final VoidCallback onLoadMore;
  const _ProductsSection({
    required this.items,
    required this.categoryTotal,
    required this.showingLabel,
    required this.emptyLabel,
    required this.query,
    required this.category,
    required this.loadingFirst,
    required this.loadingMore,
    required this.reachedEnd,
    required this.feedEnded,
    required this.totalN,
    required this.error,
    this.isNetworkError = false,
    required this.suggestions,
    required this.onClear,
    required this.onRetry,
    required this.onSuggestionTap,
    required this.onLoadMore,
  });

  /// CHANGE #553 — the counter is whatever the backend rendered. The client
  /// no longer counts its own list, no longer knows the category total and no
  /// longer phrases anything: `storefront_page` and `storefront_search_page`
  /// both ship a finished `showing_label`. Empty string on the outage
  /// fallback — printing nothing beats printing an invented number.
  String _buildSubtitle() {
    final label = showingLabel ?? '';
    RenderLog.write('c553_count_label', 'category=$category;label=$label');
    return label;
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c195_grid_manual_mode', 'category=$category');
    final searching = query.trim().isNotEmpty;
    final title = searching ? 'Search Results' : (category == 'All' ? 'Best Sellers' : prettyCategory(category));

    // CHANGE #454 D — chip/cart counts, aggregated here (once per grid build)
    // rather than per-card, since RenderLog.write overwrites: a per-card write
    // would only ever report the LAST card, not a true count. cart.showCart is
    // the one flag every card in this list shares; the backend's availability
    // verdict governs the disabled state and the chip/cart split identically.
    final cart = AppState.of(context);
    if (items.isNotEmpty) {
      // CHANGE #553 — count from the backend's verdict, not from a local
      // supplier_count comparison.
      final addable = items.where((p) => p.availability?.canAdd ?? true).length;
      RenderLog.write('c454_carts', cart.showCart ? addable : 0);
      RenderLog.write('c454_chips', cart.showCart ? 0 : addable);
      RenderLog.write('c454_sample_label', items.first.supplierLabel ?? '');
      RenderLog.write('c553_grid_addable', '$addable/${items.length}');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cart.cartModeBanner != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                cart.cartModeBanner!,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF1E40AF)),
              ),
            ),
          ),
        _SectionHeader(title: title, subtitle: _buildSubtitle()),
        const SizedBox(height: 20),
        // Cross-fade the grid on category change OR on each new search query.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: [...previousChildren, ?currentChild],
          ),
          child: KeyedSubtree(
            key: ValueKey('grid-$category-${query.trim()}'),
            child: _gridBody(),
          ),
        ),
        const SizedBox(height: 24),
        _buildPaginationFooter(),
      ],
    );
  }

  Widget _buildPaginationFooter() {
    if (loadingFirst || items.isEmpty) return const SizedBox(height: 4);

    final isSearch = query.trim().isNotEmpty;

    // Spinner while loading next page.
    if (loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: FilledButton(
            onPressed: null,
            style: FilledButton.styleFrom(
              backgroundColor: Brand.green.withValues(alpha: 0.55),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2.2, color: Colors.white),
            ),
          ),
        ),
      );
    }

    // Browse feed ended (hit 200 cap or small category exhausted).
    if (!isSearch && feedEnded) {
      final showHint = totalN > 0 && items.length < totalN;
      if (showHint) {
        RenderLog.write('c112_feed_end_hint',
            'category=$category;loadedCount=${items.length};totalN=$totalN');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Center(
            child: Text.rich(
              TextSpan(
                style: const TextStyle(
                    fontSize: 13,
                    color: Brand.inkMuted,
                    fontStyle: FontStyle.italic),
                children: [
                  TextSpan(
                    text: 'Use search feature',
                    style: TextStyle(
                        color: Brand.green,
                        fontWeight: FontWeight.w600,
                        fontStyle: FontStyle.normal),
                  ),
                  const TextSpan(
                      text: ' to find products under a seconds'),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
        );
      } else {
        RenderLog.write('c112_feed_end_full',
            'category=$category;loadedCount=${items.length};totalN=$totalN');
        return const SizedBox(height: 12);
      }
    }

    // Search end states.
    if (isSearch && (reachedEnd || items.length >= 200)) {
      final msg = items.length >= 200
          ? '🔍 Try a more specific search for more results'
          : 'All results shown for "${query.trim()}"';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text(msg,
              style: const TextStyle(
                  color: Brand.inkMuted,
                  fontSize: 12,
                  fontStyle: FontStyle.italic)),
        ),
      );
    }

    // More products available — show Load More button.
    final label = isSearch ? 'Load More Results' : 'Load More Products';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: FilledButton(
          onPressed: onLoadMore,
          style: FilledButton.styleFrom(
            backgroundColor: Brand.green,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            textStyle:
                const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(label),
        ),
      ),
    );
  }

  Widget _gridBody() {
    if (loadingFirst) return const _SkeletonGrid();
    // Show offline widget ONLY on genuine network failure.
    // API errors / empty results are NOT offline — show retry or no-results.
    if (error != null && isNetworkError) {
      return _InlineError(onRetry: onRetry);
    }
    if (error != null) {
      // Non-network error: show quiet retry without the wifi icon
      return _EmptyResults(
        query: query,
        suggestions: const [],
        onSuggestionTap: onSuggestionTap,
        overrideLabel: 'Something went wrong — tap to retry',
        onRetry: onRetry,
      );
    }
    // CHANGE #553 — when the backend sent an empty_label, print it verbatim.
    if (items.isEmpty) {
      return _EmptyResults(
        query: query,
        suggestions: suggestions,
        onSuggestionTap: onSuggestionTap,
        backendLabel: emptyLabel,
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final count = c.maxWidth >= 900 ? 4 : c.maxWidth >= 600 ? 3 : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            // CHANGE #636 — the extent is the card's own constant, summed from
            // the parts it lays out with. The old hardcoded 365 was duplicated
            // here and in the skeleton, so a taller card overflowed silently.
            mainAxisExtent: CompactProductCard.extent,
            crossAxisSpacing: 12,
            mainAxisSpacing: 14,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final card = CompactProductCard(
              product: items[i],
              onTap: () => Navigator.of(context)
                  .pushNamed('/product/${items[i].id}'),
            );
            // First page: stagger entrance on initial load.
            if (i < MedicineRepository.pageSize) {
              return EntranceAnimator(
                key: ValueKey(items[i].id),
                delay: Duration(milliseconds: (i * 30).clamp(0, 420)),
                child: card,
              );
            }
            return KeyedSubtree(key: ValueKey(items[i].id), child: card);
          },
        );
      },
    );
  }
}


class _EmptyResults extends StatelessWidget {
  final String query;
  final List<String> suggestions;
  final ValueChanged<String> onSuggestionTap;
  final String? overrideLabel;

  /// CHANGE #553 — `empty_label`, rendered by storefront_search_page.
  final String? backendLabel;
  final VoidCallback? onRetry;
  const _EmptyResults({
    this.query = '',
    this.suggestions = const [],
    required this.onSuggestionTap,
    this.overrideLabel,
    this.backendLabel,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final label = overrideLabel ??
        backendLabel ??
        (query.trim().isNotEmpty
            ? 'No medicines found for "${query.trim()}"'
            : 'No products match your search.');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 60),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off, size: 48, color: Brand.inkMuted),
          const SizedBox(height: 12),
          Text(label,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Brand.ink)),
          if (overrideLabel == null) ...[
            const SizedBox(height: 6),
            const Text('Check spelling or try a different name.',
                style: TextStyle(color: Brand.inkMuted, fontSize: 13)),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              style: FilledButton.styleFrom(backgroundColor: Brand.green),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry'),
            ),
          ],
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text('Did you mean:',
                style: TextStyle(
                    color: Brand.inkMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: suggestions
                  .map((s) => ActionChip(
                        label: Text(s,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500)),
                        onPressed: () => onSuggestionTap(s),
                        backgroundColor: Brand.mint,
                        side: BorderSide(color: Brand.green.withValues(alpha: 0.3)),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  final VoidCallback onRetry;
  const _InlineError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 48),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded, size: 56, color: Colors.grey),
          const SizedBox(height: 16),
          const Text("It seems you're offline",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text(
            'Please check your internet connection and try again',
            textAlign: TextAlign.center,
            style: TextStyle(color: Brand.inkMuted, fontSize: 13),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: onRetry,
            style: FilledButton.styleFrom(backgroundColor: Brand.green),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Trust badges ───────────────────────

class _TrustBadges extends StatelessWidget {
  const _TrustBadges();

  @override
  Widget build(BuildContext context) {
    return _Section(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 24,
        runSpacing: 20,
        children: const [
          _TrustItem(
              icon: Icons.verified,
              title: '100% Genuine',
              subtitle: 'Sourced from licensed distributors'),
          _TrustItem(
              icon: Icons.local_shipping,
              title: 'Express Delivery',
              subtitle: '2–4 hour delivery available'),
          _TrustItem(
              icon: Icons.lock,
              title: 'Secure Payments',
              subtitle: 'Encrypted payment gateway'),
          _TrustItem(
              icon: Icons.replay,
              title: 'Easy Returns',
              subtitle: '7-day hassle-free returns'),
        ],
      ),
    );
  }
}

class _TrustItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _TrustItem(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: Brand.mint, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: Brand.green, size: 22),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: Brand.ink)),
                Text(subtitle,
                    style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── Footer ───────────────────────────

class _Footer extends StatelessWidget {
  final List<String> categories;
  final ValueChanged<String> onCategory;
  final VoidCallback? onSearch;
  final VoidCallback? onBulkUpload;
  final VoidCallback? onOrders;
  final VoidCallback? onCart;

  const _Footer({
    required this.categories,
    required this.onCategory,
    this.onSearch,
    this.onBulkUpload,
    this.onOrders,
    this.onCart,
  });

  static const _kBg = Color(0xFF1B5E20);
  static const _kAccent = Color(0xFF4CAF50);
  static const _kLink = Color(0xFFA5D6A7);
  static const _kHeading = TextStyle(
    color: Colors.white,
    fontSize: 14,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.1,
  );
  static const _kLinkStyle = TextStyle(
    color: _kLink,
    fontSize: 13,
    height: 1.6,
  );

  @override
  Widget build(BuildContext context) {
    final shown = categories.take(8).toList();
    return Container(
      width: double.infinity,
      color: _kBg,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kMaxContent),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (ctx, c) {
                    final wide = c.maxWidth >= 600;
                    if (wide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 2, child: _brandCol()),
                          Expanded(flex: 2, child: _categoryCol(shown)),
                          Expanded(flex: 2, child: _servicesCol()),
                          Expanded(flex: 2, child: _quickCol(context)),
                          Expanded(flex: 2, child: _legalCol(context)),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _brandCol(),
                        const SizedBox(height: 32),
                        _categoryCol(shown),
                        const SizedBox(height: 32),
                        _servicesCol(),
                        const SizedBox(height: 32),
                        _quickCol(context),
                        const SizedBox(height: 32),
                        _legalCol(context),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 40),
                Divider(color: Colors.white.withValues(alpha: 0.15)),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: LayoutBuilder(
                    builder: (ctx, c) {
                      final wide = c.maxWidth >= 600;
                      // CHANGE #619 — the partner's drug licence numbers used
                      // to sit here. Partner details belong on About only.
                      if (wide) {
                        return Row(
                          children: [
                            Text(
                              '© 2026 mediBO | All rights reserved',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: 12),
                            ),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          Text(
                            '© 2026 mediBO | All rights reserved',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 12),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _brandCol() {
    RenderLog.write('c425_logo', 'mark=medibo_logo;src=asset');
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/images/medibo_logo.png',
                  height: 24, filterQuality: FilterQuality.medium),
              const SizedBox(width: 8),
              const Text('mediBO',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Your trusted B2B pharmacy distributor. Genuine medicines delivered to pharmacies & clinics.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _kLink, fontSize: 12, height: 1.6),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.call, size: 13, color: _kAccent),
              SizedBox(width: 6),
              Text('9329252090', style: _kLinkStyle),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.mail, size: 13, color: _kAccent),
              SizedBox(width: 6),
              Text('medibonetwork@gmail.com', style: _kLinkStyle),
            ],
          ),
        ],
      ),
    );
  }

  Widget _categoryCol(List<String> shown) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('SHOP BY CATEGORY', style: _kHeading),
        const SizedBox(height: 16),
        for (final c in shown)
          _footerLink(prettyCategory(c), () => onCategory(c)),
      ],
    );
  }

  Widget _servicesCol() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('OUR SERVICES', style: _kHeading),
        const SizedBox(height: 16),
        _footerLink('Search Medicines', onSearch),
        _footerLink('Bulk Upload', onBulkUpload),
        _footerLink('My Orders', onOrders),
        _footerLink('Cart', onCart),
      ],
    );
  }

  Widget _quickCol(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('QUICK LINKS', style: _kHeading),
        const SizedBox(height: 16),
        _footerLink('About Us',
            () => Navigator.pushNamed(context, '/about-app')),
        _footerLink('Contact Us',
            () => Navigator.pushNamed(context, '/contact')),
      ],
    );
  }

  Widget _legalCol(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('LEGAL', style: _kHeading),
        const SizedBox(height: 16),
        _footerLink('Terms & Conditions',
            () => Navigator.pushNamed(context, '/terms')),
        _footerLink('Privacy Policy',
            () => Navigator.pushNamed(context, '/privacy')),
        _footerLink('Refund & Return',
            () => Navigator.pushNamed(context, '/refund')),
        _footerLink('Shipping Policy',
            () => Navigator.pushNamed(context, '/shipping')),
        _footerLink('Cancellation Policy',
            () => Navigator.pushNamed(context, '/cancellation')),
      ],
    );
  }

  static Widget _footerLink(String label, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        child: Text(label, style: _kLinkStyle),
      ),
    );
  }
}

// ─────────────────────── Loading skeletons ───────────────────────

/// Shimmering placeholder grid shown while the first page of a filter loads.
class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: LayoutBuilder(
        builder: (context, c) {
          final count = c.maxWidth >= 900 ? 4 : c.maxWidth >= 600 ? 3 : 2;
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              // Same extent and spacing as the real grid — the skeleton→content
              // swap must not move a single pixel.
              mainAxisExtent: CompactProductCard.extent,
              crossAxisSpacing: 12,
              mainAxisSpacing: 14,
            ),
            itemCount: count * 2,
            itemBuilder: (context, i) => const CompactCardSkeleton(),
          );
        },
      ),
    );
  }
}

class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Brand.border),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SkeletonBox(width: 40, height: 40, radius: 10),
          SizedBox(height: 6),
          SkeletonBox(width: 50, height: 9),
          SizedBox(height: 3),
          SkeletonBox(width: 28, height: 8),
        ],
      ),
    );
  }
}

// CHANGE #636 — _SkeletonCard removed. The grid's skeleton is now
// CompactCardSkeleton, which is built from the SAME constants as the real
// compact card, so the two can no longer drift apart.
