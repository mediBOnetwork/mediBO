// PROTECTED — CMD #2113.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes bulk-review-row behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the contract between `bulk_match_items()` and the
// phone review row. Before this command the row was the app deciding:
//
//   • the pack was SHORTENED in Dart (`_packShort`: "10 tablets in 1 strip" →
//     "10'T"), so the review list and the storefront card described the same
//     pack in two different vocabularies;
//   • availability was a two-letter "AV"/"NA" chip, worded and coloured in
//     Flutter from `buyable`;
//   • and the price never rendered at all — MEDICINE.mrp is TEXT, the payload
//     carried the raw column, and `(m['mrp'] as num?)` silently parsed it to
//     0.0 on every row.
//
// So: every string the row prints is now a string the payload sent, and the
// one that says a viewer may not see a trade rate is the SAME field as the one
// that says "₹31.50" — `card_price.price_display`. Nothing here may type a
// price, a pack sentence, "Available", "Unavailable" or "PTR" as a fallback.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/product.dart';

/// One candidate exactly as `bulk_match_items()` sends it.
///
/// `entitled: false` is the unapproved / anonymous shape: `has_ptr` is false
/// and `price_display` is the locked WORD. The ptr keys are absent rather than
/// empty, which is how Postgres really sends them — a fixture that filled them
/// with '' would hide a leak this test exists to catch.
Map<String, dynamic> _candidate({
  bool entitled = false,
  bool available = true,
  bool withBadge = true,
  String packType = 'Strip',
  String packQty = '10 tablets in 1 strip',
}) => {
      'id': 99000001,
      'product_name': 'Dolo 650mg Tablet',
      'company': 'Micro Labs Ltd',
      'image_url': 'https://cdn.example/dolo.jpg',
      'pack_type': packType,
      'pack_size': 'strip of 10 tablets',
      'pack_type_label': packType,
      'pack_qty_label': packQty,
      'pack_line': [packType, packQty].where((s) => s.isNotEmpty).join(', '),
      'mrp': '31.50',
      'gst_percent': 12,
      'buyable': available,
      'category': 'PAIN ANALGESICS',
      'availability': {
        'is_available': available,
        'can_add': available,
        'cta_label': available ? 'Add to cart' : 'Unavailable',
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      },
      if (withBadge)
        'avail_badge': available
            ? {
                'label': 'Available',
                'available': true,
                'bg': '#D1FAE5',
                'fg': '#065F46',
              }
            : {
                'label': 'Unavailable',
                'available': false,
                'bg': '#FEE2E2',
                'fg': '#991B1B',
              },
      'pricing': {
        'has_price': true,
        'mrp': 31.50,
        'sale_price': 31.50,
        'mrp_display': '₹31.50',
        'price_display': entitled ? '₹24.20' : 'PTR',
        'price_caption': 'PTR',
        'has_discount': false,
        'discount_label': '',
        'card_price': {
          'has_mrp': true,
          'mrp_label': 'MRP',
          'mrp_display': '₹31.50',
          'strike_mrp': false,
          'sale_label': 'Sale price:',
          'sale_bg': '#1B7A43',
          'sale_fg': '#FFFFFF',
          'price_display': entitled ? '₹24.20' : 'PTR',
          'price_locked': !entitled,
          'has_ptr': entitled,
          if (entitled) 'ptr_label': 'PTR',
          if (entitled) 'ptr_display': '₹24.20',
        },
      },
    };

void main() {
  group('bulk review row — the payload is the row', () {
    test('the two pack badges and the joined line are the payload verbatim',
        () {
      final p = Product.fromBulkMatch(_candidate());

      // The selected row prints these as two separate grey badges; the
      // alternative rows print the joined line. Both are the backend's.
      expect(p.packTypeLabel, 'Strip');
      expect(p.packQtyLabel, '10 tablets in 1 strip');
      expect(p.packLine, 'Strip, 10 tablets in 1 strip');

      // The abbreviation this row used to print instead. If it ever comes
      // back, the review list is describing a pack the catalogue does not.
      expect(p.packQtyLabel, isNot(contains("'T")));
      expect(p.packLine, isNot(contains("'T")));
    });

    test('an absent pack label is absence, never a substitute sentence', () {
      final p = Product.fromBulkMatch(_candidate(packQty: ''));
      expect(p.packQtyLabel, '');
      // packSize is still carried for other callers, but the badge line is
      // empty — the row draws no second badge rather than falling back to
      // "strip of 10 tablets", which is a different string about the pack.
      expect(p.packLine, 'Strip');
    });

    test('an unapproved viewer gets the locked WORD and no trade number', () {
      final cp = Product.fromBulkMatch(_candidate()).pricing?.cardPrice;

      expect(cp, isNotNull);
      expect(cp!.hasPtr, isFalse);
      expect(cp.priceLocked, isTrue);
      // ONE field is the sale line, whichever it holds.
      expect(cp.priceDisplay, 'PTR');
      expect(cp.ptrDisplay, '');
      // The MRP is still printed, plainly and unstruck.
      expect(cp.hasMrp, isTrue);
      expect(cp.mrpLabel, 'MRP');
      expect(cp.mrpDisplay, '₹31.50');
      expect(cp.strikeMrp, isFalse);
      expect(cp.saleLabel, 'Sale price:');
    });

    test('an entitled viewer gets the amount in that SAME field', () {
      final cp =
          Product.fromBulkMatch(_candidate(entitled: true)).pricing?.cardPrice;

      expect(cp!.hasPtr, isTrue);
      expect(cp.priceLocked, isFalse);
      expect(cp.priceDisplay, '₹24.20');
      // Not recomputed from mrp, not re-formatted, not rounded here.
      expect(cp.mrpDisplay, '₹31.50');
    });

    test('the MRP renders at all — the TEXT column used to parse to 0.0', () {
      final p = Product.fromBulkMatch(_candidate());
      // The row prints pricing.card_price, never p.mrp; what matters is that a
      // price BLOCK arrived, which it did not before this command.
      expect(p.pricing, isNotNull);
      expect(p.pricing!.hasPrice, isTrue);
      expect(p.pricing!.mrpDisplay, '₹31.50');
    });

    test('the state badge is a word and two colours, all from the backend', () {
      final ok = Product.fromBulkMatch(_candidate()).availBadge;
      expect(ok, isNotNull);
      expect(ok!.label, 'Available');
      expect(ok.available, isTrue);
      expect(ok.bg, 0xFFD1FAE5);
      expect(ok.fg, 0xFF065F46);

      final bad = Product.fromBulkMatch(_candidate(available: false)).availBadge;
      expect(bad!.label, 'Unavailable');
      expect(bad.available, isFalse);
      expect(bad.bg, 0xFFFEE2E2);
      expect(bad.fg, 0xFF991B1B);

      // Two letters wearing a colour: the thing this replaced.
      expect(ok.label, isNot('AV'));
      expect(bad.label, isNot('NA'));
    });

    test('no badge in the payload means no badge on the row', () {
      final p = Product.fromBulkMatch(_candidate(withBadge: false));
      expect(p.availBadge, isNull);
    });

    test('the availability CTA still arrives beside it, unchanged', () {
      // #1926 put the zone verdict on this list. The badge is a second,
      // different thing (a state word); it must not have displaced the CTA.
      final p = Product.fromBulkMatch(_candidate(available: false));
      expect(p.availability, isNotNull);
      expect(p.availability!.canAdd, isFalse);
      expect(p.availability!.ctaLabel, 'Unavailable');
    });

    test('a restored session still holds every printed string', () {
      // The review list is persisted across a reload (_MatchRow.toJson), so a
      // row that came back from storage must print exactly what it printed
      // before — otherwise the badges and the price silently vanish on resume.
      final before = Product.fromBulkMatch(_candidate(entitled: true));
      final after = Product.fromJson(before.toJson());

      expect(after.packTypeLabel, before.packTypeLabel);
      expect(after.packQtyLabel, before.packQtyLabel);
      expect(after.packLine, before.packLine);
      expect(after.imageUrl, before.imageUrl);
      expect(after.availBadge?.label, before.availBadge?.label);
      expect(after.availBadge?.bg, before.availBadge?.bg);
      expect(after.availBadge?.fg, before.availBadge?.fg);
      expect(after.pricing?.cardPrice?.priceDisplay,
          before.pricing?.cardPrice?.priceDisplay);
      expect(after.pricing?.cardPrice?.mrpDisplay,
          before.pricing?.cardPrice?.mrpDisplay);
    });

    test('a locked row that round-trips does not gain a trade price', () {
      final before = Product.fromBulkMatch(_candidate());
      final after = Product.fromJson(before.toJson());
      expect(after.pricing?.cardPrice?.hasPtr, isFalse);
      expect(after.pricing?.cardPrice?.ptrDisplay, '');
      expect(after.pricing?.cardPrice?.priceDisplay, 'PTR');
    });
  });
}
