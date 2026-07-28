import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';

/// CHANGE #559 — the cart lives in the backend.
///
/// A DB audit trigger proved the old cart never reached the database: items
/// went into an in-memory map, the badge and totals were computed in Dart, and
/// nothing was written. These tests pin the new contract:
///
///   * "Add to cart" calls `cart_set_item(productId, 1)`.
///   * What renders is the cart the SERVER returned, not a local guess.
///   * When the server returns no lines, no line renders — even after a tap.
///     There is no optimistic update to fall back on.
void main() {
  /// Renders the cart the way the real screens do: lines, badge, header and
  /// the "N items" pill all come off CartModel, which owns nothing itself.
  Widget harness(CartModel cart, Product product) {
    return MaterialApp(
      home: AppState(
        cart: cart,
        child: Builder(builder: (context) {
          final c = AppState.of(context);
          return Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => c.add(product),
                  child: const Text('Add to cart'),
                ),
                Text('badge:${c.badge ?? '-'}'),
                Text('header:${c.header ?? '-'}'),
                Text('cta:${c.ctaLabel ?? '-'}'),
                Text('delivery:${c.deliveryNote ?? '-'}'),
                for (final l in c.lines)
                  Text('line:${l.product.name}:${l.quantity}'),
              ],
            ),
          );
        }),
      ),
    );
  }

  final product = Product.fromCartData(
    id: '101',
    name: 'Telvas 40',
    b2bPrice: 881.38,
    mrp: 881.38,
  );

  /// A cart_state() payload shaped exactly like the live RPC returns.
  Map<String, dynamic> serverCart({required int qty}) => {
        'items': [
          {
            'product_id': '101',
            'product_name': 'Telvas 40',
            'quantity': qty,
            'price': 881.38,
            'mrp': 881.38,
            'image_url': '',
            'manufacturer': 'Aristo',
            'pack_size': '10 tab',
            'line_total': 881.38 * qty,
          }
        ],
        'item_count': 1,
        'unit_count': qty,
        'total': 881.38 * qty,
        'header': '1 product in cart',
        'badge': '1',
        'cta_label': '1 item',
        'empty_title': 'Your cart is empty',
        'empty_note': 'Add products from the catalog to start an order.',
        'delivery_note': 'You have FREE delivery',
        'delivery_progress': 1,
      };

  tearDown(() => CartModel.rpcTransport = null);

  testWidgets('Add to cart calls cart_set_item and renders the returned cart',
      (tester) async {
    final calls = <(String, Map<String, dynamic>?)>[];
    CartModel.rpcTransport = (fn, params) async {
      calls.add((fn, params));
      if (fn == 'cart_set_item') {
        return {'ok': true, 'message': 'Cart updated', 'cart': serverCart(qty: 2)};
      }
      return <String, dynamic>{};
    };

    final cart = CartModel.forTest();
    await tester.pumpWidget(harness(cart, product));

    // Nothing before the tap — the server has reported no cart.
    expect(find.textContaining('line:'), findsNothing);

    await tester.tap(find.text('Add to cart'));
    // Flush the async RPC, then RenderLog's 800ms debounce timer.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // The write went to cart_set_item with quantity 1, never to cart_items.
    final setCalls = calls.where((c) => c.$1 == 'cart_set_item').toList();
    expect(setCalls.length, 1);
    expect(setCalls.single.$2, {'p_product_id': '101', 'p_quantity': 1});

    // What renders is the SERVER's cart — quantity 2, which no local
    // increment-by-one could ever have produced from an empty cart.
    expect(find.text('line:Telvas 40:2'), findsOneWidget);
    expect(cart.quantityOf('101'), 2);

    // Every display string is the server's, verbatim.
    expect(find.text('badge:1'), findsOneWidget);
    expect(find.text('header:1 product in cart'), findsOneWidget);
    expect(find.text('cta:1 item'), findsOneWidget);
    expect(find.text('delivery:You have FREE delivery'), findsOneWidget);
  });

  testWidgets('no cart line is rendered from local state', (tester) async {
    // The server accepts the write but reports an EMPTY cart. A client that
    // kept its own cart would show a line here; this one must show none.
    CartModel.rpcTransport = (fn, params) async {
      if (fn == 'cart_set_item') {
        return {
          'ok': true,
          'message': 'Cart updated',
          'cart': {
            'items': const [],
            'item_count': 0,
            'unit_count': 0,
            'total': 0,
            'empty_title': 'Your cart is empty',
            'empty_note': 'Add products from the catalog to start an order.',
          },
        };
      }
      return <String, dynamic>{};
    };

    final cart = CartModel.forTest();
    await tester.pumpWidget(harness(cart, product));
    await tester.tap(find.text('Add to cart'));
    // Flush the async RPC, then RenderLog's 800ms debounce timer.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('line:'), findsNothing);
    expect(cart.quantityOf('101'), 0);
    expect(cart.distinctItems, 0);
    expect(find.text('badge:-'), findsOneWidget);
  });

  testWidgets('a rejected write surfaces the server message verbatim',
      (tester) async {
    CartModel.rpcTransport = (fn, params) async {
      if (fn == 'cart_set_item') {
        return {'ok': false, 'message': 'No supplier for this product right now'};
      }
      return <String, dynamic>{};
    };

    final cart = CartModel.forTest();
    await tester.pumpWidget(harness(cart, product));
    await tester.tap(find.text('Add to cart'));
    // Flush the async RPC, then RenderLog's 800ms debounce timer.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(cart.cartError.value, 'No supplier for this product right now');
    // The rejected product never appears in the cart.
    expect(find.textContaining('line:'), findsNothing);
  });
}
