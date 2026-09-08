// PROTECTED — CHANGE #636, rewritten by #673, by #274, and again by CMD #1895.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes compact-card behaviour, never to make an unrelated
// change go green. #1895 rebuilt the card to Om's 08-Sep sketch, so this file
// moved with it. The rules it REVERSES are called out below; everything else
// is unchanged and simply re-pointed.
//
// What this holds down:
//
//   1. The card prints backend strings and computes nothing. Name, pack
//      sentence, type chip, company, MRP, the sale line and the ADD word all
//      arrive rendered from storefront_pricing() / storefront_cta(). The card
//      three generations back had a `_SchemePill` that showed a "5+1" badge
//      for ~30% of products, chosen from a hash of the product id — the app
//      answering a question ("what scheme does this have?") only the backend
//      can answer. A badge must never appear unless the payload sent one.
//
//   2. The ribbon is TWO explicit backend fields (ribbon_top / ribbon_bottom),
//      never one string split in Dart, and never derived from discount_label.
//      Same for the scheme badge, gated on a boolean (`has_scheme` /
//      `has_offer`) and not on "the string is non-empty" — an offer is a fact
//      about the product, not about the payload.
//
//   3. **ONE FIELD IS THE SALE LINE.** `card_price.price_display` is either
//      the formatted trade amount or the literal word "PTR", and the card
//      prints whichever arrived. There is no approval check in Dart, no
//      arithmetic and no second branch: the string that says "this viewer may
//      not see the rate" and the string that says "₹2,337.30" are the same
//      field. Nothing here may type "PTR", "MRP", "% OFF" or "Best offer".
//
//   4. **A WITHHELD PTR IS NOT HIDDEN IN FLUTTER — IT NEVER ARRIVES.** A
//      locked payload carries no `ptr_display` at all; it carries the WORD in
//      price_display. The matching server-side half is the
//      `storefront_ptr_entitlement` regression guard, which proves an
//      anonymous viewer's payload carries no PTR number. This test is the
//      client half: given a withheld payload, the card reveals nothing.
//
//   5. REVERSED BY #1895 — the "Register and get approved to see trade prices"
//      SENTENCE is no longer on the card. It was a third line of copy on every
//      card an unapproved visitor saw. Tapping the locked word opens the
//      backend's prompt, and that prompt's title, sentence, button word and
//      ROUTE are all payload strings.
//
//   6. REVERSED BY #1895 — the MRP is struck whether or not a trade price sits
//      under it. It is the printed pack ceiling, and it is shown to everyone,
//      including a visitor who is not signed in. The card still follows
//      `strike_mrp` rather than deciding: the backend simply always sends it.
//
//   7. ADD ⇄ stepper morphs in place off the CART's own quantity. The label is
//      `availability.cta_short` verbatim, falling back to `cta_label` — never
//      the word "ADD" typed here, and never `cta_label` truncated in Dart.
//
//   8. Out of stock is the backend's `can_add:false` verdict, never a stock
//      number or a supplier count compared in Dart. In that state the card
//      offers no cart control at all.
//
//   9. The company line IS on the card (under the name, #274). The
//      composition line is not.
//
//  10. **THE TWO PACK STRINGS SWAPPED PLACES AGAIN (#1895), and each is still
//      a SEPARATE backend key.** `pack_qty_label` — MEDICINE.pack_qty
//      VERBATIM, the long stored sentence — is ON the plate now, in its
//      full-width footer strip, which is what stopped it being ellipsised as
//      "10 tablet er…". `pack_type_label` (one word) is the chip in the row
//      under the plate, beside the ADD control. An EMPTY label draws nothing
//      rather than falling back to another column; the card must never choose
//      between pack_qty / pack_size / pack_type again.
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
/// The pricing block is what storefront_pricing() really returns for a viewer
/// ENTITLED to trade prices: a PTR, the MRP it is struck against, and the
/// margin the pharmacy earns. It is deliberately NOT a consumer "% off"
/// payload. Pass `entitled: false` for the shape an unapproved visitor gets —
/// note that the ptr keys are ABSENT, not empty, exactly as Postgres sends it.
Map<String, dynamic> _row({
  bool canAdd = true,
  String ctaLabel = 'Add to cart',
  String ctaShort = 'ADD',
  bool hasPrice = true,
  bool hasDiscount = true,
  bool hasOffer = true,
  bool entitled = true,
}) =>
    {
      'id': 176026,
      'product_name': 'Alkacel 100mg Injection',
      'marketer': 'CELON LABORATORIES LTD',
      'salt_composition': 'Paclitaxel (100mg)',
      'therapeutic_class': 'ANTI NEOPLASTICS',
      'pack_qty': '1 injection',
      'pack_size': 'Vial of 1 Injection',
      'pack_type': 'Vial',
      // CHANGE #287 — the two decided labels every storefront card RPC sends.
      // Deliberately NOT equal to any raw column above: a card that renders
      // one of those instead of these fails.
      'pack_qty_label': '1.0 Injection in 1 vial',
      'pack_type_label': 'Vial',
      'image_url_1': '',
      'mrp': '2597',
      'has_offer': hasOffer,
      'offer_chip': hasOffer ? 'Scheme available' : '',
      'availability': {
        'is_available': canAdd,
        'can_add': canAdd,
        'cta_label': ctaLabel,
        'cta_short': ctaShort,
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
        'card_price': {
          'has_mrp': hasPrice,
          'mrp_label': hasPrice ? 'MRP' : '',
          'mrp_display': hasPrice ? '₹2,597.00' : '',
          // #1895 — struck for everyone: the ceiling is a fact about the pack.
          'strike_mrp': hasPrice,
          'has_ptr': hasPrice && entitled,
          // The withheld payload carries NEITHER key — this is the shape the
          // RPC really sends, and the whole point of rule 4.
          if (hasPrice && entitled) 'ptr_label': 'PTR',
          if (hasPrice && entitled) 'ptr_display': '₹2,337.30',
          if (hasPrice && entitled) 'ptr_bg': '#1B7A43',
          if (hasPrice && entitled) 'ptr_fg': '#FFFFFF',
          // #1895 — the ONE field the sale line prints, either way.
          'price_display':
              (hasPrice && entitled) ? '₹2,337.30' : 'PTR',
          'price_locked': !(hasPrice && entitled),
          if (!(hasPrice && entitled)) ...{
            'locked_title': 'Trade price',
            'locked_note': 'Register and get approved to see trade prices',
            'locked_cta': 'Register now',
            'locked_route': '/register',
          },
          // #1895 — the sentence LEFT the card. The backend sends the block
          // with the note switched off, and this fixture is that shape.
          'has_note': false,
          'note': '',
        },
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
    testWidgets('name, pack type and pack quantity are verbatim', (tester) async {
      await _pump(tester, _row());

      expect(find.text('Alkacel 100mg Injection'), findsOneWidget);
      // #1895 — the chip in the row under the plate takes pack_type_label…
      expect(find.text('Vial'), findsOneWidget,
          reason: 'the chip beside the ADD control is pack_type_label');
      // …and the plate's own footer strip takes pack_qty_label, VERBATIM: the
      // long stored sentence, not the shortened '1 injection' badge.
      expect(find.text('1.0 Injection in 1 vial'), findsOneWidget,
          reason: 'the strip on the image is pack_qty_label, stored verbatim');
      expect(find.text('1 injection'), findsNothing,
          reason: 'the shortened badge is not what #287 prints on the card');
    });

    testWidgets('the two pack strings are the LABELS, not the raw columns',
        (tester) async {
      // The catalogue's three pack columns disagree with each other and are
      // re-keyed by two feed RPCs. The card reads neither: it prints what the
      // backend decided. Give the labels values no raw column holds.
      final r = _row();
      r['pack_qty_label'] = 'ZZ qty label';
      r['pack_type_label'] = 'ZZtype';
      await _pump(tester, r);

      expect(find.text('ZZ qty label'), findsOneWidget);
      expect(find.text('ZZtype'), findsOneWidget);
      expect(find.text('Vial of 1 Injection'), findsNothing);
    });

    testWidgets('an empty pack_qty_label prints nothing on the plate',
        (tester) async {
      // Most `Piece` rows carry no pack_qty. Om's rule, unchanged since #287:
      // print nothing — never fall back to pack_size, never a placeholder.
      final r = _row();
      r['pack_qty_label'] = '';
      await _pump(tester, r);

      expect(find.byType(Chip), findsNothing);
      expect(find.text('1.0 Injection in 1 vial'), findsNothing);
      expect(find.text('Vial of 1 Injection'), findsNothing);
      // the one-word type still prints in the row beside the ADD control
      expect(find.text('Vial'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty pack_type_label draws no chip at all',
        (tester) async {
      // The other half of the same rule, on the string that moved in #1895.
      final r = _row();
      r['pack_type_label'] = '';
      await _pump(tester, r);

      expect(find.text('Vial'), findsNothing);
      expect(find.text('Vial of 1 Injection'), findsNothing,
          reason: 'an empty label is empty — it never falls back to pack_size');
      // the pack sentence on the plate is untouched by it
      expect(find.text('1.0 Injection in 1 vial'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an absent label falls back — a cached payload is never blank',
        (tester) async {
      // The offline cache and the outage fallbacks predate #287 and carry no
      // label keys at all. ABSENT is not EMPTY: the old columns fill in.
      final r = _row();
      r.remove('pack_qty_label');
      r.remove('pack_type_label');
      final p = Product.fromMap(r);

      expect(p.packQtyLabel, '1 injection', reason: 'falls back to pack_qty');
      expect(p.packTypeLabel, 'Vial', reason: 'falls back to pack_type');
    });

    testWidgets('the manufacturer sits under the name', (tester) async {
      // REVERSED BY #274 — it used to be forbidden here. The reference layout
      // puts it on the card and the extent below was re-summed to pay for it.
      await _pump(tester, _row());
      expect(find.text('CELON LABORATORIES LTD'), findsOneWidget);
    });

    testWidgets('the composition line is NOT on the card', (tester) async {
      await _pump(tester, _row());
      expect(find.text('Paclitaxel (100mg)'), findsNothing);
    });
  });

  group('the B2B price block', () {
    testWidgets('the MRP and the sale line are the rendered strings',
        (tester) async {
      await _pump(tester, _row());

      expect(find.text('MRP'), findsOneWidget,
          reason: 'card_price.mrp_label — never typed in Dart');
      expect(find.text('₹2,597.00'), findsOneWidget,
          reason: 'card_price.mrp_display verbatim');
      expect(find.text('₹2,337.30'), findsOneWidget,
          reason: 'card_price.price_display verbatim — never mrp × (1 - pct)');
      expect(find.text('PTR'), findsNothing,
          reason: 'an entitled card shows the AMOUNT, not the word');
    });

    testWidgets('reword the MRP caption in Postgres and the card follows',
        (tester) async {
      final r = _row();
      final cp = (r['pricing'] as Map<String, dynamic>)['card_price']
          as Map<String, dynamic>;
      cp['mrp_label'] = 'LIST';
      await _pump(tester, r);

      expect(find.text('LIST'), findsOneWidget);
      expect(find.text('MRP'), findsNothing,
          reason: 'if "MRP" were a Dart literal it would still be here');
    });

    testWidgets('the sale line is ONE field — reword it and the card follows',
        (tester) async {
      // RULE 3. The same key carries the amount and the word, so a surface
      // that renamed the locked word (or a backend that started sending a
      // second currency) needs no deploy.
      final r = _row(entitled: false);
      ((r['pricing'] as Map<String, dynamic>)['card_price']
          as Map<String, dynamic>)['price_display'] = 'ON APPROVAL';
      await _pump(tester, r);

      expect(find.text('ON APPROVAL'), findsOneWidget);
      expect(find.text('PTR'), findsNothing,
          reason: 'if "PTR" were a Dart literal it would still be here');
    });

    testWidgets('the MRP follows strike_mrp — and it is struck for everyone',
        (tester) async {
      // REVERSED BY #1895 (rule 6). It used to be struck only when a trade
      // price sat under it. The printed ceiling is now shown struck to an
      // anonymous visitor too, with the word PTR beneath it.
      for (final entitled in [true, false]) {
        await _pump(tester, _row(entitled: entitled));
        final struck = tester
            .widgetList<Text>(find.text('₹2,597.00'))
            .any((t) => t.style?.decoration == TextDecoration.lineThrough);
        expect(struck, isTrue, reason: 'strike_mrp:true, entitled=$entitled');
      }

      // Still the BACKEND's flag, not a Dart decision: send false and the
      // strike goes away.
      final r = _row();
      ((r['pricing'] as Map<String, dynamic>)['card_price']
          as Map<String, dynamic>)['strike_mrp'] = false;
      await _pump(tester, r);
      final struck2 = tester
          .widgetList<Text>(find.text('₹2,597.00'))
          .any((t) => t.style?.decoration == TextDecoration.lineThrough);
      expect(struck2, isFalse);
    });

    testWidgets('a withheld PTR is the WORD, and the sentence is off the card',
        (tester) async {
      // RULES 4 + 5. The payload an unapproved visitor gets: no ptr_display
      // key at all, price_display carrying the word. The card must reveal no
      // trade price — and must NOT print the register sentence, which is the
      // prompt's copy now.
      await _pump(tester, _row(entitled: false));

      expect(find.text('₹2,337.30'), findsNothing,
          reason: 'there is no PTR in this payload to print');
      expect(find.text('PTR'), findsOneWidget,
          reason: 'price_display verbatim — the word IS the sale line');
      expect(find.text('Register and get approved to see trade prices'),
          findsNothing,
          reason: '#1895 — that sentence belongs to the prompt, not the card');

      // MRP still shows, struck: it is public, printed on the pack.
      expect(find.text('₹2,597.00'), findsOneWidget);
      expect(find.text('MRP'), findsOneWidget);
    });

    testWidgets('tapping the locked word opens the backend prompt',
        (tester) async {
      await _pump(tester, _row(entitled: false));

      await tester.tap(find.text('PTR'));
      await tester.pumpAndSettle();

      // Every word in the sheet is a payload string.
      expect(find.text('Trade price'), findsOneWidget);
      expect(find.text('Register and get approved to see trade prices'),
          findsOneWidget);
      expect(find.text('Register now'), findsOneWidget);
    });

    testWidgets('an unlocked sale line opens no prompt', (tester) async {
      // price_locked is the backend's verdict and the ONLY thing that makes
      // the line tappable. An approved viewer taps the card, not a sheet.
      await _pump(tester, _row());

      await tester.tap(find.text('₹2,337.30'));
      await tester.pumpAndSettle();

      expect(find.text('Trade price'), findsNothing);
      expect(find.text('Register now'), findsNothing);
    });

    testWidgets('an empty price_display draws no sale line at all',
        (tester) async {
      // A half-filled payload must not paint an empty row. The card prints a
      // string it was given or nothing — it never substitutes a word.
      final r = _row();
      final cp = (r['pricing'] as Map<String, dynamic>)['card_price']
          as Map<String, dynamic>;
      cp['price_display'] = '';
      await _pump(tester, r);
      expect(find.text('PTR'), findsNothing);
      expect(find.text('₹2,337.30'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('has_price:false shows no price at all', (tester) async {
      await _pump(tester, _row(hasPrice: false));
      expect(find.textContaining('₹'), findsNothing,
          reason: '9.7% of the catalogue has no MRP; ₹0.00 reads as free');
    });

    testWidgets('no consumer-discount wording anywhere on the card',
        (tester) async {
      // mediBO is B2B: discounts land on the BILL, not on the shelf label.
      // These are the reference app's consumer devices, and they must never
      // appear here even though a percentage exists in the payload.
      await _pump(tester, _row());
      expect(find.textContaining('OFF'), findsNothing);
      expect(find.textContaining('% off'), findsNothing);
      expect(find.textContaining('Best offer'), findsNothing);
      expect(find.textContaining('orders of'), findsNothing);
    });
  });

  group('the ribbon and the scheme badge', () {
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
      // draw no ribbon. Reconstructing one from it would be the card deciding.
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
          reason: 'offer_chip verbatim, on the plate');

      await _pump(tester, _row(hasOffer: false));
      expect(find.text('Scheme available'), findsNothing);

      // has_offer:false with a stale string still present — the boolean wins.
      final r = _row(hasOffer: false);
      r['offer_chip'] = 'Scheme available';
      await _pump(tester, r);
      expect(find.text('Scheme available'), findsNothing,
          reason: 'an offer is a fact about the product, not about the payload');
    });
  });

  group('ADD ⇄ stepper', () {
    testWidgets('the ADD label is cta_short verbatim', (tester) async {
      await _pump(tester, _row());
      expect(find.text('ADD'), findsOneWidget);
      expect(find.text('Add to cart'), findsNothing,
          reason: 'the card takes the SHORT backend word, not the long one');

      // Reword it in Postgres and the button follows.
      await _pump(tester, _row(ctaShort: 'BUY'));
      expect(find.text('BUY'), findsOneWidget);
      expect(find.text('ADD'), findsNothing);
    });

    testWidgets('no cta_short falls back to cta_label, never to a Dart word',
        (tester) async {
      // An older payload (or a surface that has not been migrated) carries only
      // the long label. The card prints THAT — it does not substitute "ADD".
      await _pump(tester, _row(ctaShort: ''));
      expect(find.text('Add to cart'), findsOneWidget);
    });

    testWidgets('tapping ADD morphs the control into the stepper',
        (tester) async {
      final cart = await _pump(tester, _row());

      expect(find.text('ADD'), findsOneWidget);
      expect(find.byIcon(Icons.remove_rounded), findsNothing);

      await tester.tap(find.text('ADD'));
      // CHANGE #678a — the swap is instant now (the 180ms cross-fade is gone),
      // so pumpAndSettle returns before the cart's own send debounce has run.
      // Pump past it explicitly rather than relying on an animation to hold
      // the frame loop open.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(cart.quantityOf('176026'), 1);
      expect(find.text('1'), findsOneWidget, reason: 'the stepper qty');
      expect(find.byIcon(Icons.remove_rounded), findsOneWidget);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      expect(find.text('ADD'), findsNothing,
          reason: 'ADD morphs in place — the two never show at once');
    });

    testWidgets('+ and − drive the cart quantity', (tester) async {
      final cart = await _pump(tester, _row());

      await tester.tap(find.text('ADD'));
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
      await _pump(tester, _row(canAdd: false, ctaLabel: 'Unavailable',
          ctaShort: 'Out of stock'));

      // Re-pointed in #673: the ADD pill stopped being an OutlinedButton, so
      // asserting on OutlinedButton would now pass without proving anything.
      // The real control is CompactCartControl — the only widget in the card
      // that can write to the cart.
      expect(find.byType(CompactCartControl), findsNothing,
          reason: 'can_add:false means no path into the cart at all');
      expect(find.text('ADD'), findsNothing,
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
      // The card two generations back duplicated a hardcoded 365 in the grid
      // AND the skeleton, so a taller card overflowed silently in both. The
      // extent is derived, and this pins that it stays derived.
      //
      // #1895 sum: plate + gap + the pack-type/ADD row + gap + two name lines
      //            + gap + company + gap + MRP line + gap + sale line. It
      //            comes to the SAME 300 the #274 card did, which is why no
      //            grid or rail had to move for this rebuild.
      expect(CompactProductCard.extent, 300);
      expect(CompactProductCard.extent,
          greaterThan(CompactProductCard.tileH + CompactProductCard.pillH),
          reason: 'the text block below the plate must be real, not clipped');
    });

    test('the extent is a constant, not a function of the viewport', () {
      // Four callers (two rails, two grids) reserve this one number. If it ever
      // became width-derived, the reserved height would differ from the card's
      // real height on some phones and every tile would overflow. The card's
      // WIDTH is now viewport-derived in the rail (#274) — its HEIGHT must not
      // be.
      expect(CompactProductCard.extent, isA<double>());
      expect(CompactProductCard.tileH, 152);
    });

    testWidgets('the chips sit hard LEFT, on the same edge as the name',
        (tester) async {
      // #274 shipped once with `Align(widthFactor: 1)` around the type chip and
      // the PTR box. Align shrinks ITSELF to its child, and the fixed-height
      // SizedBox that reserves the row then centres that shrunken box — so
      // both rendered mid-card on the live site while every unit test passed.
      // Pin the geometry, not the widget: everything in the text block starts
      // on one edge.
      await _pump(tester, _row());

      final nameLeft = tester.getTopLeft(find.text('Alkacel 100mg Injection')).dx;
      expect(tester.getTopLeft(find.text('Vial')).dx, lessThan(nameLeft + 12),
          reason: 'the pack type chip is left-aligned, not centred');
      expect(tester.getTopLeft(find.text('MRP')).dx, lessThan(nameLeft + 4),
          reason: 'the MRP line starts on the same edge');
      expect(tester.getTopLeft(find.text('₹2,337.30')).dx,
          lessThan(nameLeft + 12),
          reason: 'and so does the sale line');
    });

    testWidgets('the card never overflows the extent the grid reserves',
        (tester) async {
      await _pump(tester, _row());
      expect(tester.takeException(), isNull,
          reason: 'a RenderFlex overflow would surface here');
    });

    testWidgets('and does not overflow at the narrowest rail width either',
        (tester) async {
      // #274 sizes the rail card from the viewport; 148 is the floor.
      final cart = CartModel.forTest();
      await tester.pumpWidget(
        AppState(
          cart: cart,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 148,
                height: CompactProductCard.extent,
                child: CompactProductCard(
                  // #287 — the long stored pack sentence, at the narrowest
                  // width the rail is ever laid out at. The chip is Flexible
                  // for exactly this: a Row hands a non-flex child an unbounded
                  // main-axis constraint, so this used to paint past the edge.
                  product: Product.fromMap(_row()
                    ..['pack_qty_label'] =
                        '10.0 tablet er in 1 strip of 10 tablets'),
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
