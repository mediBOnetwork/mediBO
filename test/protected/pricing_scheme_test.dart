// CHANGE #175 — scheme badge parsing contract.
//
// The scheme badge is produced by _pricing_block() in Postgres and arrives in
// the `pricing` sub-object that every storefront row carries. The client NEVER
// decides whether a product has a scheme — it reads `has_scheme` and
// `scheme_badge` verbatim and renders them if present.
//
// Rules held down here:
// 1. hasSchemeBadge is true only when the payload sends has_scheme:true.
// 2. schemeBadge.label is printed verbatim — never composed in Dart.
// 3. schemeBadge colours come from the payload (#RRGGBB → ARGB int).
// 4. When has_scheme is false/absent, hasSchemeBadge is false and schemeBadge is null.
// 5. schemeText is carried separately and not the same field as schemeBadge.label.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/product.dart';

void main() {
  Map<String, dynamic> _basePricing({
    bool hasScheme = false,
    Map<String, dynamic>? schemeBadge,
    String schemeText = '',
  }) =>
      {
        'has_price': true,
        'price_display': '₹82.50',
        'mrp_display': '₹100.00',
        'discount_label': '17.5% off',
        'has_discount': true,
        'sale_price': 82.5,
        'mrp': 100.0,
        'display_mode': 'full',
        'has_struck_mrp': true,
        'has_ptr': true,
        'ptr_display': '₹80.00',
        'ptr_caption': 'PTR',
        'has_net': true,
        'net_display': '₹82.50',
        'net_caption': 'NET',
        'price_caption': 'PTR',
        'scheme_text': schemeText,
        'has_scheme': hasScheme,
        if (schemeBadge != null) 'scheme_badge': schemeBadge,
      };

  test('has_scheme true → hasSchemeBadge true', () {
    final p = Pricing.fromMap(_basePricing(hasScheme: true))!;
    expect(p.hasSchemeBadge, isTrue);
  });

  test('has_scheme false → hasSchemeBadge false', () {
    final p = Pricing.fromMap(_basePricing(hasScheme: false))!;
    expect(p.hasSchemeBadge, isFalse);
  });

  test('has_scheme absent → hasSchemeBadge false', () {
    final raw = _basePricing();
    raw.remove('has_scheme');
    final p = Pricing.fromMap(raw)!;
    expect(p.hasSchemeBadge, isFalse);
  });

  test('scheme_badge label is verbatim', () {
    const label = '10+1 FREE';
    final p = Pricing.fromMap(_basePricing(
      hasScheme: true,
      schemeBadge: {'label': label, 'bg': '#D1FAE5', 'fg': '#065F46'},
    ))!;
    expect(p.schemeBadge?.label, equals(label));
  });

  test('scheme_badge colours parsed as ARGB', () {
    final p = Pricing.fromMap(_basePricing(
      hasScheme: true,
      schemeBadge: {'label': '5+1', 'bg': '#D1FAE5', 'fg': '#065F46'},
    ))!;
    expect(p.schemeBadge?.bg, equals(0xFFD1FAE5));
    expect(p.schemeBadge?.fg, equals(0xFF065F46));
  });

  test('no scheme_badge → schemeBadge null', () {
    final p = Pricing.fromMap(_basePricing(hasScheme: false))!;
    expect(p.schemeBadge, isNull);
  });

  test('scheme_text is separate from schemeBadge.label', () {
    final p = Pricing.fromMap(_basePricing(
      hasScheme: true,
      schemeText: '10+1',
      schemeBadge: {'label': '10+1 FREE', 'bg': '#D1FAE5', 'fg': '#065F46'},
    ))!;
    expect(p.schemeText, equals('10+1'));
    expect(p.schemeBadge?.label, equals('10+1 FREE'));
    expect(p.schemeText, isNot(equals(p.schemeBadge?.label)));
  });

  test('toJson round-trips scheme fields', () {
    final p = Pricing.fromMap(_basePricing(
      hasScheme: true,
      schemeBadge: {'label': '5+1 FREE', 'bg': '#D1FAE5', 'fg': '#065F46'},
    ))!;
    final j = p.toJson();
    expect(j['has_scheme'], isTrue);
    expect((j['scheme_badge'] as Map?)?['label'], equals('5+1 FREE'));
  });
}
