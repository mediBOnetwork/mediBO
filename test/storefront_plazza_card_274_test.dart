// CHANGE #274 — the command's own focused test.
//
// The protected suite (test/protected/compact_card_test.dart) pins how the
// CARD renders. This file pins the two things #274 changed AROUND the card,
// which nothing else covers:
//
//   1. The rail's card width is DERIVED from the viewport so the next card
//      always peeks. A fixed width meant "does this row scroll?" was decided by
//      the phone the user happened to hold.
//   2. The payload mapping the Plazza anatomy depends on: `pack_label` is the
//      compact QUANTITY that goes on the image and `form_chip` is the TYPE that
//      goes in the chip below it. They were swapped, which is how the long
//      "10.0 tablet er in 1 strip" ended up in the chip under the card.
//
// Plus the entitlement contract on the MODEL side: a payload with no
// `ptr_display` must parse to a CardPrice that has no trade price to show —
// the client half of the `storefront_ptr_entitlement` regression guard.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/home_sections.dart';
import 'package:pharma_b2b/models/product.dart';

/// One rail card in the exact shape `_sf_cards()` sends after #274.
Map<String, dynamic> _card({bool entitled = false}) => {
      'id': 176044,
      'name': 'Tranomac MF 500mg/250mg Tablet',
      'company': 'MACLEODS PHARMACEUTICALS PVT LTD',
      // The compact badge that rides on the image.
      'pack_label': '6 tablets',
      // The type chip under the image.
      'form_chip': 'Strip',
      'image': '',
      'buyable': true,
      'availability': {
        'is_available': true,
        'can_add': true,
        'cta_label': 'Add to cart',
        'cta_short': 'ADD',
        'gated': false,
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      },
      'pricing': {
        'has_price': true,
        'mrp': 117.19,
        'sale_price': 117.19,
        'price_display': '₹117.19',
        'price_caption': 'MRP',
        'display_mode': entitled ? 'full' : 'mrp_only',
        'card_price': {
          'has_mrp': true,
          'mrp_label': 'MRP',
          'mrp_display': '₹117.19',
          'strike_mrp': entitled,
          'has_ptr': entitled,
          if (entitled) 'ptr_label': 'PTR',
          if (entitled) 'ptr_display': '₹82.50',
          if (entitled) 'ptr_bg': '#1B7A43',
          if (entitled) 'ptr_fg': '#FFFFFF',
          'has_note': !entitled,
          'note': entitled ? '' : 'Register and get approved to see trade prices',
        },
      },
    };

void main() {
  group('the rail always shows the next card peeking', () {
    test('a phone fits about two and a fraction cards, never a flat two', () {
      // 360 / 390 / 414 are the three phone widths DESIGN.md names. At each,
      // the number of whole cards that fit must NOT be a round number — a row
      // ending flush with the screen edge is indistinguishable from a static
      // two-column grid, which is exactly what Om was looking at.
      for (final viewport in <double>[360, 390, 414]) {
        final w = HomeSectionMetrics.railCardWidth(viewport);
        final perScreen = (viewport - 32) / (w + 12);
        expect(perScreen.floor() < perScreen, isTrue,
            reason: 'at ${viewport}pt the row ends flush — nothing shows that '
                'it scrolls');
        expect(perScreen, greaterThan(2.0),
            reason: 'two full cards plus a peek is the target shape');
        expect(perScreen, lessThan(3.0),
            reason: 'more than that and the cards are too small to read');
      }
    });

    test('a desktop window does not inflate one card to a third of the page',
        () {
      final w = HomeSectionMetrics.railCardWidth(1280);
      expect(w, lessThanOrEqualTo(190));
      final perScreen = (1280 - 32) / (w + 12);
      expect(perScreen, greaterThan(5),
          reason: 'a wide window shows a row, not three billboards');
      expect(perScreen.floor() < perScreen, isTrue,
          reason: 'and still peeks');
    });

    test('the width is a pure function of the viewport, not of the payload',
        () {
      expect(HomeSectionMetrics.railCardWidth(390),
          HomeSectionMetrics.railCardWidth(390));
      expect(HomeSectionMetrics.railCardWidth(390),
          isNot(HomeSectionMetrics.railCardWidth(1280)));
    });
  });

  group('the card payload maps to the Plazza anatomy', () {
    test('pack_label is the badge ON the image, form_chip is the type chip',
        () {
      final p = Product.fromHomeCard(_card());

      // These two were SWAPPED before #274: packSize held "Strip" and the chip
      // held the long pack sentence, which is what rendered as the full-width
      // grey pill Om called out.
      expect(p.packSize, '6 tablets',
          reason: 'the compact quantity, for the plate footer');
      expect(p.formChip, 'Strip',
          reason: 'the dosage type, for the chip under the card');
    });

    test('the manufacturer survives the mapping', () {
      // The card prints it now, so a dropped field would render a blank line
      // rather than fail loudly.
      expect(Product.fromHomeCard(_card()).manufacturer,
          'MACLEODS PHARMACEUTICALS PVT LTD');
    });

    test('cta_short rides on the availability block', () {
      expect(Product.fromHomeCard(_card()).availability?.ctaShort, 'ADD');
      expect(Product.fromHomeCard(_card()).availability?.ctaLabel,
          'Add to cart');
    });
  });

  group('PTR entitlement, on the client side of the contract', () {
    test('an un-entitled payload parses to a CardPrice with no trade price',
        () {
      final p = Product.fromHomeCard(_card()).pricing!;
      final cp = p.cardPrice!;

      expect(cp.hasPtr, isFalse);
      expect(cp.ptrDisplay, isEmpty,
          reason: 'there is no ptr_display key in this payload to carry');
      expect(cp.strikeMrp, isFalse,
          reason: 'nothing sits under the MRP, so it is not struck');
      expect(cp.hasMrp, isTrue, reason: 'MRP is printed on the pack; it is public');
      expect(cp.note, 'Register and get approved to see trade prices',
          reason: 'the backend says how to become entitled');

      // The whole pricing block, not just the card slice.
      expect(p.hasPtr, isFalse);
      expect(p.ptrDisplay, isEmpty);
    });

    test('an entitled payload carries both numbers and both words', () {
      final cp = Product.fromHomeCard(_card(entitled: true)).pricing!.cardPrice!;

      expect(cp.hasPtr, isTrue);
      expect(cp.ptrLabel, 'PTR');
      expect(cp.ptrDisplay, '₹82.50');
      expect(cp.mrpLabel, 'MRP');
      expect(cp.mrpDisplay, '₹117.19');
      expect(cp.strikeMrp, isTrue);
      expect(cp.hasNote, isFalse);
    });

    test('a flag without a value is still no trade price', () {
      // A half-written payload must not produce an empty filled box.
      final raw = _card(entitled: true);
      ((raw['pricing'] as Map<String, dynamic>)['card_price']
          as Map<String, dynamic>)['ptr_display'] = '';
      expect(
          Product.fromHomeCard(raw).pricing!.cardPrice!.hasPtr, isFalse);
    });

    test('a pre-#274 payload falls back without inventing a word', () {
      // The short-dated rail and the back-in-stock strip still send the old
      // shape. It must render the numbers it has — and no PTR it was not sent.
      final p = Pricing.fromMap({
        'has_price': true,
        'mrp': 117.19,
        'price_display': '₹117.19',
        'price_caption': 'MRP',
        'has_struck_mrp': false,
      })!;

      expect(p.cardPrice!.hasMrp, isTrue);
      expect(p.cardPrice!.mrpDisplay, '₹117.19');
      expect(p.cardPrice!.mrpLabel, 'MRP', reason: 'price_caption, verbatim');
      expect(p.cardPrice!.hasPtr, isFalse);
      expect(p.cardPrice!.hasNote, isFalse,
          reason: 'an old payload has no note to print — it prints nothing');
    });
  });
}
