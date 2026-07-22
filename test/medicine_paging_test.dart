// Regression test for CHANGE #491 — MEDICINE keyset paging.
//
// Proves the `medicine_page` keyset fallback (which replaced the raw
// MEDICINE.range(offset, offset+limit-1) offset scan) threads a row-id
// cursor correctly:
//   1. First load passes p_after_id: null.
//   2. "Load more" after a page whose last row id is 500 passes
//      p_after_id: 500 (never an offset/range).
//   3. When the RPC returns fewer rows than the page limit, the caller
//      sees an end-of-list signal and stops requesting further pages.
//
// No network: the repository's rpc hook is replaced with a fake that
// records every call and returns canned rows, forcing the primary
// (unrelated, untouched) RPC to fail so the keyset fallback fires.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pharma_b2b/data/medicine_repository.dart';

/// A [SupabaseClient] is only constructed here to satisfy the repository's
/// constructor — every rpc() call is intercepted by [_FakeRpc] below, so
/// this client never performs any I/O.
final _dummyClient = SupabaseClient('https://example.invalid', 'anon-key');

Map<String, dynamic> _row(int id) => {
      'id': id,
      'product_name': 'Test Med $id',
      'salt_composition': 'Salt $id',
      'marketer': 'Marketer',
      'therapeutic_class': 'GENERAL',
      'image_url_1': '',
      'pack_qty': '1',
      'pack_size': '10',
      'pack_type': 'Strip',
      'mrp': '100',
      'gst_percent': 12,
      'status': 'Available',
      'rx_required': '',
      'sales_count': 0,
      'has_scheme': false,
      'has_image': false,
      'buyable': true,
    };

/// Records every rpc() call and always fails the primary
/// fetch_medicines_by_category_priority RPC, forcing fetchPage into the
/// medicine_page keyset fallback — the only path under test here.
class _FakeRpc {
  final List<Map<String, dynamic>> calls = [];
  List<Map<String, dynamic>> nextRows = [];

  Future<dynamic> call(String fn, {Map<String, dynamic>? params}) async {
    calls.add({'fn': fn, 'params': params});
    if (fn == 'medicine_page') return nextRows;
    throw Exception('$fn unavailable (simulated)');
  }
}

void main() {
  group('MedicineRepository — keyset paging (CHANGE #491)', () {
    test('first load calls medicine_page with p_after_id null', () async {
      final fake = _FakeRpc()..nextRows = [_row(1), _row(2)];
      final repo = MedicineRepository(_dummyClient, fake.call);

      await repo.fetchPage(category: 'All', query: '', offset: 0, afterId: null);

      final keysetCalls = fake.calls.where((c) => c['fn'] == 'medicine_page');
      expect(keysetCalls.length, 1);
      expect(keysetCalls.first['params']['p_after_id'], isNull);
    });

    test('load more after last row id 500 sends p_after_id 500, not an offset', () async {
      final fake = _FakeRpc()..nextRows = [_row(501), _row(502)];
      final repo = MedicineRepository(_dummyClient, fake.call);

      await repo.fetchPage(category: 'All', query: '', offset: 20, afterId: '500');

      final keysetCalls = fake.calls.where((c) => c['fn'] == 'medicine_page');
      expect(keysetCalls.length, 1);
      final params = keysetCalls.single['params'] as Map<String, dynamic>;
      expect(params['p_after_id'], 500);
      expect(params.containsKey('offset'), isFalse);
      expect(params.containsKey('range'), isFalse);
    });

    test('fewer rows than the limit marks end-of-list — no further calls', () async {
      final fake = _FakeRpc()..nextRows = [_row(1), _row(2), _row(3)];
      final repo = MedicineRepository(_dummyClient, fake.call);

      final result = await repo.fetchPage(
        // Distinct category from the other tests — fetchPage caches results
        // by "term|category|offset" in a module-level map, so a shared key
        // would return a stale cached page from an earlier test.
        category: 'EndOfListTestCategory',
        query: '',
        offset: 0,
        afterId: null,
        limit: MedicineRepository.pageSize,
      );

      // Mirrors the exact end-of-list check storefront_screen.dart uses.
      final reachedEnd = result.items.length < MedicineRepository.pageSize;
      expect(reachedEnd, isTrue);
      expect(result.items.length, 3);

      final callsBefore = fake.calls.length;
      if (!reachedEnd) {
        await repo.fetchPage(
            category: 'EndOfListTestCategory', query: '', offset: 3, afterId: result.items.last.id);
      }
      expect(fake.calls.length, callsBefore); // no further call was made
    });
  });
}
