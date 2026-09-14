// PROTECTED — CMD #2013 (supersedes CMD #1952's row contract).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes what a cart row says about money.
//
// CMD #1952 gave every row a "Sale price: PTR" chip, a "MRP × qty" caption and
// a tap-to-open detail body. CMD #2013 replaced all three with ONE money block
// under the quantity pill, and replaced the strip above the list and the
// four-line ladder above Place order with a single summary row. What survives
// unchanged from #1952 is the rule underneath: THE PRICE IS THE BACKEND'S.
//
// What this holds down:
//
//   1. The row's value is `row.price.value`, which cart_render() fills from
//      the SAME `price_display` the product cards print. The cart never
//      re-prices a line, so the two surfaces cannot disagree.
//
//   2. The struck MRP is `price.has_strike`, not a comparison done in Dart.
//      A withheld price ("PTR", `locked: true`) draws ONE plain line: no
//      strike, no percent — the backend already said there is nothing to
//      compare.
//
//   3. The discount percent is `price.discount_label`, a backend sentence.
//      Nothing here divides one number by another, and `has_discount:false`
//      means no percent is printed even when a label was sent.
//
//   4. Absence is absence. A payload with no `price` draws no money at all;
//      the row never falls back to an amount it derived from MRP.
//
//   5. The quantity pill prints `stepper.qty_text` alone.
//
//   6. The summary above Place order is `summary.bottom` — items on the left,
//      the advance on the right — and an advance the backend did not send is
//      not invented.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/screens/cart_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _row({
  bool price = true,
  String value = 'PTR',
  bool locked = true,
  bool strike = false,
  String mrpDisplay = '',
  bool discount = false,
  String discountLabel = '',
  String qtyText = '9',
  bool rx = false,
}) =>
    {
      'name': 'Dolo 650',
      'pack_label': '1 Strip of 15 Tablets',
      'has_pack': true,
      'mrp_display': '₹231.80',
      'has_mrp': true,
      'stepper': {'qty': 9, 'qty_text': qtyText, 'unit_label': 'Strip'},
      if (price)
        'price': {
          'has': true,
          'value': value,
          'locked': locked,
          'has_strike': strike,
          'mrp_display': mrpDisplay,
          'has_discount': discount,
          'discount_label': discountLabel,
          'discount_fg': '#065F46',
        },
      'rx_chip': {
        'has': rx,
        'label': 'Rx',
        'tone': {'bg': '#1E40AF', 'fg': '#FFFFFF'},
      },
    };

/// One cart line, adopted the way the app adopts one: through the payload.
Future<CartLine> _line(Map<String, dynamic>? row) async {
  CartModel.rpcTransport = (fn, params) async => {
        'items': [
          {
            'id': 1,
            'product_id': '101',
            'product_name': 'Dolo 650',
            'quantity': 9,
            'mrp': 231.80,
            'image_url': '',
            'manufacturer': 'Micro Labs Ltd',
            'pack_size': '1 Strip of 15 Tablets',
            'category': 'ANALGESICS',
            if (row != null) 'row': row,
          }
        ],
        'item_count': 1,
        'render': const {},
      };
  final cart = CartModel.forTest();
  await cart.refresh();
  return cart.lines.single;
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('CMD #2013 — the row carries the card\'s own price', () {
    tearDown(() => CartModel.rpcTransport = null);

    test('the value is the payload\'s price_display, verbatim', () async {
      final line = await _line(_row(
          value: '₹189.00',
          locked: false,
          strike: true,
          mrpDisplay: '₹231.80',
          discount: true,
          discountLabel: '18% OFF'));
      final p = line.rowMap('price');
      expect(p['has'], isTrue);
      expect(p['value'], '₹189.00');
      expect(p['locked'], isFalse);
      expect(p['discount_label'], '18% OFF');
    });

    test('a withheld price is the backend\'s word, and carries no ceiling',
        () async {
      final p = (await _line(_row())).rowMap('price');
      expect(p['value'], 'PTR');
      expect(p['locked'], isTrue);
      expect(p['has_strike'], isFalse);
      expect(p['has_discount'], isFalse);
    });

    test('no price block means no money invented', () async {
      final line = await _line(_row(price: false));
      expect(line.rowMap('price'), isEmpty);
      // The MRP is still on the row as a payload string; it is never promoted
      // into a price by this side.
      expect(line.rows('mrp_display'), '₹231.80');
    });

    test('the pill gets the number alone', () async {
      final st = (await _line(_row())).rowMap('stepper');
      expect(st['qty_text'], '9');
      // #1952's unit caption under the pill is gone — the money lives there
      // now — but the backend still names the unit for anyone who wants it.
      expect(st['unit_label'], 'Strip');
    });

    test('the Rx badge is a per-line flag with the payload\'s own colours',
        () async {
      expect((await _line(_row())).rowMap('rx_chip')['has'], isFalse);
      final on = (await _line(_row(rx: true))).rowMap('rx_chip');
      expect(on['has'], isTrue);
      expect(on['label'], 'Rx');
      expect((on['tone'] as Map)['bg'], '#1E40AF');
    });
  });

  group('CMD #2013 — the price widget prints what it is handed', () {
    testWidgets('a discounted line: struck MRP, percent, then the price',
        (tester) async {
      await _pump(
          tester,
          const C2013RowPrice(price: {
            'has': true,
            'value': '₹189.00',
            'locked': false,
            'has_strike': true,
            'mrp_display': '₹231.80',
            'has_discount': true,
            'discount_label': '18% OFF',
            'discount_fg': '#065F46',
          }));
      expect(find.text('₹231.80'), findsOneWidget);
      expect(find.text('18% OFF'), findsOneWidget);
      expect(find.text('₹189.00'), findsOneWidget);
      final mrp = tester.widget<Text>(find.text('₹231.80'));
      expect(mrp.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('no discount means one line: no strike, no percent',
        (tester) async {
      await _pump(
          tester,
          const C2013RowPrice(price: {
            'has': true,
            'value': 'PTR',
            'locked': true,
            'has_strike': false,
            'mrp_display': '₹231.80',
            'has_discount': false,
            'discount_label': '',
          }));
      expect(find.text('PTR'), findsOneWidget);
      // The ceiling is NOT drawn just because the payload carried the string.
      expect(find.text('₹231.80'), findsNothing);
    });

    testWidgets('an absent price draws nothing at all', (tester) async {
      await _pump(tester, const C2013RowPrice(price: {}));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('CMD #2013 — ONE summary row above Place order', () {
    testWidgets('both halves print verbatim', (tester) async {
      await _pump(
          tester,
          const C2013SummaryRow(render: {
            'summary': {
              'bottom': {
                'has': true,
                'items_label': 'Total items',
                'items_value': '4',
                'advance_label': 'Advance to pay',
                'has_advance': true,
                'advance_display': '₹229.31',
              }
            }
          }));
      expect(find.text('Total items'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('Advance to pay'), findsOneWidget);
      expect(find.text('₹229.31'), findsOneWidget);
    });

    testWidgets('an advance the backend did not send is not invented',
        (tester) async {
      await _pump(
          tester,
          const C2013SummaryRow(render: {
            'summary': {
              'bottom': {
                'has': true,
                'items_label': 'Total items',
                'items_value': '2',
                'advance_label': 'Advance to pay',
                'has_advance': false,
                'advance_display': '₹0.00',
              }
            }
          }));
      expect(find.text('Total items'), findsOneWidget);
      expect(find.text('Advance to pay'), findsNothing);
      expect(find.text('₹0.00'), findsNothing);
    });

    testWidgets('no bottom block means no summary row', (tester) async {
      await _pump(tester, const C2013SummaryRow(render: {'summary': {}}));
      expect(find.byType(Text), findsNothing);
    });
  });
}
