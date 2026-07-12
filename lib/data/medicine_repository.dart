import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/product.dart';

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
typedef FetchPageResult = ({List<Product> items, int? exactCount});

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

/// Columns fetched for list/search cards — excludes heavy text blobs
/// (uses, benefits, side_effects, how_it_works, PS1-PS30, etc.).
/// This cuts payload ~10× vs SELECT * on the 60-column MEDICINE table.
const String _kListCols =
    'id,product_name,salt_composition,marketer,therapeutic_class,'
    'image_url_1,pack_qty,pack_size,pack_type,mrp,gst_percent,'
    'status,rx_required,sales_count,has_scheme,has_image,buyable';

/// Fetches medicines from the Supabase `MEDICINE` table.
///
/// Reads are paginated: the storefront pulls [pageSize] rows at a time and
/// keeps requesting the next page as the user scrolls.
class MedicineRepository {
  final SupabaseClient _client;

  MedicineRepository([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  /// Rows fetched per page (infinite-scroll increment).
  static const int pageSize = 20;

  /// Set to true when the last [fetchPage] call was served from cache.
  static bool lastCallWasCacheHit = false;

  /// Set to the error string when browse_medicines RPC fails (for diagnostics).
  static String? browseRpcError;
  static set _browseRpcError(String? v) => browseRpcError = v;

  /// #401: cart_items stores a point-in-time price/name snapshot with no
  /// `buyable` column, so cart lines must re-fetch current buyability by id
  /// to know if a line is still orderable. Returns id -> buyable (missing
  /// ids, e.g. a deleted product, are simply absent from the map).
  Future<Map<String, bool>> fetchBuyableFlags(List<String> ids) async {
    if (ids.isEmpty) return {};
    try {
      final rows = await _client
          .from('MEDICINE')
          .select('id,buyable')
          .inFilter('id', ids);
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
    return CatalogMeta(categories, total);
  }

  /// CHANGE #441: every category's buyable count in one call, via
  /// `get_all_storefront_counts` — powers an instant, no-loading-state
  /// "Showing X of N" label on category switch. Keys are uppercased
  /// category names plus 'ALL'.
  Future<Map<String, int>> fetchAllCategoryCounts() async {
    final res = await _client.rpc('get_all_storefront_counts');
    if (res == null) return {};
    return (res as Map).map(
      (k, v) => MapEntry(k.toString().toUpperCase(), (v as num).toInt()),
    );
  }

  /// Single-category buyable count, via `get_storefront_count`. Used only
  /// as a cache-miss fallback (e.g. before [fetchAllCategoryCounts] resolves).
  Future<int?> fetchCategoryCount(String category) async {
    final res = await _client
        .rpc('get_storefront_count', params: {'category_filter': category});
    return (res as num?)?.toInt();
  }

  /// Loads one page of medicines, optionally filtered by [category] and [query].
  ///
  /// Search path (query non-empty): `search_medicines_priority` RPC applies
  /// trigram fuzzy matching + category filter when set.
  ///
  /// Browse path (no query): `fetch_medicines_by_category_priority` RPC uses
  /// idx_medicine_sales_count index → ~0.12 ms.
  ///
  /// Both RPCs have an ILIKE+sales fallback in case they are unavailable.
  ///
  /// Throws if the request fails so callers can show an error/retry state.
  ///
  /// Returns a [FetchPageResult] with [items] (the page) and [exactCount]
  /// (total filtered rows from the SAME query — never mismatches).
  /// [exactCount] is null for search paths (which show all items).
  ///
  /// When [onlyBuyable] is true (home/All + category browse, NOT search),
  /// filters to buyable=true and includes an exact count. Search passes false.
  Future<FetchPageResult> fetchPage({
    String category = 'All',
    String query = '',
    required int offset,
    int limit = pageSize,
    bool onlyBuyable = false,
  }) async {
    // Strip characters that break PostgREST's or()/ilike syntax.
    final term = query.replaceAll(RegExp(r'[,()*%_]'), ' ').trim();

    // Buyable-only cache uses a distinct key to avoid poisoning the all-items cache.
    final cacheKey = onlyBuyable && term.isEmpty
        ? '${term.toLowerCase()}|$category|$offset|buyable'
        : '${term.toLowerCase()}|$category|$offset';
    final cached = _resultCache[cacheKey];
    if (cached != null) {
      lastCallWasCacheHit = true;
      return cached;
    }
    lastCallWasCacheHit = false;

    if (term.isNotEmpty) {
      // ── Search: fuzzy priority RPC — returns ALL items incl. unavailable ────
      List<Product> items;
      try {
        final rows = await _client.rpc('search_medicines_priority', params: {
          'search_term': term,
          'category_filter': category,
          'page_offset': offset,
          'page_limit': limit,
        });
        items = (rows as List)
            .map((r) => Product.fromMap(r as Map<String, dynamic>))
            .toList(growable: false);
      } catch (_) {
        final pat = '%$term%';
        var fb = _client.from('MEDICINE').select(_kListCols);
        if (category != 'All') fb = fb.eq('therapeutic_class', category);
        final rows = await fb
            .or('product_name.ilike.$pat,salt_composition.ilike.$pat,marketer.ilike.$pat')
            .order('sales_count', ascending: false)
            .range(offset, offset + limit - 1);
        items = rows.map((r) => Product.fromMap(r)).toList(growable: false);
      }
      final result = (items: items, exactCount: null);
      _cacheSet(_resultCache, cacheKey, result);
      return result;
    }

    // ── Browse path: get_storefront_feed (precomputed, image-only, fast) ────────
    // Used for BOTH home "Best Sellers" (All) and category pages.
    // CHANGE #441: the "Showing X of N" label reads from the all-categories
    // count cache (fetchAllCategoryCounts) instead of a per-switch RPC.
    if (onlyBuyable) {
      try {
        final rows = await _client.rpc('get_storefront_feed', params: {
          'category_filter': category,
          'page_offset': offset,
          'page_limit': limit,
        });
        final items = (rows as List)
            .map((r) => Product.fromMap(r as Map<String, dynamic>))
            .toList(growable: false);
        final result = (items: items, exactCount: null);
        _cacheSet(_resultCache, cacheKey, result);
        return result;
      } catch (e) {
        // get_storefront_feed failed — fall back to direct buyable table query.
        _browseRpcError = '${category}:${e.toString().substring(0, e.toString().length.clamp(0, 80))}';
        var fb = _client.from('MEDICINE').select(_kListCols).eq('buyable', true);
        if (category != 'All') fb = fb.eq('therapeutic_class', category);
        final res = await fb
            .order('sales_count', ascending: false)
            .range(offset, offset + limit - 1)
            .count(CountOption.exact);
        final items = (res.data as List)
            .map((r) => Product.fromMap(r as Map<String, dynamic>))
            .toList(growable: false);
        final result = (items: items, exactCount: res.count);
        _cacheSet(_resultCache, cacheKey, result);
        return result;
      }
    }

    // ── Browse non-buyable: category/all priority RPC ─────────────────────────
    List<Product> items;
    try {
      final rows = await _client.rpc('fetch_medicines_by_category_priority', params: {
        'category_name': category,
        'page_offset': offset,
        'page_limit': limit,
      });
      items = (rows as List)
          .map((r) => Product.fromMap(r as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      var fb = _client.from('MEDICINE').select(_kListCols);
      if (category != 'All') fb = fb.eq('therapeutic_class', category);
      final rows = await fb
          .order('sales_count', ascending: false)
          .range(offset, offset + limit - 1);
      items = rows.map((r) => Product.fromMap(r)).toList(growable: false);
    }
    final result = (items: items, exactCount: null);
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
