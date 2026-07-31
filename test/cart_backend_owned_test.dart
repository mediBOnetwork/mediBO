import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  // The guest uuid is persisted with shared_preferences (never dart:html —
  // DEFENSIVE IMPORT RULE), so every test needs its mock store.
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
                Text('tier:${c.tierNote ?? '-'}'),
                Text('tierlabel:${c.tierLabel ?? '-'}'),
                Text('net:${c.netPayable}'),
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
            'gst_percent': 12,
            'line_total': 881.38 * qty,
            'line_mrp': 881.38 * qty,
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
        'mrp_total': 881.38 * qty,
        'tier_current': {
          'label': 'FREE delivery',
          'min_mrp': 999,
          'discount_pct': 0,
          'free_delivery': true,
        },
        'tier_next': {
          'label': '3% off',
          'min_mrp': 2999,
          'discount_pct': 3,
          'free_delivery': true,
        },
        'tier_label': 'FREE delivery',
        'tier_gap': 1236.24,
        'tier_progress': 0.382,
        'tier_note': 'Add ₹1236.24 more for 3% off',
        'discount_pct': 0,
        'discount_amount': 0,
        'delivery_fee': 0,
        'net_payable': 881.38 * qty,
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
    // CHANGE #610 — a stepper tap is now debounced for 300ms before it is
    // sent, so advance past that first; then flush the async RPC, then
    // RenderLog's own 800ms debounce timer.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // The write went to cart_set_item with quantity 1, never to cart_items.
    final setCalls = calls.where((c) => c.$1 == 'cart_set_item').toList();
    expect(setCalls.length, 1);
    expect(setCalls.single.$2!['p_product_id'], '101');
    expect(setCalls.single.$2!['p_quantity'], 1);

    // What renders is the SERVER's cart — quantity 2, which no local
    // increment-by-one could ever have produced from an empty cart.
    expect(find.text('line:Telvas 40:2'), findsOneWidget);
    expect(cart.quantityOf('101'), 2);

    // Every display string is the server's, verbatim.
    expect(find.text('badge:1'), findsOneWidget);
    expect(find.text('header:1 product in cart'), findsOneWidget);
    expect(find.text('cta:1 item'), findsOneWidget);
    expect(find.text('tier:Add ₹1236.24 more for 3% off'), findsOneWidget);
    expect(find.text('tierlabel:FREE delivery'), findsOneWidget);

    // The tier ladder is the server's: current/next/gap/progress, no Dart maths.
    expect(cart.tierNextLabel, '3% off');
    expect(cart.tierNextPct, 3);
    expect(cart.tierGap, 1236.24);
    expect(cart.tierProgress, 0.382);
    expect(cart.tierMaxed, isFalse);

    // Money is the server's too, including per-line GST.
    expect(cart.netPayable, 1762.76);
    expect(cart.mrpTotal, 1762.76);
    expect(cart.deliveryFee, 0);
    expect(cart.lines.single.product.gstPercent, 12);
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
    // CHANGE #610 — a stepper tap is now debounced for 300ms before it is
    // sent, so advance past that first; then flush the async RPC, then
    // RenderLog's own 800ms debounce timer.
    await tester.pump(const Duration(milliseconds: 400));
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
    // CHANGE #610 — a stepper tap is now debounced for 300ms before it is
    // sent, so advance past that first; then flush the async RPC, then
    // RenderLog's own 800ms debounce timer.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(cart.cartError.value, 'No supplier for this product right now');
    // The rejected product never appears in the cart.
    expect(find.textContaining('line:'), findsNothing);
  });

  testWidgets('logged out, the guest uuid is sent to every cart RPC',
      (tester) async {
    final calls = <(String, Map<String, dynamic>?)>[];
    CartModel.rpcTransport = (fn, params) async {
      calls.add((fn, params));
      if (fn == 'cart_set_item') {
        return {'ok': true, 'message': 'Cart updated', 'cart': serverCart(qty: 1)};
      }
      return <String, dynamic>{};
    };

    final cart = CartModel.forTest();
    await tester.pumpWidget(harness(cart, product));
    await tester.tap(find.text('Add to cart'));
    // CHANGE #610 — clear the 300ms stepper debounce before the RPC is sent.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // A guest uuid was minted and passed as p_guest_uid, so the row is filed
    // server-side rather than kept in a local cart.
    final set = calls.firstWhere((c) => c.$1 == 'cart_set_item');
    final guest = set.$2!['p_guest_uid'] as String?;
    expect(guest, isNotNull);
    expect(guest, matches(RegExp(r'^[0-9a-f-]{36}$')));

    // A later read reuses the SAME id — one guest, one cart.
    await cart.refresh();
    await tester.pump(const Duration(seconds: 1));
    // CHANGE #582 renamed the read to cart_render() (cart_state plus display
    // strings); this assertion still named the old RPC and had been failing
    // ever since. It is the same read, under the name it actually has.
    final read = calls.lastWhere((c) => c.$1 == 'cart_render');
    expect(read.$2!['p_guest_uid'], guest);

    // And it survives as the persisted identity, not as cart contents.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('medibo_guest_uid'), guest);
    expect(prefs.getKeys().any((k) => k.contains('cart_items')), isFalse);
    // Drain RenderLog's debounce so no timer outlives the test.
    await tester.pump(const Duration(seconds: 1));
  });
}
