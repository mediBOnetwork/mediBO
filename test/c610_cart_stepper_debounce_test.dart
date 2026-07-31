import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';

/// CHANGE #610 — the cart tap costs ONE round trip, and no tap is lost.
///
/// Before: `_setItem` returned early whenever a write was in flight, so a
/// burst of taps was silently discarded; and every accepted write was followed
/// by `get_my_cart` + `medicine_buyable_flags` (and a realtime-triggered
/// `cart_render`) before anything could render. Three-plus sequential round
/// trips per tap is where the ~2s came from — not from the absence of an
/// optimistic cart.
///
/// These tests pin the new contract:
///   * a burst of taps shows every tap immediately and sends ONE RPC;
///   * that RPC's response is the last word — nothing is re-read after it;
///   * a failure puts the SERVER's quantity back;
///   * counts, totals, badge and tier are NEVER derived locally, mid-burst or
///     otherwise — they only ever change when a server payload lands.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => CartModel.rpcTransport = null);

  final product = Product.fromCartData(
    id: '101',
    name: 'Telvas 40',
    b2bPrice: 100.0,
    mrp: 100.0,
  );

  /// A cart_set_item response shaped like the live RPC now returns it:
  /// cart_render() output, complete and render-ready.
  Map<String, dynamic> serverCart({required int qty}) => {
        'items': [
          {
            'id': 5771,
            'product_id': '101',
            'product_name': 'Telvas 40',
            'quantity': qty,
            'price': 100.0,
            'mrp': 100.0,
            'image_url': '',
            'manufacturer': 'Aristo',
            'pack_size': '10 tab',
            'gst_percent': 12,
            'added_by': 'customer',
            'added_by_admin': false,
            'category': 'CARDIAC',
            'buyable': true,
            'line_total': 100.0 * qty,
            'line_mrp': 100.0 * qty,
          }
        ],
        'admin_removed': const [],
        'item_count': 1,
        'unit_count': qty,
        'total': 100.0 * qty,
        'mrp_total': 100.0 * qty,
        'header': '1 product in cart',
        'badge': '1',
        'cta_label': '1 item',
        'empty_title': 'Your cart is empty',
        'empty_note': 'Add products from the catalog to start an order.',
        'net_payable': 100.0 * qty,
        'delivery_fee': 0,
        'discount_pct': 0,
        'discount_amount': 0,
      };

  Widget harness(CartModel cart) {
    return MaterialApp(
      home: AppState(
        cart: cart,
        child: Builder(builder: (context) {
          final c = AppState.of(context);
          return Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => c.increment(product),
                  child: const Text('+'),
                ),
                TextButton(
                  onPressed: () => c.decrement(product),
                  child: const Text('-'),
                ),
                Text('qty:${c.quantityOf('101')}'),
                Text('badge:${c.badge ?? '-'}'),
                Text('net:${c.netPayable}'),
                Text('units:${c.totalUnits}'),
              ],
            ),
          );
        }),
      ),
    );
  }

  /// Advances past the 300ms stepper debounce, lets the RPC future resolve,
  /// then drains RenderLog's own 800ms debounce so no timer outlives the test.
  Future<void> settle(WidgetTester tester) async {
    // The debounce fires...
    await tester.pump(const Duration(milliseconds: 400));
    // ...then the write awaits the guest uuid (shared_preferences) before the
    // RPC, so several event-loop turns pass before the response is adopted.
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    // Finally drain RenderLog's own 800ms debounce.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  /// RenderLog debounces its writes by 800ms, and a write can be scheduled by
  /// the very last adoption in a test. Drain until nothing is left, or the
  /// test ends with a pending timer.
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('five rapid taps: every tap shows at once, ONE RPC is sent',
      (tester) async {
    final sent = <Map<String, dynamic>>[];
    CartModel.rpcTransport = (fn, params) async {
      if (fn == 'cart_set_item') {
        sent.add(params!);
        return {
          'ok': true,
          'message': 'Cart updated',
          'cart': serverCart(qty: params['p_quantity'] as int),
        };
      }
      return <String, dynamic>{};
    };

    final cart = CartModel.forTest();
    await tester.pumpWidget(harness(cart));

    // Five taps, each well inside the 300ms debounce window.
    for (var i = 1; i <= 5; i++) {
      await tester.tap(find.text('+'));
      await tester.pump(const Duration(milliseconds: 50));
      // The tap is on screen in the same frame it happened.
      expect(find.text('qty:$i'), findsOneWidget);
    }

    // ...and not one RPC has gone out yet.
    expect(sent, isEmpty);

    // Crucially: nothing DERIVED has moved. The badge, the money and the unit
    // count are still whatever the server last said (nothing), because the app
    // does not compute them.
    expect(find.text('badge:-'), findsOneWidget);
    expect(find.text('units:0'), findsOneWidget);
    // Compared as a number, not as rendered text: dart2js prints an integral
    // double as "500", the Dart VM as "500.0".
    expect(cart.netPayable, 0.0);

    await settle(tester);

    // Exactly one call, carrying the FINAL quantity.
    expect(sent.length, 1);
    expect(sent.single['p_product_id'], '101');
    expect(sent.single['p_quantity'], 5);

    // Now the server has spoken, the derived values move — all at once.
    expect(find.text('qty:5'), findsOneWidget);
    expect(find.text('badge:1'), findsOneWidget);
    expect(find.text('units:5'), findsOneWidget);
    expect(cart.netPayable, 500.0);
    await drain(tester);
  });

  testWidgets('the write response is the last word — nothing is re-read',
      (tester) async {
    final fns = <String>[];
    CartModel.rpcTransport = (fn, params) async {
      fns.add(fn);
      if (fn == 'cart_set_item') {
        return {
          'ok': true,
          'message': 'Cart updated',
          'cart': serverCart(qty: 1),
        };
      }
      return <String, dynamic>{};
    };

    final cart = CartModel.forTest();
    await tester.pumpWidget(harness(cart));
    await tester.tap(find.text('+'));
    await settle(tester);

    // The whole tap is ONE RPC. No cart_render to re-read what we were just
    // told, no get_my_cart for row metadata, no medicine_buyable_flags.
    expect(fns, ['cart_set_item']);
    expect(fns.contains('cart_render'), isFalse);
    expect(fns.contains('get_my_cart'), isFalse);
    expect(fns.contains('medicine_buyable_flags'), isFalse);

    // And the payload alone was enough to render the line completely.
    expect(cart.lines.single.product.category, 'CARDIAC');
    expect(cart.lines.single.product.isBuyable, isTrue);
    expect(cart.lines.single.cartItemId, 5771);
    await drain(tester);
  });

  testWidgets('a thrown call rolls back to the server quantity',
      (tester) async {
    var failNext = false;
    CartModel.rpcTransport = (fn, params) async {
      if (fn == 'cart_set_item') {
        if (failNext) throw Exception('offline');
        return {
          'ok': true,
          'message': 'Cart updated',
          'cart': serverCart(qty: params!['p_quantity'] as int),
        };
      }
      return <String, dynamic>{};
    };

    final cart = CartModel.forTest();
    await tester.pumpWidget(harness(cart));

    // Get the server to a known quantity of 2 first.
    await tester.tap(find.text('+'));
    await tester.tap(find.text('+'));
    await settle(tester);
    expect(find.text('qty:2'), findsOneWidget);

    // Now go offline and tap again.
    failNext = true;
    await tester.tap(find.text('+'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('qty:3'), findsOneWidget); // the tap showed
    await settle(tester);

    // ...and reverted to what the server actually holds, with the toast copy.
    expect(find.text('qty:2'), findsOneWidget);
    expect(cart.cartError.value, 'Could not update the cart. Please try again.');
    // The server's totals never moved through any of it.
    expect(find.text('units:2'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('a rejected write rolls back and keeps the server message',
      (tester) async {
    CartModel.rpcTransport = (fn, params) async {
      if (fn == 'cart_set_item') {
        return {'ok': false, 'message': 'No supplier for this product right now'};
      }
      return <String, dynamic>{};
    };

    final cart = CartModel.forTest();
    await tester.pumpWidget(harness(cart));
    await tester.tap(find.text('+'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('qty:1'), findsOneWidget);

    await settle(tester);

    expect(cart.cartError.value, 'No supplier for this product right now');
    expect(find.text('qty:0'), findsOneWidget);
    expect(cart.lines, isEmpty);
    await drain(tester);
  });

  testWidgets('taps during an in-flight call send only the latest quantity',
      (tester) async {
    final sent = <Map<String, dynamic>>[];
    final gates = <Completer<dynamic>>[];
    CartModel.rpcTransport = (fn, params) {
      if (fn == 'cart_set_item') {
        sent.add(params!);
        final gate = Completer<dynamic>();
        gates.add(gate);
        return gate.future;
      }
      return Future<dynamic>.value(<String, dynamic>{});
    };

    final cart = CartModel.forTest();
    await tester.pumpWidget(harness(cart));

    // One tap, let it go out, and hold the response open.
    await tester.tap(find.text('+'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(sent.length, 1);
    expect(sent[0]['p_quantity'], 1);

    // Three more taps while that call is still in flight.
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('+'));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 400));

    // Still only one call — the rest are parked behind it, not interleaved.
    expect(sent.length, 1);
    expect(find.text('qty:4'), findsOneWidget);

    // Release the first response; the parked quantity goes out as ONE call.
    gates[0].complete({
      'ok': true,
      'message': 'Cart updated',
      'cart': serverCart(qty: 1),
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(sent.length, 2);
    expect(sent[1]['p_quantity'], 4); // last write wins, nothing in between

    gates[1].complete({
      'ok': true,
      'message': 'Cart updated',
      'cart': serverCart(qty: 4),
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('qty:4'), findsOneWidget);
    expect(find.text('units:4'), findsOneWidget);
    await drain(tester);
  });
}
