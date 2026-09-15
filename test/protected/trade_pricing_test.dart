// PROTECTED — CHANGE #355.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the cart states the money.
//
// The register rows this holds down (feature_gaps, customer surface, critical):
//
//   #79  "Every order in history is billed at MRP, never a trade rate."
//        213 of 213 priced order lines had price = mrp exactly, 0 below MRP,
//        and cart_render returned grand_total = net_payable = the MRP total.
//   #81  "No GST on any catalogue row, so no tax breakup before checkout."
//        cart_render carried no taxable value, no CGST, no SGST, no GST total.
//
// legal_get_page('about'): MRP "is the legal ceiling and a display field, never
// the selling price ... Any build that prices, totals, or reports revenue on
// MRP is wrong."
//
// What this file asserts:
//
//   1. The payable is the BACKEND's net payable. mrp_total is present in the
//      same payload and is a DIFFERENT number; nothing may read it as money
//      owed.
//   2. With no line priced yet, the payable is the backend's own sentence
//      ("Awaiting supplier rates") — not ₹0.00 assembled here, and above all
//      not the MRP worth sitting right next to it in the payload.
//   3. The GST breakup is rendered in PAYLOAD ORDER and verbatim: taxable
//      value, CGST, SGST, GST total. No rate is halved and no rupee string is
//      formatted in Dart.
//   4. `unpriced_note` is printed verbatim — "1 item"/"3 items" is pluralised
//      by the backend, the same rule cart_unavailable_test holds for the
//      unavailable badge.
//   5. has_tax is the backend's flag. An all-unpriced basket has no tax block
//      at all, rather than a row of zeroes.
//   6. A per-line rate is the resolved trade rate; a line without one carries
//      the backend's note instead, and never its MRP dressed as a rate.
//
// SCOPE NOTE: CartScreen needs five inherited states and a live Supabase client
// to mount, so — as in cart_unavailable_test — this asserts the decisions the
// footer renders rather than pumping the screen.
//
// No network, no Supabase, no goldens.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures — shaped exactly like cart_render() ─────────────────────────────

/// A line as _cart_render_core() emits it: the catalogue facts, plus whatever
/// trade_price_line() resolved for it.
Map<String, dynamic> _line({
  required int productId,
  required String name,
  int quantity = 3,
  double mrp = 117.19,
  String? priceDisplay,
}) {
  final priced = priceDisplay != null;
  return {
    'id': productId,
    'product_id': '$productId',
    'product_name': name,
    'quantity': quantity,
    'mrp': mrp,
    'image_url': '',
    'manufacturer': 'CIPLA LTD',
    'pack_size': '10 tablets in 1 strip',
    'category': 'ANTI INFECTIVES',
    'buyable': true,
    'added_by_admin': false,
    'mrp_display': '₹117.19',
    'line_mrp_display': '₹351.57',
    'has_trade_rate': priced,
    'price_display': priced ? priceDisplay : '',
    'rate_note': priced ? '' : 'Rate on supplier confirmation',
    'qty_label':
        priced ? '$quantity × $priceDisplay' : '$quantity × Rate on supplier confirmation',
  };
}

/// The pricing block from cart_pricing_block(), minus `lines` (the screen reads
/// the per-line copy off the items, which already carry it).
Map<String, dynamic> _pricing({
  required int priced,
  required int unpriced,
  required String netPayableDisplay,
  required String mrpWorthDisplay,
  List<Map<String, String>> taxLines = const [],
  String unpricedNote = '',
  String gstNote = '',
}) =>
    {
      'title': 'Order summary',
      'priced_count': priced,
      'unpriced_count': unpriced,
      'has_priced': priced > 0,
      'has_unpriced': unpriced > 0,
      'has_tax': priced > 0,
      'net_payable_label': 'Net payable',
      'net_payable_display': netPayableDisplay,
      'mrp_worth_label': 'MRP worth (reference only)',
      'mrp_worth_display': mrpWorthDisplay,
      'unpriced_note': unpricedNote,
      'gst_note': gstNote,
      'tax_lines': taxLines,
    };

Map<String, dynamic> _cart({
  required List<Map<String, dynamic>> items,
  required Map<String, dynamic> pricing,
  required double mrpTotal,
  required double netPayable,
  required String subtotalLine,
}) =>
    {
      'items': items,
      'item_count': items.length,
      'unit_count': items.fold<int>(0, (s, i) => s + (i['quantity'] as int)),
      // The catalogue ceiling stays in the payload — it just is not the money.
      'mrp_total': mrpTotal,
      'net_payable': netPayable,
      'subtotal': netPayable,
      'pricing': pricing,
      'render': {
        'grand_total': netPayable,
        'grand_total_display': pricing['net_payable_display'],
        'net_payable_display': pricing['net_payable_display'],
        'mrp_total_display': '₹1,653.47',
        'subtotal_display': '₹225.00',
        'subtotal_line': subtotalLine,
        'has_tax': pricing['has_tax'],
        'tax_lines': pricing['tax_lines'],
        'pricing': pricing,
        'labels': {
          'subtotal': 'Taxable value',
          'mrp_worth': 'MRP worth (reference only)',
          'gst': 'GST',
          'total': 'Net payable',
        },
      },
    };

/// One priced line (PTR ₹75.00, GST 12 %) and one the suppliers have not
/// quoted yet — the shape every real basket has today.
Map<String, dynamic> _mixedBasket() => _cart(
      items: [
        _line(productId: 176044, name: 'Priced product', priceDisplay: '₹75.00'),
        _line(
            productId: 334552,
            name: 'Daplo MF 10mg/1000mg Tablet ER',
            quantity: 5,
            mrp: 260.38),
      ],
      pricing: _pricing(
        priced: 1,
        unpriced: 1,
        netPayableDisplay: '₹252.00',
        mrpWorthDisplay: '₹1,653.47',
        unpricedNote: '1 item not priced yet — rate comes with the supplier quote',
        taxLines: const [
          {'label': 'Taxable value', 'value': '₹225.00'},
          {'label': 'CGST', 'value': '₹13.50'},
          {'label': 'SGST', 'value': '₹13.50'},
          {'label': 'GST', 'value': '₹27.00'},
        ],
      ),
      mrpTotal: 1653.47,
      netPayable: 252.00,
      subtotalLine: '2 items • ₹252.00 • 1 item not priced yet — rate comes '
          'with the supplier quote',
    );

/// The basket from #79's own evidence: eight lines, 32 units, MRP worth
/// ₹14,421.53, and not one of them priced.
Map<String, dynamic> _nothingPricedBasket() => _cart(
      items: [
        for (var i = 0; i < 8; i++)
          _line(productId: 900 + i, name: 'Unpriced $i', quantity: 4),
      ],
      pricing: _pricing(
        priced: 0,
        unpriced: 8,
        netPayableDisplay: 'Awaiting supplier rates',
        mrpWorthDisplay: '₹14,421.53',
        unpricedNote: '8 items not priced yet — rate comes with the supplier quote',
      ),
      mrpTotal: 14421.53,
      netPayable: 0.0,
      subtotalLine: '8 items • Awaiting supplier rates • 8 items not priced yet',
    );

Future<CartModel> _loaded(Map<String, dynamic> payload) async {
  CartModel.rpcTransport = (fn, params) async => payload;
  final cart = CartModel.forTest();
  await cart.refresh();
  return cart;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => CartModel.rpcTransport = null);

  test('1. the payable is the trade total, and it is NOT the MRP total',
      () async {
    final cart = await _loaded(_mixedBasket());

    expect(cart.netPayableDisplay, '₹252.00');
    expect(cart.grandTotal, 252.00);
    expect(cart.netPayable, 252.00);

    // The ceiling is still in the payload, and it is a different number. #79
    // was these two being the same by construction.
    expect(cart.mrpTotal, 1653.47);
    expect(cart.mrpWorthDisplay, '₹1,653.47');
    expect(cart.grandTotal, isNot(cart.mrpTotal),
        reason: 'pricing an order on MRP is what feature_gaps #79 is');
  });

  test('2. nothing priced → the backend\'s sentence, never the MRP worth',
      () async {
    final cart = await _loaded(_nothingPricedBasket());

    expect(cart.netPayableDisplay, 'Awaiting supplier rates');
    expect(cart.netPayableDisplay, isNot(contains('14,421.53')),
        reason: 'the exact number #79 filed: the MRP worth quoted as payable');
    expect(cart.grandTotal, 0.0);

    // The ceiling is still shown, under the label that says what it is.
    expect(cart.mrpWorthDisplay, '₹14,421.53');
    expect(cart.mrpWorthLabel, 'MRP worth (reference only)');
  });

  test('3. the GST breakup renders verbatim, in payload order', () async {
    final cart = await _loaded(_mixedBasket());

    expect(cart.hasTax, isTrue);
    expect(cart.taxLines.map((l) => l['label']).toList(),
        ['Taxable value', 'CGST', 'SGST', 'GST']);
    expect(cart.taxLines.map((l) => l['value']).toList(),
        ['₹225.00', '₹13.50', '₹13.50', '₹27.00']);

    // Both halves come off the payload. Nothing here halves a rate or formats
    // a rupee amount — #81 is not fixed by moving the arithmetic to Dart.
    for (final l in cart.taxLines) {
      expect(l.keys.toSet(), {'label', 'value'});
    }
  });

  test('4. unpriced_note is printed verbatim, pluralised by the backend',
      () async {
    final one = await _loaded(_mixedBasket());
    expect(one.unpricedNote,
        '1 item not priced yet — rate comes with the supplier quote');

    final many = await _loaded(_nothingPricedBasket());
    expect(many.unpricedNote,
        '8 items not priced yet — rate comes with the supplier quote');
  });

  test('5. an all-unpriced basket has no tax block at all', () async {
    final cart = await _loaded(_nothingPricedBasket());

    expect(cart.hasTax, isFalse,
        reason: 'has_tax is the backend flag, not a count of lines');
    expect(cart.taxLines, isEmpty,
        reason: 'a row of zeroes is not a tax breakup');
  });

  test('6. a line shows its trade rate, or the backend note — never its MRP',
      () async {
    final cart = await _loaded(_mixedBasket());
    final items = cart.rawItems;

    final priced = items.firstWhere((i) => i['product_id'] == '176044');
    final unpriced = items.firstWhere((i) => i['product_id'] == '334552');

    expect(priced['has_trade_rate'], isTrue);
    expect(priced['qty_label'], '3 × ₹75.00');
    expect(priced['rate_note'], '');

    expect(unpriced['has_trade_rate'], isFalse);
    expect(unpriced['qty_label'], '5 × Rate on supplier confirmation');
    expect(unpriced['rate_note'], 'Rate on supplier confirmation');
    expect(unpriced['qty_label'], isNot(contains('260.38')),
        reason: 'the printed ceiling must never be shown as the rate');
  });
}
