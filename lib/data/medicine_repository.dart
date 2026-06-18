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

/// Columns fetched for list/search cards — excludes heavy text blobs
/// (uses, benefits, side_effects, how_it_works, PS1-PS30, etc.).
/// This cuts payload ~10× vs SELECT * on the 60-column MEDICINE table.
const String _kListCols =
    'id,product_name,salt_composition,marketer,therapeutic_class,'
    'image_url_1,pack_qty,pack_size,pack_type,mrp,gst_percent,'
    'status,rx_required,sales_count,has_scheme,has_image';

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
  Future<List<Product>> fetchPage({
    String category = 'All',
    String query = '',
    required int offset,
    int limit = pageSize,
  }) async {
    // Strip characters that break PostgREST's or()/ilike syntax.
    final term = query.replaceAll(RegExp(r'[,()*%_]'), ' ').trim();

    if (term.isNotEmpty) {
      // ── Search: fuzzy priority RPC (respects category filter) ───────────────
      try {
        final rows = await _client.rpc('search_medicines_priority', params: {
          'search_term': term,
          'category_filter': category,
          'page_offset': offset,
          'page_limit': limit,
        });
        return (rows as List)
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
        return rows.map((r) => Product.fromMap(r)).toList(growable: false);
      }
    }

    // ── Browse: category/all priority RPC (index scan ~0.12ms) ─────────────────
    try {
      final rows = await _client.rpc('fetch_medicines_by_category_priority', params: {
        'category_name': category,
        'page_offset': offset,
        'page_limit': limit,
      });
      return (rows as List)
          .map((r) => Product.fromMap(r as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      var fb = _client.from('MEDICINE').select(_kListCols);
      if (category != 'All') fb = fb.eq('therapeutic_class', category);
      final rows = await fb
          .order('sales_count', ascending: false)
          .range(offset, offset + limit - 1);
      return rows.map((r) => Product.fromMap(r)).toList(growable: false);
    }
  }

  /// Returns up to 3 product names similar to [query] for "Did you mean?"
  /// suggestions. Never throws — returns empty list on any error.
  Future<List<String>> fetchSuggestions(String query) async {
    final term = query.replaceAll(RegExp(r'[,()*%_]'), ' ').trim();
    if (term.isEmpty) return const [];
    try {
      final rows = await _client.rpc('suggest_medicines', params: {'search_term': term});
      return (rows as List)
          .map((r) => (r as Map<String, dynamic>)['product_name'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
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
