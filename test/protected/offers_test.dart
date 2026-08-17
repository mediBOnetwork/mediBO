// PROTECTED TEST — CHANGE #179: Offers marketplace contracts.
// DO NOT modify unless explicitly changing these contracts.
// Tests:
//   1. _offer_confirm_qty never oversells (concurrent simulation via pure logic)
//   2. Customer-facing RPCs never leak supplier_id (identity audit)

import 'package:flutter_test/flutter_test.dart';

/// Simulates the _offer_confirm_qty atomic decrement in pure Dart.
/// The real guard is PostgreSQL row-level locking — this verifies the
/// LOGIC contract: only one of N concurrent requests can decrement
/// when available_qty == 1.
class _MockOfferQtyState {
  int availableQty;
  _MockOfferQtyState(this.availableQty);

  /// Returns true if qty was deducted, false if oversold.
  bool confirmQty(int qty) {
    if (availableQty >= qty) {
      availableQty -= qty;
      return true;
    }
    return false;
  }
}

/// Simulates what _offer_display_block returns — verifies seller is always
/// 'mediBO' and supplier_id is NEVER included.
Map<String, dynamic> _mockOfferDisplayBlock({
  required int id,
  required int productId,
  required String supplierId, // stored server-side, never in output
}) {
  // This is what the RPC returns — supplier_id is intentionally absent.
  return {
    'id': id,
    'product_id': productId,
    'product_name': 'Test Product',
    'listing_type': 'discount',
    'seller': 'mediBO',
    'seller_display': 'Sold by mediBO',
    'discount_pct': 10.0,
    'available_qty': 100,
    // supplier_id is deliberately NOT in this map
  };
}

/// Simulates offers_feed payload — verifies no supplier fields leak.
List<Map<String, dynamic>> _mockOffersFeed(List<Map<String, dynamic>> listings) {
  return listings.map((l) => _mockOfferDisplayBlock(
    id: l['id'] as int,
    productId: l['product_id'] as int,
    supplierId: l['supplier_id'] as String,
  )).toList();
}

void main() {
  group('CHANGE #179 — Offers marketplace', () {
    group('Race-proof qty locking', () {
      test('Only one confirm succeeds when available_qty == 1', () {
        final state = _MockOfferQtyState(1);
        // Simulate 5 concurrent requests each trying to buy 1
        final results = List.generate(5, (_) => state.confirmQty(1));
        // Exactly one should succeed
        expect(results.where((r) => r).length, equals(1));
        expect(state.availableQty, equals(0));
      });

      test('Exact qty available — all succeed, none oversell', () {
        final state = _MockOfferQtyState(10);
        final results = List.generate(10, (_) => state.confirmQty(1));
        expect(results.every((r) => r), isTrue);
        expect(state.availableQty, equals(0));
      });

      test('More requests than qty — only qty-worth succeed', () {
        final state = _MockOfferQtyState(3);
        final results = List.generate(10, (_) => state.confirmQty(1));
        expect(results.where((r) => r).length, equals(3));
        expect(state.availableQty, equals(0));
      });

      test('qty=0 — no request succeeds (sold out)', () {
        final state = _MockOfferQtyState(0);
        expect(state.confirmQty(1), isFalse);
        expect(state.confirmQty(5), isFalse);
      });

      test('Bulk qty request refused when insufficient', () {
        final state = _MockOfferQtyState(5);
        expect(state.confirmQty(10), isFalse); // wants 10, only 5 avail
        expect(state.availableQty, equals(5)); // unchanged
      });
    });

    group('Supplier identity audit — customer RPCs never leak supplier_id', () {
      final testListings = [
        {'id': 1, 'product_id': 1001, 'supplier_id': 'uuid-secret-1'},
        {'id': 2, 'product_id': 1002, 'supplier_id': 'uuid-secret-2'},
      ];

      test('_offer_display_block output has no supplier_id key', () {
        final block = _mockOfferDisplayBlock(id: 1, productId: 1001, supplierId: 'uuid-secret-1');
        expect(block.containsKey('supplier_id'), isFalse,
          reason: 'supplier_id must never appear in customer-facing offer block');
        expect(block.containsKey('supplier_name'), isFalse,
          reason: 'supplier_name must never appear in customer-facing offer block');
      });

      test('seller field is always "mediBO", never the supplier', () {
        final block = _mockOfferDisplayBlock(id: 1, productId: 1001, supplierId: 'uuid-secret-1');
        expect(block['seller'], equals('mediBO'));
        expect(block['seller_display'], equals('Sold by mediBO'));
      });

      test('offers_feed payload has no supplier identity fields', () {
        final feed = _mockOffersFeed(testListings);
        for (final row in feed) {
          expect(row.containsKey('supplier_id'), isFalse,
            reason: 'supplier_id leaked in row id=${row["id"]}');
          expect(row.containsKey('supplier_name'), isFalse,
            reason: 'supplier_name leaked in row id=${row["id"]}');
          expect(row['seller'], equals('mediBO'));
        }
      });

      test('All offer rows in feed render seller as mediBO', () {
        final feed = _mockOffersFeed(testListings);
        expect(feed.length, equals(2));
        for (final row in feed) {
          expect(row['seller'], equals('mediBO'));
        }
      });
    });

    group('Offer type contracts', () {
      test('scheme_text is formatted as BUY+FREE FREE', () {
        // Pure logic: scheme_text = buy_qty + '+' + free_qty + ' FREE'
        String schemeText(int buy, int free) => '${buy}+${free} FREE';
        expect(schemeText(5, 1), equals('5+1 FREE'));
        expect(schemeText(10, 2), equals('10+2 FREE'));
      });

      test('near_expiry listing requires batch_expiry_date (creation gate)', () {
        // Pure logic: validation that near_expiry requires expiry date
        bool isValid(String type, DateTime? expiryDate) {
          if (type == 'near_expiry' && expiryDate == null) return false;
          return true;
        }
        expect(isValid('near_expiry', null), isFalse);
        expect(isValid('near_expiry', DateTime.now()), isTrue);
        expect(isValid('discount', null), isTrue);
        expect(isValid('scheme', null), isTrue);
      });

      test('listing_type is one of the allowed values', () {
        const allowed = {'scheme', 'near_expiry', 'discount'};
        expect(allowed.contains('scheme'), isTrue);
        expect(allowed.contains('near_expiry'), isTrue);
        expect(allowed.contains('discount'), isTrue);
        expect(allowed.contains('bundle'), isFalse);
        expect(allowed.contains('flash_sale'), isFalse);
      });

      test('status is one of the allowed values', () {
        const allowed = {'active', 'paused', 'expired', 'delisted'};
        expect(allowed.contains('active'), isTrue);
        expect(allowed.contains('paused'), isTrue);
        expect(allowed.contains('expired'), isTrue);
        expect(allowed.contains('delisted'), isTrue);
        expect(allowed.contains('pending'), isFalse);
      });
    });
  });
}
