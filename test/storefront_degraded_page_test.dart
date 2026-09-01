// CMD #434 — the storefront category deep-link that errored client-side while
// `storefront_page()` was healthy.
//
// The symptom on the live build was two render-log lines that could not both
// be true: `c410_compare_tick=...;state=error` with an EMPTY
// `c553_count_label`, while `storefront_page('CARDIAC',0,20)` called directly
// returned 20 items and a finished "Showing 20 of 3067 products in CARDIAC".
// render_verify.js Phase 11 failed its own gridOk gate on every build as a
// result, because that gate IS the non-empty showing_label.
//
// The cause was not the backend. `fetchPage` writes the OUTAGE FALLBACK's
// result into `_resultCache` under exactly the key a healthy envelope would
// use, with no TTL and no marker — and the fallback carries no showing_label,
// no total, no paging plan and no sort chips. So ONE transient RPC failure
// left that category serving a label-less page for the whole session, and the
// grid's own Retry re-read the poisoned entry, which is why it could never
// recover without a full reload.
//
// What this file holds down:
//   1. A degraded page is never cached — the next fetch retries the real RPC.
//   2. A healthy envelope IS still cached (the fix must not cost the cache).
//   3. `degraded` is the flag, not a guess made from a null showing_label.
//   4. When BOTH lanes fail, fetchPage reports the PRIMARY error — the one
//      that actually broke — not the fallback's, and browseRpcError names both
//      so the screen's c434_page_error line can print the real cause.
//
// No network, no Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pharma_b2b/data/medicine_repository.dart';

final _client = SupabaseClient('https://example.invalid', 'anon-key');

/// A healthy `storefront_page` envelope, trimmed to the fields the parser
/// reads. `showing_label` is the backend's own sentence — never rebuilt here.
Map<String, dynamic> _healthy(String category) => {
      'status': 'ok',
      'items': const <Map<String, dynamic>>[],
      'total': 3067,
      'has_more': true,
      'next_offset': 250,
      'initial_limit': 250,
      'more_limit': 100,
      'showing_label': 'Showing 250 of 3067 products in $category',
      'more_label': 'Load more products',
      'end_label': 'You have seen everything in this category',
      'sort_options': const <Map<String, dynamic>>[],
    };

void main() {
  setUp(() => MedicineRepository.browseRpcError = null);

  group('CMD #434 — a degraded page must never be cached', () {
    test('one transient failure does not strand the category on a label-less '
        'page: the next fetch retries storefront_page and gets the counter',
        () async {
      final calls = <String>[];
      var failPrimary = true;
      final repo = MedicineRepository(_client, (fn, {params}) async {
        calls.add(fn);
        if (fn == 'storefront_page' && failPrimary) {
          throw Exception('transient: statement timeout');
        }
        if (fn == 'medicine_page_v2') return const <Map<String, dynamic>>[];
        return _healthy('C434_A');
      });

      final first = await repo.fetchPage(
          offset: 0, category: 'C434_A', onlyBuyable: true);
      expect(first.degraded, isTrue);
      expect(first.showingLabel, isNull,
          reason: 'the fallback has no envelope, so it has no counter');
      expect(calls, ['storefront_page', 'medicine_page_v2']);

      // The RPC is healthy again. Before the fix this second call was served
      // from the cache — lastCallWasCacheHit true, showingLabel still null.
      failPrimary = false;
      calls.clear();
      final second = await repo.fetchPage(
          offset: 0, category: 'C434_A', onlyBuyable: true);

      expect(MedicineRepository.lastCallWasCacheHit, isFalse,
          reason: 'the degraded page must not have been cached');
      expect(calls, ['storefront_page']);
      expect(second.degraded, isFalse);
      expect(second.showingLabel, 'Showing 250 of 3067 products in C434_A');
    });

    test('a healthy envelope is still cached — the fix does not cost the cache',
        () async {
      final calls = <String>[];
      final repo = MedicineRepository(_client, (fn, {params}) async {
        calls.add(fn);
        return _healthy('C434_B');
      });

      await repo.fetchPage(offset: 0, category: 'C434_B', onlyBuyable: true);
      final again = await repo.fetchPage(
          offset: 0, category: 'C434_B', onlyBuyable: true);

      expect(calls, ['storefront_page'], reason: 'served from cache');
      expect(MedicineRepository.lastCallWasCacheHit, isTrue);
      expect(again.showingLabel, 'Showing 250 of 3067 products in C434_B');
      expect(again.degraded, isFalse);
    });

    test('search behaves the same way — a degraded search page is not cached',
        () async {
      final calls = <String>[];
      var failPrimary = true;
      final repo = MedicineRepository(_client, (fn, {params}) async {
        calls.add(fn);
        if (fn == 'storefront_search_page' && failPrimary) {
          throw Exception('transient');
        }
        if (fn == 'medicine_page_v2') return const <Map<String, dynamic>>[];
        return _healthy('C434_C');
      });

      final first = await repo.fetchPage(
          offset: 0, category: 'C434_C', query: 'atorva');
      expect(first.degraded, isTrue);

      failPrimary = false;
      calls.clear();
      final second = await repo.fetchPage(
          offset: 0, category: 'C434_C', query: 'atorva');
      expect(calls.first, 'storefront_search_page');
      expect(second.degraded, isFalse);
      expect(second.showingLabel, isNotNull);
    });
  });

  group('CMD #434 — when both lanes are down, the PRIMARY error is reported',
      () {
    test('fetchPage throws storefront_page\'s error, not the fallback\'s, and '
        'browseRpcError names both', () async {
      final repo = MedicineRepository(_client, (fn, {params}) async {
        if (fn == 'storefront_page') {
          throw Exception('PRIMARY storefront_page exploded');
        }
        throw Exception('FALLBACK medicine_page_v2 exploded');
      });

      Object? thrown;
      try {
        await repo.fetchPage(offset: 0, category: 'C434_D', onlyBuyable: true);
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isNotNull,
          reason: 'both lanes failed, so there is no page to return');
      expect(thrown.toString(), contains('PRIMARY storefront_page exploded'));
      expect(thrown.toString(), isNot(contains('FALLBACK')),
          reason: 'the fallback only ran because the primary already failed');

      final reported = MedicineRepository.browseRpcError;
      expect(reported, isNotNull,
          reason: 'the screen prints this into c434_page_error');
      expect(reported, contains('C434_D'));
      expect(reported, contains('primary=Exception: PRIMARY'));
      expect(reported, contains('fallback=Exception: FALLBACK'));
    });

    test('a total failure caches nothing, so Retry actually retries', () async {
      var attempts = 0;
      final repo = MedicineRepository(_client, (fn, {params}) async {
        if (fn == 'storefront_page') {
          attempts++;
          throw Exception('down');
        }
        throw Exception('down too');
      });

      for (var i = 0; i < 3; i++) {
        try {
          await repo.fetchPage(
              offset: 0, category: 'C434_E', onlyBuyable: true);
        } catch (_) {}
      }
      expect(attempts, 3,
          reason: 'every Retry must reach the RPC, never a cached failure');
    });
  });
}
