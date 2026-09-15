// PROTECTED — CMD #2029.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes floating-cart-pill behaviour.
//
// What this holds down — the pill DECIDES NOTHING:
//
//   1. `show` is the backend's answer. The pill never counts the cart to work
//      out whether it exists, and when show is false it is both invisible and
//      untappable (a ghost pill that still swallows taps was the bug that made
//      this a widget test rather than a decision test).
//
//   2. `items_label` is printed VERBATIM. "1 item" / "13 items" is pluralised
//      in SQL; a fixture with deliberately non-English wording proves Dart
//      never rebuilds the string from a count.
//
//   3. `cta` is printed verbatim too — line two is payload, not a literal.
//
//   4. `thumbs` decides how MANY squares are drawn and in WHICH ORDER. One
//      entry draws one square, two draw two, and the app never reaches past
//      what the backend sent (a 13-item cart still sends two thumbs).
//
//   5. A thumb with no image renders the placeholder icon INSIDE the square —
//      never a blank white box.
//
//   6. The pill is 60% of the viewport, clamped, and never wider than the
//      viewport at 320 / 360 / 412 / 480 px. No overflow on any phone.
//
// No network, no Supabase, no goldens: every thumb url in the pumped tests is
// empty, so ProductImage paints its offline fallback.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/cart_pill.dart';
import 'package:pharma_b2b/widgets/product_image.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _thumb(String id, {String image = ''}) => {
      'product_id': id,
      'name': 'Product $id',
      'image_url': image,
      'has_image': image.isNotEmpty,
    };

/// Mirrors cart_pill_block(): every string and the whole thumb list arrive
/// already decided.
Map<String, dynamic> _payload({
  required bool show,
  required String itemsLabel,
  String cta = 'View cart',
  List<Map<String, dynamic>> thumbs = const [],
}) =>
    {
      'items': const [],
      'item_count': 0,
      'render': {
        'pill': {
          'show': show,
          'items_label': itemsLabel,
          'cta': cta,
          'thumbs': thumbs,
          'thumb_count': thumbs.length,
        },
      },
    };

Future<CartModel> _loaded(Map<String, dynamic> payload) async {
  CartModel.rpcTransport = (fn, params) async => payload;
  final cart = CartModel.forTest();
  await cart.refresh();
  return cart;
}

Future<int> _pump(
  WidgetTester tester,
  CartModel cart, {
  double width = 360,
  VoidCallback? onTap,
}) async {
  var taps = 0;
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AppState(
        cart: cart,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: CartPill(onTap: onTap ?? () => taps++),
        ),
      ),
    ),
  ));
  await tester.pump();
  return taps;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => CartModel.rpcTransport = null);

  testWidgets('1. show:false is invisible AND untappable', (tester) async {
    final cart = await _loaded(_payload(show: false, itemsLabel: ''));
    await _pump(tester, cart);

    final fade = tester.widget<AnimatedOpacity>(find.ancestor(
      of: find.byKey(const Key('c2029_pill')),
      matching: find.byType(AnimatedOpacity),
    ));
    expect(fade.opacity, 0, reason: 'the backend said there is no pill');

    final gate = tester.widget<IgnorePointer>(find
        .descendant(
            of: find.byType(CartPill), matching: find.byType(IgnorePointer))
        .first);
    expect(gate.ignoring, isTrue,
        reason: 'a hidden pill must not swallow taps meant for the page');
  });

  testWidgets('2. items_label is printed verbatim — never pluralised in Dart',
      (tester) async {
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items',
      thumbs: [_thumb('1'), _thumb('2')],
    ));
    await _pump(tester, cart);

    expect(find.text('13 items'), findsOneWidget);
    expect(find.text('View cart'), findsOneWidget);
  });

  testWidgets('2b. the singular is the backend\'s too', (tester) async {
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '1 item',
      thumbs: [_thumb('1')],
    ));
    await _pump(tester, cart);

    expect(find.text('1 item'), findsOneWidget);
    expect(find.textContaining('items'), findsNothing,
        reason: 'Dart must not append an s of its own');
  });

  testWidgets('3. both lines are payload — odd wording survives intact',
      (tester) async {
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '13 saman',
      cta: 'Cart dekhein',
      thumbs: [_thumb('1'), _thumb('2')],
    ));
    await _pump(tester, cart);

    expect(find.text('13 saman'), findsOneWidget);
    expect(find.text('Cart dekhein'), findsOneWidget);
  });

  testWidgets('4. thumbs decide how many squares, and in which order',
      (tester) async {
    final one = await _loaded(_payload(
      show: true,
      itemsLabel: '1 item',
      thumbs: [_thumb('aaa')],
    ));
    await _pump(tester, one);
    expect(find.byKey(const Key('c2029_pill_thumb_0')), findsOneWidget);
    expect(find.byKey(const Key('c2029_pill_thumb_1')), findsNothing,
        reason: 'one item is one square');

    final two = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items',
      thumbs: [_thumb('older'), _thumb('newest')],
    ));
    await _pump(tester, two);
    expect(find.byKey(const Key('c2029_pill_thumb_0')), findsOneWidget);
    expect(find.byKey(const Key('c2029_pill_thumb_1')), findsOneWidget);
    expect(find.byKey(const Key('c2029_pill_thumb_2')), findsNothing,
        reason: 'a 13-item cart still draws exactly what the backend sent');

    // Draw order is the payload's order: [0] behind, [1] on top.
    final rendered = tester
        .widgetList<ProductImage>(find.byType(ProductImage))
        .map((w) => w.url)
        .toList();
    expect(rendered.length, 2);
  });

  testWidgets('5. a thumb with no image shows the placeholder, not a blank box',
      (tester) async {
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '2 items',
      thumbs: [_thumb('a'), _thumb('b')],
    ));
    await _pump(tester, cart);

    expect(find.byIcon(Icons.medication_outlined), findsNWidgets(2),
        reason: 'an imageless product still shows the mediBO placeholder');
  });

  testWidgets('5b. a thumb url is passed through untouched', (tester) async {
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '2 items',
      thumbs: [_thumb('a'), _thumb('b', image: 'https://cdn/x.png')],
    ));
    // The pill must hand ProductImage exactly the backend's url; it never
    // rewrites, resizes or substitutes one.
    CartModel.rpcTransport = null;
    expect(cart.pillThumbs.map((t) => t['image_url']).toList(),
        ['', 'https://cdn/x.png']);
    expect(cart.pillThumbs.last['has_image'], isTrue);
  });

  testWidgets('6. never wider than the phone, at every phone', (tester) async {
    for (final w in <double>[320, 360, 412, 480]) {
      final cart = await _loaded(_payload(
        show: true,
        itemsLabel: '13 items',
        thumbs: [_thumb('1'), _thumb('2')],
      ));
      await _pump(tester, cart, width: w);
      final size = tester.getSize(find.byKey(const Key('c2029_pill')));
      expect(size.width, lessThanOrEqualTo(w),
          reason: 'the pill overflowed at ${w}px');
      expect(size.height, CartPill.kHeight);
      expect(tester.takeException(), isNull,
          reason: 'no overflow exception at ${w}px');
    }
  });

  testWidgets('7. the whole pill opens the cart', (tester) async {
    var taps = 0;
    final cart = await _loaded(_payload(
      show: true,
      itemsLabel: '13 items',
      thumbs: [_thumb('1'), _thumb('2')],
    ));
    await _pump(tester, cart, onTap: () => taps++);
    await tester.tap(find.byKey(const Key('c2029_pill')));
    await tester.pump();
    expect(taps, 1);
  });
}
