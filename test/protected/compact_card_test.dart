// PROTECTED — CHANGE #636, rewritten by CHANGE #673.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes compact-card behaviour, never to make an unrelated
// change go green. #673 rebuilt the card's shape, so this file was rewritten
// with it — the RULES below are unchanged, only the geometry and the widget
// names moved.
//
// What this holds down:
//
//   1. The card prints backend strings and computes nothing. The price, the
//      struck MRP, the margin ribbon, the offer chip and the ADD label all
//      arrive rendered from storefront_pricing() / storefront_cta(). The card
//      that this one replaced had a `_SchemePill` that showed a "5+1" badge for
//      ~30% of products, chosen from a hash of the product id — the app
//      answering a question ("what scheme does this have?") only the backend
//      can answer. A ribbon must never appear unless the payload sent one.
//
//   2. The ribbon is TWO explicit backend fields (ribbon_top / ribbon_bottom),
//      never one string split in Dart, and never derived from discount_label.
//      Same for the offer chip, which is gated on the boolean `has_offer` and
//      not on "offer_chip is non-empty" — an offer is a fact about the product,
//      not about the payload.
//
//   3. This is B2B. The number on the card is a PTR and the word above it is
//      pricing.price_caption from the backend, because what the number IS is a
//      business decision. Nothing here may type "PTR", "MRP" or "% off".
//
//   4. ADD ⇄ stepper morphs in place off the CART's own quantity, and the ADD
//      label is availability.cta_label verbatim — not the word "ADD" typed
//      here.
//
//   5. Out of stock is the backend's `can_add:false` verdict, never a stock
//      number or a supplier count compared in Dart. In that state the card
//      offers no cart control at all.
//
//   6. The manufacturer line is gone from the card — it belongs to the product
//      page. Its return would push the card past the grid's fixed extent.
//
// Fixtures mirror a real storefront_page() row. No network, no Supabase, no
// camera.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';

/// A fabricated storefront_page() row — the exact shape Product.fromMap reads.
///
/// The pricing block is what storefront_pricing() really returns for a B2B
/// buyer: a PTR, the MRP it is struck against, and the MARGIN the pharmacy
/// earns. It is deliberately NOT a consumer "% off" payload.
Map<String, dynamic> _row({
  bool canAdd = true,
  String ctaLabel = 'Add to cart',
  bool hasPrice = true,
  bool hasDiscount = true,
  bool hasOffer = true,
}) =>
    {
      'id': 176026,
      'product_name': 'Alkacel 100mg Injection',
      'marketer': 'CELON LABORATORIES LTD',
      'salt_composition': 'Paclitaxel (100mg)',
      'therapeutic_class': 'ANTI NEOPLASTICS',
      'pack_size': 'Vial of 1 Injection',
      'pack_type': 'Vial',
      'image_url_1': '',
      'mrp': '2597',
      'has_offer': hasOffer,
      'offer_chip': hasOffer ? 'Scheme available' : '',
      'availability': {
        'is_available': canAdd,
        'can_add': canAdd,
        'cta_label': ctaLabel,
        'gated': true,
        if (!canAdd) 'note': 'No supplier for this product right now',
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      },
      'pricing': {
        'has_price': hasPrice,
        'mrp': 2597,
        'sale_price': 2337.30,
        'price_display': hasPrice ? '₹2,337.30' : '',
        'mrp_display': hasPrice ? '₹2,597.00' : '',
        'discount_pct': hasDiscount ? 10 : 0,
        'has_discount': hasPrice && hasDiscount,
        'discount_label': (hasPrice && hasDiscount) ? '10% margin' : '',
        'price_caption': hasPrice ? 'PTR' : '',
        'ribbon_top': (hasPrice && hasDiscount) ? '10%' : '',
        'ribbon_bottom': (hasPrice && hasDiscount) ? 'MARGIN' : '',
        'margin_label': (hasPrice && hasDiscount) ? 'You earn ₹259.70' : '',
      },
    };

Future<CartModel> _pump(WidgetTester tester, Map<String, dynamic> row) async {
  final cart = CartModel.forTest();
  await tester.pumpWidget(
    AppState(
      cart: cart,
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: CompactProductCard.extent,
            child: CompactProductCard(
              product: Product.fromMap(row),
              onTap: () {},
            ),
          ),
        ),
      ),
    ),
  );
  return cart;
}

void main() {
  // Every cart write in these tests goes through the fake transport, so
  // nothing ever reaches Supabase.
  setUp(() {
    CartModel.rpcTransport = (fn, params) async =>
        {'ok': true, 'message': '', 'cart': <String, dynamic>{}};
  });
  tearDown(() => CartModel.rpcTransport = null);

  group('the card prints backend strings', () {
    testWidgets('name, pack and form chip are verbatim', (tester) async {
      await _pump(tester, _row());

      expect(find.text('Alkacel 100mg Injection'), findsOneWidget);
      expect(find.text('Vial of 1 Injection'), findsOneWidget);
      expect(find.text('Vial'), findsOneWidget, reason: 'form chip = pack_type');
    });

    testWidgets('price and struck MRP are the rendered strings', (tester) async {
      await _pump(tester, _row());

      expect(find.text('₹2,337.30'), findsOneWidget,
          reason: 'price_display verbatim — never mrp × (1 - pct)');
      expect(find.text('₹2,597.00'), findsOneWidget,
          reason: 'mrp_display verbatim');
    });

    testWidgets('the price caption is a backend word, never "PTR" typed here',
        (tester) async {
      await _pump(tester, _row());
      expect(find.text('PTR'), findsOneWidget,
          reason: 'pricing.price_caption — B2B does not buy at MRP');

      // Reword it in Postgres and the card follows. If "PTR" were a Dart
      // literal this second pump would still show it.
      final r = _row();
      (r['pricing'] as Map<String, dynamic>)['price_caption'] = 'NET RATE';
      await _pump(tester, r);
      expect(find.text('NET RATE'), findsOneWidget);
      expect(find.text('PTR'), findsNothing);
    });

    testWidgets(
        'the ribbon is ribbon_top + ribbon_bottom, and only when the '
        'payload sent both', (tester) async {
      await _pump(tester, _row());
      expect(find.text('10%'), findsOneWidget);
      expect(find.text('MARGIN'), findsOneWidget,
          reason: 'two explicit backend fields — never one string split here');

      await _pump(tester, _row(hasDiscount: false));
      expect(find.text('10%'), findsNothing);
      expect(find.text('MARGIN'), findsNothing,
          reason: 'no margin block means NO ribbon — never an invented one');
    });

    testWidgets('the ribbon never renders from discount_label alone',
        (tester) async {
      // A payload that carries the sentence but not the two ribbon fields must
      // draw no ribbon. This is the exact shape the pre-#673 payload had, and
      // reconstructing a ribbon from it would be the card deciding.
      final r = _row();
      final p = r['pricing'] as Map<String, dynamic>;
      p['ribbon_top'] = '';
      p['ribbon_bottom'] = '';
      await _pump(tester, r);

      expect(find.text('10% margin'), findsNothing);
      expect(find.text('MARGIN'), findsNothing);
    });

    testWidgets('the offer chip is gated on has_offer, not on the string',
        (tester) async {
      await _pump(tester, _row());
      expect(find.text('Scheme available'), findsOneWidget,
          reason: 'offer_chip verbatim');

      await _pump(tester, _row(hasOffer: false));
      expect(find.text('Scheme available'), findsNothing);

      // has_offer:false with a stale string still present — the boolean wins.
      final r = _row(hasOffer: false);
      r['offer_chip'] = 'Scheme available';
      await _pump(tester, r);
      expect(find.text('Scheme available'), findsNothing,
          reason: 'an offer is a fact about the product, not about the payload');
    });

    testWidgets('has_price:false shows no price at all', (tester) async {
      await _pump(tester, _row(hasPrice: false));
      expect(find.textContaining('₹'), findsNothing,
          reason: '9.7% of the catalogue has no MRP; ₹0.00 reads as free');
    });

    testWidgets('the manufacturer line is NOT on the card', (tester) async {
      await _pump(tester, _row());
      expect(find.text('CELON LABORATORIES LTD'), findsNothing);
      expect(find.text('CELON LABORATORIES LTD'.toUpperCase()), findsNothing,
          reason: 'the manufacturer moved to the product page in #636');
    });

    testWidgets('the composition line is NOT on the card', (tester) async {
      await _pump(tester, _row());
      expect(find.text('Paclitaxel (100mg)'), findsNothing);
    });
  });

  group('ADD ⇄ stepper', () {
    testWidgets('the ADD label is cta_label verbatim', (tester) async {
      await _pump(tester, _row());
      expect(find.text('Add to cart'), findsOneWidget);

      // Reword it in Postgres and the button follows.
      await _pump(tester, _row(ctaLabel: 'Order now'));
      expect(find.text('Order now'), findsOneWidget);
      expect(find.text('Add to cart'), findsNothing);
    });

    testWidgets('tapping ADD morphs the control into the stepper',
        (tester) async {
      final cart = await _pump(tester, _row());

      expect(find.text('Add to cart'), findsOneWidget);
      expect(find.byIcon(Icons.remove_rounded), findsNothing);

      await tester.tap(find.text('Add to cart'));
      await tester.pumpAndSettle();

      expect(cart.quantityOf('176026'), 1);
      expect(find.text('1'), findsOneWidget, reason: 'the stepper qty');
      expect(find.byIcon(Icons.remove_rounded), findsOneWidget);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      expect(find.text('Add to cart'), findsNothing,
          reason: 'ADD morphs in place — the two never show at once');
    });

    testWidgets('+ and − drive the cart quantity', (tester) async {
      final cart = await _pump(tester, _row());

      await tester.tap(find.text('Add to cart'));
      await tester.pumpAndSettle();
      expect(cart.quantityOf('176026'), 1);

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      expect(cart.quantityOf('176026'), 2);

      await tester.tap(find.byIcon(Icons.remove_rounded));
      await tester.pumpAndSettle();
      expect(cart.quantityOf('176026'), 1);
    });
  });

  group('out of stock is the backend verdict', () {
    testWidgets('can_add:false offers no ADD control', (tester) async {
      await _pump(tester, _row(canAdd: false, ctaLabel: 'Unavailable'));

      // Re-pointed in #673: the ADD pill stopped being an OutlinedButton, so
      // asserting on OutlinedButton would now pass without proving anything.
      // The real control is CompactCartControl — the only widget in the card
      // that can write to the cart.
      expect(find.byType(CompactCartControl), findsNothing,
          reason: 'can_add:false means no path into the cart at all');
      expect(find.text('Add to cart'), findsNothing,
          reason: 'and no dead ADD label left behind');
    });

    testWidgets('the sold-out chip is the backend label, not "Out of Stock" '
        'typed here', (tester) async {
      await _pump(tester, _row(canAdd: false, ctaLabel: 'Unavailable'));
      expect(find.text('Unavailable'), findsOneWidget);

      await _pump(tester, _row(canAdd: false, ctaLabel: 'No suppliers'));
      expect(find.text('No suppliers'), findsOneWidget);
      expect(find.text('Unavailable'), findsNothing);
    });

    testWidgets('the sold-out card is dimmed', (tester) async {
      await _pump(tester, _row(canAdd: false, ctaLabel: 'Unavailable'));

      final op = tester.widgetList<Opacity>(find.byType(Opacity));
      expect(op.any((o) => o.opacity == 0.45), isTrue,
          reason: 'sold-out content renders at 45%');
    });

    testWidgets('an in-stock card is not dimmed', (tester) async {
      await _pump(tester, _row());

      final op = tester.widgetList<Opacity>(find.byType(Opacity));
      expect(op.any((o) => o.opacity == 0.45), isFalse);
    });
  });

  group('fixed geometry', () {
    test('the grid extent is the sum of the parts the card lays out', () {
      // The old card duplicated a hardcoded 365 in the grid AND the skeleton,
      // so a taller card overflowed silently in both. The extent is now
      // derived, and this pins that it stays derived.
      //
      // #673 sum: plate + pill overhang + 6 + form chip + 6 + two name lines
      //           + 4 + price row + 4 + offer chip.
      expect(CompactProductCard.extent, 292);
      expect(CompactProductCard.extent,
          greaterThan(CompactProductCard.tileH + CompactProductCard.pillH),
          reason: 'the text block below the plate must be real, not clipped');
    });

    test('the extent is a constant, not a function of the viewport', () {
      // Four callers (two rails, two grids) reserve this one number. If it ever
      // became width-derived, the grid's reserved height would differ from the
      // card's real height on some phones and every tile would overflow.
      expect(CompactProductCard.extent, isA<double>());
      expect(CompactProductCard.tileH, 160);
    });

    testWidgets('the card never overflows the extent the grid reserves',
        (tester) async {
      await _pump(tester, _row());
      expect(tester.takeException(), isNull,
          reason: 'a RenderFlex overflow would surface here');
    });
  });
}
