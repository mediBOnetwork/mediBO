// PROTECTED — CMD #2137.
//
// Two Bulk Upload bugs, held down:
//
// 1. FIRST PICK LOST. Returning from the camera / file picker resumes the app;
//    the Supabase client refreshes the token that went stale meanwhile and
//    emits tokenRefreshed. UserState answered EVERY such event with
//    `profileLoading = true`, and HomeShell answers that with a spinner
//    Scaffold that REPLACES the page tree — so BulkUploadScreen was disposed
//    while it awaited the picker, and the file came back to a dead State. The
//    second pick worked because the token was fresh by then. The rule now: a
//    refresh of the account already on screen never blanks the shell, and a
//    pick that lands on a disposed State is handed to the live one.
//
// 2. SEARCH ROWS MISSING LINES. The panel's Search used
//    search_medicines_priority(), a storefront row with no avail_badge,
//    pricing, pack_qty_label or qty_unit — so ProductRowCard printed a name
//    and nothing else, for the results AND for the product then picked. It now
//    asks bulk_search_products(), whose rows are bulk_match_items' own shape,
//    parsed by the same Product.fromBulkMatch.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/auth_refresh_policy.dart';
import 'package:pharma_b2b/models/product.dart';

String _read(String rel) {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    final f = File('${dir.path}/$rel');
    if (f.existsSync()) return f.readAsStringSync();
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  fail('CMD #2137: $rel is missing');
}

/// One row exactly as bulk_search_products() returns it (trimmed pricing).
final Map<String, dynamic> _searchRow = {
  'id': 99000001,
  'product_name': 'DOLO 650 TABLET',
  'company': 'Micro Labs',
  'pack_type': 'strip',
  'pack_size': '15 tablets',
  'mrp': '31.50',
  'buyable': true,
  'category': 'PAIN ANALGESICS',
  'image_url': null,
  'gst_percent': 12,
  'availability': {'available': true, 'label': 'Available'},
  'avail_badge': {
    'label': 'Available',
    'bg': '#D1FAE5',
    'fg': '#065F46',
    'available': true
  },
  'pack_type_label': 'Strip',
  'pack_qty_label': '15 tablets',
  'pack_line': 'Strip · 15 tablets',
  'qty_unit': 'strip',
  'composition': 'Paracetamol (650mg)',
  'pricing': {
    'has_price': true,
    'mrp': 31.50,
    'mrp_display': '₹31.50',
    'price_display': 'PTR',
    'card_price': {'price_display': 'PTR', 'sale_label': 'Sale price:'},
  },
};

void main() {
  group('first pick survives the resume token refresh', () {
    test('a refresh of the account on screen never blanks the shell', () {
      expect(
          AuthRefreshPolicy.blanksShell(
              eventUserId: 'u1', renderedUserId: 'u1'),
          isFalse);
    });
    test('a different or unresolved account still gets the spinner (#308)', () {
      expect(
          AuthRefreshPolicy.blanksShell(
              eventUserId: 'u2', renderedUserId: 'u1'),
          isTrue);
      expect(
          AuthRefreshPolicy.blanksShell(eventUserId: 'u1', renderedUserId: ''),
          isTrue);
    });
    test('the delivery probe holds only the FIRST paint', () {
      expect(
          AuthRefreshPolicy.holdForDeliveryProbe(
              resolved: false, loading: true, paintedForThisUser: false),
          isTrue);
      expect(
          AuthRefreshPolicy.holdForDeliveryProbe(
              resolved: false, loading: true, paintedForThisUser: true),
          isFalse);
    });
    test('UserState and HomeShell route through the policy', () {
      final us = _read('lib/user_state.dart');
      expect(us.contains('AuthRefreshPolicy.blanksShell('), isTrue);
      expect(us.contains('} else if (blanks) {'), isTrue);
      final hs = _read('lib/screens/home_shell.dart');
      expect(hs.contains('AuthRefreshPolicy.holdForDeliveryProbe('), isTrue);
    });
    test('a pick landing on a disposed State is handed on, not dropped', () {
      final b = _read('lib/screens/bulk_upload_screen_web.dart');
      expect(b.contains('_pendingPicks.add('), isTrue);
      expect(b.contains('live._processPickedFile(fileName, fileBytes)'), isTrue);
      expect(b.contains('_drainPendingPicks()'), isTrue);
    });
  });

  group('search rows carry the matched-row payload', () {
    test('the panel searches bulk_search_products, parsed by fromBulkMatch', () {
      final b = _read('lib/screens/bulk_upload_screen_web.dart');
      final start = b.indexOf('Future<List<Product>> _manualSearchProducts(');
      expect(start, greaterThan(0));
      final body = b.substring(start, b.indexOf('\n}\n', start));
      expect(body.contains("'bulk_search_products'"), isTrue);
      expect(body.contains('Product.fromBulkMatch('), isTrue);
      expect(body.contains('search_medicines_priority'), isFalse);
      expect(body.contains('Product.fromMap('), isFalse);
    });
    test('a search row yields all four lines, verbatim', () {
      final p = Product.fromBulkMatch(_searchRow);
      expect(p.name, 'DOLO 650 TABLET');
      expect(p.packQtyLabel, '15 tablets');
      expect(p.qtyUnit, 'strip');
      expect(p.genericName, 'Paracetamol (650mg)');
      expect(p.availBadge, isNotNull);
      expect(p.availBadge!.label, 'Available');
      expect(p.pricing, isNotNull);
      expect(p.pricing!.priceDisplay, 'PTR');
    });
    test('the picked product keeps the four lines through the session', () {
      final p = Product.fromJson(Product.fromBulkMatch(_searchRow).toJson());
      expect(p.packQtyLabel, '15 tablets');
      expect(p.qtyUnit, 'strip');
      expect(p.availBadge?.label, 'Available');
      expect(p.pricing, isNotNull);
    });
    test('the migration ships the RPC', () {
      final m = _read(
          'supabase/migrations/20261003100000_cmd2137_bulk_search_products.sql');
      expect(m.contains('function public.bulk_search_products('), isTrue);
      expect(m.contains('function public.bulk_product_payload('), isTrue);
    });
  });
}
