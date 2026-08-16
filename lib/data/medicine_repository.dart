import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/home_sections.dart';
import '../models/product.dart';
import '../models/product_detail.dart';
import '../models/storefront_p3.dart';
import 'storefront_labels.dart';

/// A therapeutic_class plus how many medicines it holds — powers the
/// dynamic category tiles and their count badges.
class CategoryCount {
  final String name;
  final int count;
  const CategoryCount(this.name, this.count);
}

/// Catalog overview: the full set of categories (with counts) and the grand
/// total, all derived live from the database.
class CatalogMeta {
  final List<CategoryCount> categories;
  final int total;
  const CatalogMeta(this.categories, this.total);
}

/// Result of a page fetch. [exactCount] is the total filtered row count from
/// the same query (buyable paths only); null for search/non-buyable paths.
///
/// CHANGE #553 — [showingLabel] and [emptyLabel] are rendered SERVER-SIDE by
/// `storefront_page` / `storefront_search_page`. Print them verbatim; never
/// rebuild a counter from the client's own list length (that was the old
/// "Showing 0 of 32133" bug). Both are null on the outage fallback paths.
///
/// CHANGE #677 — the last four fields are the backend's PAGING PLAN. The app
/// used to hold three numbers of its own: a page size of 20, a "stop at 200"
/// ceiling, and "the page came back short so the feed must have ended". All
/// three were the frontend answering a question the backend owns, and the 200
/// was why a 3,068-product category dead-ended at 200. Now: [initialLimit] is
/// how many the first request asks for, [moreLimit] how many each Load more
/// adds, [nextOffset] where the next request starts, and [hasMore] whether
/// there is anything left. Changing 250/100 is an `app_settings` UPDATE.
///
/// They are null/false only on the outage fallback paths, which carry no
/// envelope at all.
typedef FetchPageResult = ({
  List<Product> items,
  int? exactCount,
  String? showingLabel,
  String? emptyLabel,
  bool gated,
  int? initialLimit,
  int? moreLimit,
  int? nextOffset,
  bool hasMore,
  // #677 — the Load-more button's word and the end-of-feed line. Both were
  // Dart literals ('Load More Products', 'Use search feature to find products
  // under a seconds'); rewording them is now an UPDATE.
  String? moreLabel,
  String? endLabel,
});

/// CHANGE #553 — one product plus the backend's availability verdict, as
/// returned by `storefront_product`. [status] is 'ok' or 'not_found'.
typedef StorefrontProduct = ({String status, bool gated, Product? item});

// ─── Session-scoped in-memory caches (cleared on app restart) ────────────────
// Keyed by "$term|$category|$offset[|buyable]". Cap at 50 entries per cache.
final Map<String, FetchPageResult> _resultCache = {};
final Map<String, List<String>> _suggestCache = {};
const int _kMaxCacheEntries = 50;

void _cacheSet<V>(Map<String, V> cache, String key, V value) {
  if (cache.length >= _kMaxCacheEntries) {
    cache.remove(cache.keys.first); // evict oldest entry
  }
  cache[key] = value;
}

// ─── CHANGE #497: local cache for homepage category metadata & counts ────────
// Categories/counts used to be re-fetched from Supabase on every
// StorefrontScreen mount with no persistence, so a cold/slow network left the
// homepage chip row blank until the RPC returned. Caching the last-good
// response in shared_preferences (mirrored in-memory for the current session)
// lets callers render instantly from cache while a fresh fetch runs in the
// background. shared_preferences only — never dart:html/localStorage.
const String _kMetaCacheKey = 'c497_catalog_meta_cache_v1';
const String _kCountsCacheKey = 'c497_storefront_counts_cache_v1';

/// Retries [task] up to [maxAttempts] times with [backoff] gaps between
/// attempts. Never throws — returns null if every attempt fails. [onRetry]
/// fires before each retry (not the first attempt), useful for diagnostics.
Future<T?> retryWithBackoff<T>(
  Future<T> Function() task, {
  int maxAttempts = 3,
  List<Duration> backoff = const [
    Duration(milliseconds: 300),
    Duration(milliseconds: 600),
  ],
  void Function(int attempt)? onRetry,
}) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await task();
    } catch (_) {
      if (attempt < maxAttempts - 1) {
        onRetry?.call(attempt + 1);
        await Future.delayed(backoff[attempt.clamp(0, backoff.length - 1)]);
      }
    }
  }
  return null;
}

/// Fetches medicines from the Supabase `MEDICINE` table.
///
/// Reads are paginated: the storefront pulls [pageSize] rows at a time and
/// keeps requesting the next page as the user scrolls.
class MedicineRepository {
  final SupabaseClient _client;

  /// Hook every [fetchPage] RPC call goes through. Production code always
  /// forwards to the real client's `.rpc()`; tests substitute a fake so
  /// paging logic (cursor threading, end-of-list) can be verified with no
  /// network at all.
  late final Future<dynamic> Function(String fn, {Map<String, dynamic>? params}) _rpc;

  MedicineRepository([
    SupabaseClient? client,
    Future<dynamic> Function(String fn, {Map<String, dynamic>? params})? rpc,
  ]) : _client = client ?? Supabase.instance.client {
    _rpc = rpc ?? (fn, {params}) => _client.rpc(fn, params: params);
  }

  /// Rows fetched per page (infinite-scroll increment).
  static const int pageSize = 20;

  /// Set to true when the last [fetchPage] call was served from cache.
  static bool lastCallWasCacheHit = false;

  /// Set to the error string when browse_medicines RPC fails (for diagnostics).
  static String? browseRpcError;
  static set _browseRpcError(String? v) => browseRpcError = v;

  // CHANGE #497: in-memory mirror of the shared_preferences category cache.
  // Populated by [loadCachedCatalogMeta]/[loadCachedCategoryCounts] (read) and
  // by a successful [fetchCatalogMeta]/[fetchAllCategoryCounts] (write).
  CatalogMeta? _cachedMeta;
  Map<String, int>? _cachedCounts;

  /// Synchronous cache hit for this session only (null until a fetch or a
  /// [loadCachedCatalogMeta] call has populated it once).
  CatalogMeta? get cachedCatalogMeta => _cachedMeta;
  Map<String, int>? get cachedCategoryCounts => _cachedCounts;

  /// Reads the last-persisted catalog meta from shared_preferences — fast,
  /// no network. Returns null if this device has never cached it before.
  Future<CatalogMeta?> loadCachedCatalogMeta() async {
    if (_cachedMeta != null) return _cachedMeta;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kMetaCacheKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final categories = (decoded['categories'] as List)
          .map((c) => CategoryCount(
                c['name'] as String,
                (c['count'] as num).toInt(),
              ))
          .toList(growable: false);
      final meta = CatalogMeta(categories, (decoded['total'] as num?)?.toInt() ?? 0);
      _cachedMeta = meta;
      return meta;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistCatalogMeta(CatalogMeta meta) async {
    _cachedMeta = meta;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kMetaCacheKey,
        jsonEncode({
          'categories': meta.categories
              .map((c) => {'name': c.name, 'count': c.count})
              .toList(),
          'total': meta.total,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {
      // Cache write failure is non-fatal — the fetched data is still returned.
    }
  }

  /// Reads the last-persisted per-category counts from shared_preferences.
  Future<Map<String, int>?> loadCachedCategoryCounts() async {
    if (_cachedCounts != null) return _cachedCounts;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCountsCacheKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final counts = (decoded['counts'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, (v as num).toInt()));
      _cachedCounts = counts;
      return counts;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistCategoryCounts(Map<String, int> counts) async {
    _cachedCounts = counts;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kCountsCacheKey,
        jsonEncode({
          'counts': counts,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {
      // Cache write failure is non-fatal — the fetched data is still returned.
    }
  }

  /// #401: cart_items stores a point-in-time price/name snapshot with no
  /// `buyable` column, so cart lines must re-fetch current buyability by id
  /// to know if a line is still orderable. Returns id -> buyable (missing
  /// ids, e.g. a deleted product, are simply absent from the map).
  Future<Map<String, bool>> fetchBuyableFlags(List<String> ids) async {
    if (ids.isEmpty) return {};
    try {
      final raw = await _client
          .rpc('medicine_buyable_flags', params: {'p_ids': ids});
      final flags = ((raw is List ? raw.first : raw) as Map)['flags'] as Map;
      final rows = flags.entries
          .map((e) => <String, dynamic>{'id': e.key, 'buyable': e.value})
          .toList();
      final out = <String, bool>{};
      for (final r in rows as List) {
        final row = r as Map<String, dynamic>;
        out[row['id'].toString()] = row['buyable'] == true;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Estimated total row count from Postgres planner stats — instant,
  /// no sequential scan. Accuracy: within ~1-2% after autovacuum.
  Future<int> fetchTotalEstimate() async {
    try {
      final res = await _client.rpc('get_medicine_count_estimate');
      return (res as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Loads every therapeutic_class with its medicine count (and the total),
  /// via the `medicine_category_counts` RPC. Categories are never hardcoded.
  /// Uses the planner-stats estimate for the grand total (avoids exact count).
  Future<CatalogMeta> fetchCatalogMeta() async {
    final results = await Future.wait<dynamic>([
      _client.rpc('medicine_category_counts'),
      fetchTotalEstimate(),
    ]);
    final rows = (results[0] as List).cast<Map<String, dynamic>>();
    final estimate = results[1] as int;
    final categories = rows
        .map((r) => CategoryCount(
              (r['name'] as String?) ?? '',
              (r['n'] is num)
                  ? (r['n'] as num).toInt()
                  : int.tryParse('${r['n']}') ?? 0,
            ))
        .where((c) => c.name.isNotEmpty)
        .toList(growable: false);
    // Use the planner estimate as grand total; fall back to sum of categories.
    final sumTotal = categories.fold<int>(0, (sum, c) => sum + c.count);
    final total = estimate > sumTotal ? estimate : sumTotal;
    final meta = CatalogMeta(categories, total);
    unawaited(_persistCatalogMeta(meta)); // CHANGE #497: cache for instant next-open render
    return meta;
  }

  /// CHANGE #441: every category's buyable count in one call, via
  /// `get_all_storefront_counts` — powers an instant, no-loading-state
  /// "Showing X of N" label on category switch. Keys are uppercased
  /// category names plus 'ALL'.
  Future<Map<String, int>> fetchAllCategoryCounts() async {
    final res = await _client.rpc('get_all_storefront_counts');
    if (res == null) return {};
    final counts = (res as Map).map(
      (k, v) => MapEntry(k.toString().toUpperCase(), (v as num).toInt()),
    );
    unawaited(_persistCategoryCounts(counts)); // CHANGE #497: cache for instant next-open render
    return counts;
  }

  /// Single-category buyable count, via `get_storefront_count`. Used only
  /// as a cache-miss fallback (e.g. before [fetchAllCategoryCounts] resolves).
  Future<int?> fetchCategoryCount(String category) async {
    final res = await _client
        .rpc('get_storefront_count', params: {'category_filter': category});
    return (res as num?)?.toInt();
  }

  /// CHANGE #491: keyset fallback via the `medicine_page` RPC — replaces the
  /// old raw `MEDICINE.range(offset, offset+limit-1)` fallback, which went
  /// from 11ms to 8271ms on deep pages because OFFSET forces Postgres to
  /// walk and discard every prior row. `p_after_id` (the id of the last row
  /// of the previous page; null for the first page) gives constant-time
  /// paging at any depth via an indexed `id > p_after_id` scan.
  Future<List<Product>> _fetchKeysetFallback({
    required String category,
    required String? afterId,
    required int limit,
    String? search,
    bool? buyable,
  }) async {
    // #573 — v2 returns the same rows as jsonb, each carrying its own
    // `pricing` and `availability` block. The old medicine_page returned
    // SETOF "MEDICINE", so cards built from this deep-paging fallback had no
    // price block to render.
    final rows = await _rpc('medicine_page_v2', params: {
      'p_after_id': afterId == null ? null : int.tryParse(afterId),
      'p_limit': limit,
      'p_category': category == 'All' ? null : category,
      'p_search': (search == null || search.isEmpty) ? null : search,
      'p_buyable': buyable,
    });
    return (rows as List)
        .map((r) => Product.fromMap(r as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// CHANGE #553 — parses one storefront RPC envelope (`storefront_page` /
  /// `storefront_search_page`). Both return a single jsonb object whose
  /// `items` are full product rows, each carrying its own `availability`
  /// verdict. Labels are taken as-is; nothing here inspects supplier counts.
  FetchPageResult _parseEnvelope(Object? raw) {
    final env = Map<String, dynamic>.from(raw as Map);
    final items = ((env['items'] as List?) ?? const [])
        .map((r) => Product.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false);
    return (
      items: items,
      exactCount: (env['total'] as num?)?.toInt(),
      showingLabel: env['showing_label']?.toString(),
      emptyLabel: env['empty_label']?.toString(),
      gated: env['gated'] == true,
      // #677 — absent on `storefront_search_page`, which is unpaged by design
      // (search shows everything it matched). Null means "the backend sent no
      // plan", never "use 20".
      initialLimit: (env['initial_limit'] as num?)?.toInt(),
      moreLimit: (env['more_limit'] as num?)?.toInt(),
      nextOffset: (env['next_offset'] as num?)?.toInt(),
      hasMore: env['has_more'] == true,
      moreLabel: env['more_label']?.toString(),
      endLabel: env['end_label']?.toString(),
    );
  }

  /// CHANGE #553 — one product with its backend availability verdict, via
  /// `storefront_product`. Returns status 'not_found' when the id is unknown.
  Future<StorefrontProduct> fetchProductById(String productId) async {
    final id = int.tryParse(productId);
    if (id == null) return (status: 'not_found', gated: false, item: null);
    final res = await _rpc('storefront_product', params: {'p_product_id': id});
    final env = Map<String, dynamic>.from(res as Map);
    final item = env['item'];
    return (
      status: env['status']?.toString() ?? 'not_found',
      gated: env['gated'] == true,
      item: item is Map
          ? Product.fromMap(Map<String, dynamic>.from(item))
          : null,
    );
  }

  /// CHANGE #638 — one page of a company's catalogue.
  ///
  /// Paging is by `p_offset`; `has_more` is the backend's own answer, never
  /// inferred from the page size.
  Future<CompanyPage> fetchCompanyPage(
    String key, {
    int offset = 0,
    int limit = 24,
  }) async {
    try {
      final res = await _rpc('storefront_company_page', params: {
        'p_key': key,
        'p_offset': offset,
        'p_limit': limit,
      });
      if (res is! Map) return CompanyPage.failed;
      return CompanyPage.fromMap(Map<String, dynamic>.from(res));
    } catch (_) {
      return CompanyPage.failed;
    }
  }

  /// CHANGE #160 — toggle a product in/out of the customer's wishlist.
  Future<WishlistResult> wishlistToggle(String productId) async {
    final id = int.tryParse(productId);
    if (id == null) return WishlistResult.failed;
    try {
      final res =
          await _rpc('wishlist_toggle', params: {'p_product_id': id});
      if (res is! Map) return WishlistResult.failed;
      return WishlistResult.fromMap(Map<String, dynamic>.from(res));
    } catch (_) {
      return WishlistResult.failed;
    }
  }

  /// CHANGE #638 — subscribe to a back-in-stock alert.
  Future<NotifyResult> stockNotifyRequest(String productId) async {
    final id = int.tryParse(productId);
    if (id == null) return NotifyResult.failed;
    try {
      final res =
          await _rpc('stock_notify_request', params: {'p_product_id': id});
      if (res is! Map) return NotifyResult.failed;
      return NotifyResult.fromMap(Map<String, dynamic>.from(res));
    } catch (_) {
      return NotifyResult.failed;
    }
  }

  /// Whether this viewer is already subscribed. Read once on product-page
  /// load — there is deliberately no polling.
  Future<bool> stockNotifyStatus(String productId) async {
    final id = int.tryParse(productId);
    if (id == null) return false;
    try {
      final res =
          await _rpc('stock_notify_status', params: {'p_product_id': id});
      return res is Map && res['subscribed'] == true;
    } catch (_) {
      return false;
    }
  }

  /// The back-in-stock strip. Returns [BackInStock.empty] on any failure, so a
  /// dead call simply means no strip.
  Future<BackInStock> myStockNotifications() async {
    try {
      final res = await _rpc('my_stock_notifications');
      if (res is! Map) return BackInStock.empty;
      return BackInStock.fromMap(Map<String, dynamic>.from(res));
    } catch (_) {
      return BackInStock.empty;
    }
  }

  /// Marks the shown strip items seen. Fire-and-forget: the strip has already
  /// been rendered, and a failure here must never surface to the user.
  Future<void> stockNotifySeen(List<int> productIds) async {
    if (productIds.isEmpty) return;
    try {
      await _rpc('stock_notify_seen', params: {'p_product_ids': productIds});
    } catch (_) {
      // Intentionally silent.
    }
  }

  /// CHANGE #638 — loads the storefront label set into [StorefrontLabels].
  ///
  /// Cards carry no labels of their own, so this is fetched once rather than
  /// per tile. A failure leaves whatever is already cached in place.
  Future<void> loadStorefrontLabels() async {
    try {
      final res = await _rpc('storefront_labels');
      if (res is! Map) return;
      StorefrontLabels.adopt(
        res.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
      );
    } catch (_) {
      // Keep the existing labels.
    }
  }

  /// CHANGE #637 — the whole home feed is ONE RPC.
  ///
  /// `storefront_home_v2()` returns the ordered sections with their titles,
  /// subtitles, See-all destinations and items already chosen. The app renders
  /// them in order; it never decides which sections exist or how they are
  /// sorted.
  ///
  /// A throw or a non-Map response becomes [HomeSections.failed] so the screen
  /// can show its quiet retry block instead of a blank page.
  ///
  /// CHANGE #677 — [items] is null by default and null means "backend, use the
  /// count each section carries in `storefront_home_section`". The old
  /// `items = 12` was a client-side ceiling that silently capped every section
  /// at 12 cards no matter what the config said. It stays as a parameter only
  /// so a future slow-connection path can ask for LESS; it can never ask for
  /// more than the config allows.
  Future<HomeSections> fetchHomeSections({int? items}) async {
    try {
      final res = await _rpc('storefront_home_v2', params: {'p_items': items});
      if (res is! Map) return HomeSections.failed;
      return HomeSections.fromMap(Map<String, dynamic>.from(res));
    } catch (_) {
      return HomeSections.failed;
    }
  }

  /// CHANGE #677 — one more page of a home-feed section.
  ///
  /// `storefront_home_more()` returns cards in the SAME shape
  /// `storefront_home_v2()` sends, so an appended page is parsed by the same
  /// [Product.fromHomeCard] the first page went through. A second shape would
  /// mean a second parser and two places for one card to disagree with itself.
  /// [nextOffset] and [hasMore] are the backend's; the app never decides a feed
  /// has ended.
  ///
  /// Returns an empty page with hasMore:false on any failure, so a dead call
  /// stops the tail quietly instead of throwing under the user's scroll.
  Future<({List<Product> items, int nextOffset, bool hasMore})> fetchHomeMore(
    String key, {
    required int offset,
    int? limit,
  }) async {
    try {
      final res = await _rpc('storefront_home_more', params: {
        'p_key': key,
        'p_offset': offset,
        'p_limit': limit,
      });
      if (res is! Map) {
        return (items: <Product>[], nextOffset: offset, hasMore: false);
      }
      final env = Map<String, dynamic>.from(res);
      final items = ((env['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => Product.fromHomeCard(Map<String, dynamic>.from(r)))
          .toList(growable: false);
      return (
        items: items,
        nextOffset:
            (env['next_offset'] as num?)?.toInt() ?? offset + items.length,
        hasMore: env['has_more'] == true,
      );
    } catch (_) {
      return (items: <Product>[], nextOffset: offset, hasMore: false);
    }
  }

  /// CHANGE #636 — the product page is ONE RPC.
  ///
  /// `product_detail()` returns the whole page render-ready: header, images,
  /// price, the same `availability` verdict the storefront card shows, the
  /// overview rows, the sections, the similar rail and every user-facing label.
  /// There is deliberately no second call to reconcile buy-state against
  /// content — one payload cannot disagree with itself.
  ///
  /// An unparseable id and a non-Map response both render the backend's own
  /// not-found page rather than throwing.
  Future<ProductDetail> fetchProductDetail(String productId) async {
    final id = int.tryParse(productId);
    if (id == null) return ProductDetail.notFound(const {});
    final res = await _rpc('product_detail', params: {'p_product_id': id});
    if (res is! Map) return ProductDetail.notFound(const {});
    return ProductDetail.fromMap(Map<String, dynamic>.from(res));
  }

  /// Loads one page of medicines, optionally filtered by [category] and [query].
  ///
  /// CHANGE #553 — search goes through `storefront_search_page` and browse
  /// through `storefront_page`. Both wrap the older RPCs server-side and add
  /// the per-row `availability` verdict plus the rendered counter labels.
  ///
  /// Browse path (no query): `fetch_medicines_by_category_priority` RPC uses
  /// idx_medicine_sales_count index → ~0.12 ms.
  ///
  /// Both RPCs fall back to the `medicine_page` keyset RPC (via [afterId])
  /// if they're unavailable — never a raw MEDICINE offset scan.
  ///
  /// Throws if the request fails so callers can show an error/retry state.
  ///
  /// Returns a [FetchPageResult] with [items] (the page) and [exactCount]
  /// (total filtered rows from the SAME query — never mismatches).
  /// [exactCount] is null for search paths (which show all items).
  ///
  /// When [onlyBuyable] is true (home/All + category browse, NOT search),
  /// filters to buyable=true and includes an exact count. Search passes false.
  ///
  /// [afterId] is the `id` of the last row from the previous page (null for
  /// the first page) — only consulted by the keyset fallback above; the
  /// primary RPCs keep paging via [offset].
  ///
  /// CHANGE #677 — [limit] is now NULLABLE on the browse path, and null is the
  /// normal case: it means "backend, use your own plan". `storefront_page`
  /// resolves it to `app_settings.storefront_initial_limit`. The caller passes
  /// a number only when echoing back the `more_limit` the backend itself sent
  /// on the previous page. The old `limit = pageSize` default was the client
  /// holding a page size, which is a backend decision.
  Future<FetchPageResult> fetchPage({
    String category = 'All',
    String query = '',
    required int offset,
    String? afterId,
    int? limit,
    bool onlyBuyable = false,
  }) async {
    // Strip characters that break PostgREST's or()/ilike syntax.
    final term = query.replaceAll(RegExp(r'[,()*%_]'), ' ').trim();

    // Buyable-only cache uses a distinct key to avoid poisoning the all-items cache.
    // CHANGE #553: the viewer is part of the key — availability verdicts are
    // per-viewer (approved customers see real availability, everyone else sees
    // a full shop), so a cached page must never leak across a login/logout.
    final viewer = _client.auth.currentUser?.id ?? 'anon';
    // #677 — the limit is part of the key. Two requests for the same offset
    // with different page sizes are different pages, and merging them was how
    // a 250-row first page could be served a cached 20-row one.
    final lim = limit?.toString() ?? 'plan';
    final cacheKey = onlyBuyable && term.isEmpty
        ? '$viewer|${term.toLowerCase()}|$category|$offset|$lim|buyable'
        : '$viewer|${term.toLowerCase()}|$category|$offset|$lim';
    final cached = _resultCache[cacheKey];
    if (cached != null) {
      lastCallWasCacheHit = true;
      return cached;
    }
    lastCallWasCacheHit = false;

    if (term.isNotEmpty) {
      // ── Search: storefront_search_page — ALL items incl. unavailable, each
      // carrying its own availability verdict plus the rendered counter. ──────
      FetchPageResult result;
      try {
        final env = await _rpc('storefront_search_page', params: {
          'search_term': term,
          'category_filter': category,
          'page_offset': offset,
          // #677 — null lets storefront_search_page use its own plan too.
          'page_limit': limit,
        });
        result = _parseEnvelope(env);
      } catch (_) {
        // Outage path only — keyset rows carry no verdict, so callers keep
        // their default styling rather than inventing one.
        final items = await _fetchKeysetFallback(
          category: category,
          afterId: afterId,
          limit: limit ?? pageSize,
          search: term,
        );
        result = (
          items: items,
          exactCount: null,
          showingLabel: null,
          emptyLabel: null,
          gated: false,
          // Outage path: no envelope, so no plan. The caller keeps whatever
          // plan it already had rather than inventing one here.
          initialLimit: null,
          moreLimit: null,
          nextOffset: null,
          hasMore: items.isNotEmpty,
          moreLabel: null,
          endLabel: null,
        );
      }
      _cacheSet(_resultCache, cacheKey, result);
      return result;
    }

    // ── Browse path: storefront_page — wraps get_storefront_feed server-side
    // and adds each row's availability verdict, the rendered "Showing X of N"
    // label and the category total. Used for BOTH home "Best Sellers" (All)
    // and category pages.
    if (onlyBuyable) {
      try {
        final env = await _rpc('storefront_page', params: {
          'category_filter': category,
          'page_offset': offset,
          // #677 — null on purpose. The backend picks the size from
          // app_settings; this is the one call site that must NOT substitute
          // a client default.
          'page_limit': limit,
        });
        final result = _parseEnvelope(env);
        _cacheSet(_resultCache, cacheKey, result);
        return result;
      } catch (e) {
        // storefront_page failed — fall back to the keyset RPC. It carries
        // neither a counter label nor an availability verdict.
        _browseRpcError = '${category}:${e.toString().substring(0, e.toString().length.clamp(0, 80))}';
        final items = await _fetchKeysetFallback(
          category: category,
          afterId: afterId,
          limit: limit ?? pageSize,
          buyable: true,
        );
        final result = (
          items: items,
          exactCount: null,
          showingLabel: null,
          emptyLabel: null,
          gated: false,
          // Outage path: no envelope, so no plan. The caller keeps whatever
          // plan it already had rather than inventing one here.
          initialLimit: null,
          moreLimit: null,
          nextOffset: null,
          hasMore: items.isNotEmpty,
          moreLabel: null,
          endLabel: null,
        );
        _cacheSet(_resultCache, cacheKey, result);
        return result;
      }
    }

    // ── Browse non-buyable: category/all priority RPC ─────────────────────────
    List<Product> items;
    try {
      final rows = await _rpc('fetch_medicines_by_category_priority', params: {
        'category_name': category,
        'page_offset': offset,
        'page_limit': limit ?? pageSize,
      });
      items = (rows as List)
          .map((r) => Product.fromMap(r as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      items = await _fetchKeysetFallback(
        category: category,
        afterId: afterId,
        limit: limit ?? pageSize,
        buyable: false,
      );
    }
    final result = (
      items: items,
      exactCount: null,
      showingLabel: null,
      emptyLabel: null,
      gated: false,
      initialLimit: null,
      moreLimit: null,
      nextOffset: null,
      hasMore: items.isNotEmpty,
      moreLabel: null,
      endLabel: null,
    );
    _cacheSet(_resultCache, cacheKey, result);
    return result;
  }

  /// Returns up to 3 product names similar to [query] for "Did you mean?"
  /// suggestions. Never throws — returns empty list on any error.
  Future<List<String>> fetchSuggestions(String query) async {
    final term = query.replaceAll(RegExp(r'[,()*%_]'), ' ').trim();
    if (term.isEmpty) return const [];
    final key = term.toLowerCase();
    final cached = _suggestCache[key];
    if (cached != null) return cached;
    try {
      final rows = await _client.rpc('suggest_medicines', params: {'search_term': term});
      final result = (rows as List)
          .map((r) => (r as Map<String, dynamic>)['product_name'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      _cacheSet(_suggestCache, key, result);
      return result;
    } catch (_) {
      return const [];
    }
  }

  /// Fire-and-forget: increments sales_count by 1 each time a product is
  /// added to cart, so the popularity sort improves over time.
  Future<void> incrementSalesCount(String medicineId) async {
    final id = int.tryParse(medicineId);
    if (id == null) return;
    await _client.rpc('increment_sales', params: {'medicine_id': id});
  }
}
