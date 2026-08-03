// PROTECTED — CHANGE #639.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes cart unavailable-line behaviour.
//
// What this holds down:
//
//   1. The per-line red state is the BACKEND's flag, not a local stock check.
//      cart_render() marks a line `unavailable` + `qty_locked`; the model
//      carries both through untouched, and an unflagged line stays clean. The
//      red tint, the dead +/− and the red ⊗ are all driven off these two
//      booleans, so this is the decision the cart screen renders.
//
//   2. `unavailable_badge` is printed VERBATIM. No count is added up in Dart
//      and "item"/"items" is never pluralised here.
//
//   3. The badge is ABSENT when unavailable_count is 0 — cart_render() omits
//      the key entirely in that case, and the app must not manufacture a chip
//      with empty text.
//
//   4. Removing the flagged line and re-rendering clears the flags and the
//      badge because the SERVER recomputed them. There is no local bookkeeping
//      to go stale.
//
//   5. place_order_v2()'s refusal is read, not interpreted:
//      error == 'unavailable_in_cart' is what decides, and `message` is shown
//      verbatim. Anything else is not this refusal.
//
// SCOPE NOTE: CartScreen needs five inherited states and a live Supabase
// client to mount, so per CLAUDE.md ("if a widget resists mocking, extract its
// decisions into a pure class and test that") this file asserts the decisions —
// the two per-line booleans, the badge strings and CartOrderRefusal — rather
// than pumping the screen. The widgets that consume them are plain renderings
// of exactly these values.
//
// No network, no Supabase, no goldens.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _line({
  required int productId,
  required String name,
  int quantity = 2,
  bool unavailable = false,
}) =>
    {
      'id': productId,
      'product_id': productId,
      'product_name': name,
      'quantity': quantity,
      'mrp': 153.30,
      'image_url': '',
      'manufacturer': 'CIPLA LTD',
      'pack_size': '10 tablets in 1 strip',
      'category': 'ANTI INFECTIVES',
      'buyable': true,
      'added_by_admin': false,
      'line_mrp_display': '₹306.60',
      'qty_label': '2 × ₹153.30',
      // cart_render() attaches BOTH keys, and only to flagged lines.
      if (unavailable) 'unavailable': true,
      if (unavailable) 'qty_locked': true,
    };

/// Mirrors cart_render(): the badge key is present ONLY when the count is
/// non-zero, exactly as the live function behaves.
Map<String, dynamic> _cart({
  required List<Map<String, dynamic>> items,
  required int unavailableCount,
  String? badge,
}) =>
    {
      'items': items,
      'item_count': items.length,
      'unit_count': items.fold<int>(0, (s, i) => s + (i['quantity'] as int)),
      'subtotal': 306.60,
      'render': {'subtotal_display': '₹306.60'},
      'unavailable_count': unavailableCount,
      if (badge != null) 'unavailable_badge': badge,
    };

Future<CartModel> _loaded(Map<String, dynamic> payload) async {
  CartModel.rpcTransport = (fn, params) async => payload;
  final cart = CartModel.forTest();
  await cart.refresh();
  return cart;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => CartModel.rpcTransport = null);

  test('1. per-line unavailable + qty_locked come straight off the payload',
      () async {
    final cart = await _loaded(_cart(
      items: [
        _line(productId: 101, name: 'Montecip 10mg Tablet'),
        _line(productId: 102, name: 'Azimax 100 Dry Syrup', unavailable: true),
      ],
      unavailableCount: 1,
      badge: '1 item not available',
    ));

    final ok = cart.lines.firstWhere((l) => l.product.id == '101');
    final bad = cart.lines.firstWhere((l) => l.product.id == '102');

    expect(bad.unavailable, isTrue);
    expect(bad.qtyLocked, isTrue,
        reason: 'the dead +/- and the red tint are driven by this flag');

    expect(ok.unavailable, isFalse);
    expect(ok.qtyLocked, isFalse,
        reason: 'an unflagged line must be untouched');
  });

  test('2. unavailable_badge is printed verbatim', () async {
    final cart = await _loaded(_cart(
      items: [_line(productId: 102, name: 'Azimax', unavailable: true)],
      unavailableCount: 1,
      badge: '1 item not available',
    ));

    expect(cart.unavailableCount, 1);
    expect(cart.unavailableBadge, '1 item not available');
  });

  test('2b. the plural form is the backend\'s, never rebuilt here', () async {
    final cart = await _loaded(_cart(
      items: [
        _line(productId: 102, name: 'Azimax', unavailable: true),
        _line(productId: 103, name: 'Montecip', unavailable: true),
      ],
      unavailableCount: 2,
      badge: '2 items not available',
    ));

    expect(cart.unavailableBadge, '2 items not available');
  });

  test('3. no badge when unavailable_count is 0', () async {
    final cart = await _loaded(_cart(
      items: [_line(productId: 101, name: 'Montecip 10mg Tablet')],
      unavailableCount: 0,
      // cart_render() omits the key entirely on this path.
    ));

    expect(cart.unavailableCount, 0);
    expect(cart.unavailableBadge, isEmpty,
        reason: 'an absent badge must render nothing, not an empty chip');
    expect(cart.lines.single.unavailable, isFalse);
  });

  test('4. re-rendering after removal clears the flags and the badge',
      () async {
    // First render: one flagged line.
    var payload = _cart(
      items: [
        _line(productId: 101, name: 'Montecip 10mg Tablet'),
        _line(productId: 102, name: 'Azimax 100 Dry Syrup', unavailable: true),
      ],
      unavailableCount: 1,
      badge: '1 item not available',
    );
    CartModel.rpcTransport = (fn, params) async => payload;
    final cart = CartModel.forTest();
    await cart.refresh();
    expect(cart.unavailableCount, 1);

    // The server recomputes after the line is removed — the app clears nothing
    // itself, it simply renders the next payload.
    payload = _cart(
      items: [_line(productId: 101, name: 'Montecip 10mg Tablet')],
      unavailableCount: 0,
    );
    await cart.refresh();

    expect(cart.unavailableCount, 0);
    expect(cart.unavailableBadge, isEmpty);
    expect(cart.lines.any((l) => l.unavailable), isFalse);
  });

  group('5. place_order_v2 refusal', () {
    test('unavailable_in_cart is recognised and the message kept verbatim', () {
      final r = CartOrderRefusal.from({
        'error': 'unavailable_in_cart',
        'message': 'Remove the 1 unavailable item before placing this order.',
        'count': 1,
        'items': [
          {'product_id': 102, 'product_name': 'Azimax 100 Dry Syrup'}
        ],
      });

      expect(r.isUnavailableInCart, isTrue);
      expect(r.message,
          'Remove the 1 unavailable item before placing this order.');
      expect(r.count, 1);
      expect(r.items.single['product_name'], 'Azimax 100 Dry Syrup');
    });

    test('a successful order is not a refusal', () {
      final r = CartOrderRefusal.from({
        'order_code': 'CPO030826ABC001',
        'amount_display': '₹306.60',
      });
      expect(r.isUnavailableInCart, isFalse);
      expect(r.message, isEmpty);
    });

    test('a DIFFERENT error is not this refusal', () {
      final r = CartOrderRefusal.from({
        'error': 'order_hours_closed',
        'message': 'Ordering is closed right now.',
      });
      expect(r.isUnavailableInCart, isFalse,
          reason: 'only the backend\'s own code selects this path');
      expect(r.message, isEmpty);
    });

    test('a refusal with no message renders nothing rather than a substitute',
        () {
      final r = CartOrderRefusal.from({
        'error': 'unavailable_in_cart',
        'count': 2,
      });
      expect(r.isUnavailableInCart, isTrue);
      expect(r.message, isEmpty);
      expect(r.count, 2);
    });
  });
}
