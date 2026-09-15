// PROTECTED — CMD #2025.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how a cart tap is saved and rendered.
//
// What this holds down — the tap path, which used to cost a whole cart_render
// (avg 1 s, peak 6.8 s) plus a cart_availability pass PER TAP:
//
//   1. ONE RPC PER BURST, AND IT IS THE FAST ONE. Ten rapid taps send exactly
//      one call, it is `cart_update_item` (never `cart_set_item`), and it
//      carries the FINAL quantity. Every tap shows on screen in its own frame
//      while the burst is still being debounced.
//
//   2. THE ANSWER IS ONE ROW PLUS THE SUMMARY. `cart_update_item` returns the
//      changed line and the two numbers the bar prints; adopting it replaces
//      that line, leaves every other line alone, and moves items/advance to
//      the payload's own strings. Nothing is re-read: no cart_render, no
//      cart_availability follows a tap.
//
//   3. QUANTITY 0 REMOVES THAT LINE AND NOTHING ELSE. `item:null` drops the
//      row; the sibling row and its strings survive untouched.
//
//   4. A FAILURE IS THAT ROW'S, AND IT IS THE BACKEND'S WORDS. `ok:false`
//      rolls the row back to the server's quantity, exposes the backend's
//      `message` and its `retry.label` on that row, and raises NO global
//      cartError — the blocking toast is what this change removed. Retry
//      re-sends the quantity the user was reaching for.
//
//   5. THE PACK CAPTION IS THE PAYLOAD'S. `row.pack_label` is printed
//      verbatim — it is the same sf_pack_badge() string the storefront card
//      prints, and the row never falls back to a unit word it assembled
//      itself ("1 Strip").
//
//   6. WHETHER A ROW OPENS A PRODUCT PAGE IS `row.open.has` — the backend's
//      flag, not a client-side test on the id.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _item({
  String id = '101',
  String name = 'Dolo 650',
  int qty = 1,
  String packLabel = 'Strip of 10 tablets',
  bool canOpen = true,
}) =>
    {
      'id': 1,
      'product_id': id,
      'product_name': name,
      'quantity': qty,
      'mrp': 944.80,
      'image_url': '',
      'manufacturer': 'Micro Labs Ltd',
      'pack_size': '',
      'pack_label': packLabel,
      'category': 'ANALGESICS',
      'row': {
        'name': name,
        'pack_label': packLabel,
        'has_pack': packLabel.isNotEmpty,
        'stepper': {'qty': qty, 'qty_text': '$qty', 'unit_label': 'Strip'},
        'open': {
          'has': canOpen,
          'product_id': id,
          'back_label': 'Back to cart',
        },
        'retry': {'label': 'Retry', 'note': 'Not saved'},
      },
    };

Map<String, dynamic> _summary({int items = 1, String advance = '₹300.00'}) => {
      'item_count': items,
      'unit_count': items,
      'items_label': items == 1 ? '1 item' : '$items items',
      'badge': items > 0 ? '$items' : '',
      'bottom': {
        'has': true,
        'items_label': 'Total items',
        'items_value': '$items',
        'advance_label': 'Advance to pay',
        'has_advance': advance.isNotEmpty,
        'advance_display': advance,
      },
    };

/// The cart as it stands after an open: one full render, two lines.
Map<String, dynamic> _openPayload() => {
      'items': [_item(), _item(id: '202', name: 'Zincovit', qty: 2)],
      'item_count': 2,
      'unit_count': 3,
      'render': {
        'item_count': 2,
        'items_label': '2 items',
        'summary': {
          'bottom': {
            'has': true,
            'items_label': 'Total items',
            'items_value': '2',
            'advance_label': 'Advance to pay',
            'has_advance': true,
            'advance_display': '₹600.00',
          },
        },
        'pill': {'show': true, 'items_label': '2 items'},
      },
    };

/// A cart that has been opened once, plus the call log the transport recorded.
Future<(CartModel, List<(String, Map<String, dynamic>?)>)> _opened(
  Future<dynamic> Function(String fn, Map<String, dynamic>? p) onWrite,
) async {
  final calls = <(String, Map<String, dynamic>?)>[];
  CartModel.rpcTransport = (fn, params) async {
    calls.add((fn, params));
    if (fn == 'cart_render') return _openPayload();
    return onWrite(fn, params);
  };
  final cart = CartModel.forTest();
  await cart.refresh();
  calls.clear(); // the open itself is not what these tests measure
  return (cart, calls);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    RenderLog.flushEnabled = false;
  });
  // A logged-out write mints a guest id through shared_preferences before it
  // sends anything; without the mock store the write never leaves the model.
  setUp(() =>
      SharedPreferences.setMockInitialValues({'medibo_guest_uid': 'guest-1'}));
  tearDown(() => CartModel.rpcTransport = null);

  // ── 1 ──────────────────────────────────────────────────────────────────────
  testWidgets('ten rapid taps send ONE cart_update_item with the final qty',
      (tester) async {
    final (cart, calls) = await _opened((fn, p) async => {
          'ok': true,
          'product_id': '101',
          'removed': false,
          'item': _item(qty: (p?['p_quantity'] as num).toInt()),
          'summary': _summary(),
        });

    for (var i = 0; i < 10; i++) {
      cart.incrementId('101');
      // Every tap is on screen in its own frame, before any call goes out.
      expect(cart.quantityOf('101'), 1 + i + 1);
      expect(calls, isEmpty, reason: 'a tap mid-burst must not send an RPC');
    }

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(calls.length, 1, reason: 'a burst costs exactly one RPC');
    expect(calls.single.$1, 'cart_update_item',
        reason: 'the tap path is the fast door, never cart_set_item');
    expect(calls.single.$2?['p_quantity'], 11,
        reason: 'the call carries the settled quantity, not the first tap');
  });

  // ── 2 ──────────────────────────────────────────────────────────────────────
  testWidgets('the answer is one row + the summary; nothing is re-read',
      (tester) async {
    final (cart, calls) = await _opened((fn, p) async => {
          'ok': true,
          'product_id': '101',
          'removed': false,
          'item': _item(qty: 5, packLabel: 'Strip of 10 tablets'),
          'summary': _summary(items: 2, advance: '₹1,500.00'),
        });

    cart.setQuantityId('101', 5);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // The changed line moved; the sibling did not.
    expect(cart.lines.length, 2);
    expect(cart.lines.first.quantity, 5);
    expect(cart.lines.first.rows('pack_label'), 'Strip of 10 tablets');
    expect(cart.lines[1].product.id, '202');
    expect(cart.lines[1].quantity, 2, reason: 'a sibling row is never touched');

    // The bar's two numbers are the payload's own strings.
    final bottom = (cart.render['summary'] as Map)['bottom'] as Map;
    expect(bottom['items_value'], '2');
    expect(bottom['advance_display'], '₹1,500.00');

    // And that was the ONLY call.
    expect(calls.map((c) => c.$1).toList(), ['cart_update_item'],
        reason: 'a tap triggers no cart_render and no cart_availability');
  });

  // ── 3 ──────────────────────────────────────────────────────────────────────
  testWidgets('quantity 0 drops that line and leaves the other one alone',
      (tester) async {
    final (cart, calls) = await _opened((fn, p) async => {
          'ok': true,
          'product_id': '101',
          'removed': true,
          'message': 'Removed from cart',
          'item': null,
          'summary': _summary(items: 1, advance: '₹300.00'),
        });

    cart.setQuantityId('101', 0);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(cart.lines.length, 1);
    expect(cart.lines.single.product.id, '202');
    expect(cart.lines.single.rows('pack_label'), 'Strip of 10 tablets');
    expect(calls.map((c) => c.$1).toList(), ['cart_update_item']);
  });

  // ── 4 ──────────────────────────────────────────────────────────────────────
  testWidgets('a refused row rolls back inline, in the backend\'s words',
      (tester) async {
    final (cart, calls) = await _opened((fn, p) async => {
          'ok': false,
          'product_id': '101',
          'message': 'No supplier for this product right now',
          'retry': {'label': 'Retry', 'note': 'Not saved'},
        });

    cart.setQuantityId('101', 7);
    expect(cart.quantityOf('101'), 7, reason: 'the tap shows immediately');

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // Rolled back to the server's number — and ONLY this row.
    expect(cart.quantityOf('101'), 1);
    expect(cart.quantityOf('202'), 2);

    // The row says so, using the backend's own strings.
    expect(cart.hasRowError('101'), isTrue);
    expect(cart.rowErrorMessage('101'), 'No supplier for this product right now');
    expect(cart.rowRetryLabel('101'), 'Retry');
    expect(cart.hasRowError('202'), isFalse);

    // No blocking toast. That is the whole point of the row-level state.
    expect(cart.cartError.value, isNull);

    // Retry re-sends the quantity the user was reaching for.
    calls.clear();
    cart.retryRow('101');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(calls.length, 1);
    expect(calls.single.$2?['p_quantity'], 7);
  });

  // ── 5 + 6 ──────────────────────────────────────────────────────────────────
  testWidgets('pack caption and the product-page flag are the payload\'s',
      (tester) async {
    final (cart, _) = await _opened((fn, p) async => {
          'ok': true,
          'item': _item(packLabel: 'Bottle of 100 ml', canOpen: false),
          'summary': _summary(),
        });

    cart.setQuantityId('101', 2);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    final line = cart.lines.first;
    // Verbatim. The row never assembles "2 Bottle" out of a unit word.
    expect(line.rows('pack_label'), 'Bottle of 100 ml');
    // The backend decides whether there is a page behind this row.
    expect(line.rowMap('open')['has'], isFalse);
    expect(cart.lines[1].rowMap('open')['has'], isTrue);
    expect(cart.lines[1].rowMap('open')['back_label'], 'Back to cart');
  });
}
