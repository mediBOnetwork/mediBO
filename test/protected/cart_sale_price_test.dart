// PROTECTED — CMD #1952.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes what a cart row says about money.
//
// What this holds down:
//
//   1. THE PRICE IS THE CARD'S. A row's sale value is `row.sale.value`, which
//      cart_render() fills from the SAME `price_display` the product cards
//      print. The cart never re-prices a line, so the two surfaces cannot
//      disagree — the defect this command fixed was a cart that showed no
//      price at all until a row was expanded.
//
//   2. Absence is absence. A payload with no `sale` draws no price line; the
//      row never falls back to an amount it computed from MRP.
//
//   3. The locked wording is the backend's. "PTR" arrives as the value with
//      `locked: true`; nothing in Dart decides when a price is withheld.
//
//   4. The quantity pill prints `stepper.qty_text` ALONE, with
//      `stepper.unit_label` as a caption under it. The unit word sharing a
//      44px slot with the number is what rendered as "1 S…".
//
//   5. The top strip is `render.top_strip` and holds two things: the item
//      count and the advance due. `show:false` (an empty basket) draws
//      nothing — never "Items × 0" — and an advance the backend did not send
//      is not invented.
//
//   6. The sticky bar's line is `summary.sale_line`, printed verbatim with
//      the payload's own tone.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/screens/cart_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _row({
  bool sale = true,
  String saleValue = 'PTR',
  bool locked = true,
  String qtyText = '9',
  String unitLabel = 'Strip',
  String packPrefix = '1 Strip · MRP',
  String packAmount = '₹231.80',
  String mrpQty = '₹231.80 × 9',
  List<Map<String, dynamic>> expanded = const [
    {
      'key': 'sale',
      'label': 'Sale price',
      'value': 'PTR',
      'strong': true,
      'tone': {'bg': '#D1FAE5', 'fg': '#065F46'},
    },
    {'key': 'mrp', 'label': 'MRP', 'value': '₹231.80 × 9', 'strike': true},
    {'key': 'company', 'label': 'Company', 'value': 'Micro Labs Ltd'},
    {'key': 'pack', 'label': 'Pack', 'value': '1 Strip of 15 Tablets'},
  ],
}) =>
    {
      'name': 'Dolo 650',
      'pack_label': '1 Strip of 15 Tablets',
      'mrp_qty': mrpQty,
      'stepper': {
        'qty': 9,
        'qty_text': qtyText,
        'unit_label': unitLabel,
      },
      'pack_mrp': {
        'has': true,
        'prefix': packPrefix,
        'amount': packAmount,
        'strike': true,
      },
      if (sale)
        'sale': {
          'has': true,
          'label': 'Sale price:',
          'value': saleValue,
          'locked': locked,
          'tone': {'bg': '#D1FAE5', 'fg': '#065F46'},
        },
      'rx_chip': {'has': false, 'label': 'Rx'},
      'expanded_rows': expanded,
      'detail_rows': const [
        {'key': 'company', 'label': 'Company', 'value': 'Micro Labs Ltd'},
      ],
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

  group('CMD #1952 — the row carries the card\'s own price', () {
    tearDown(() => CartModel.rpcTransport = null);

    test('the sale value is the payload\'s price_display, verbatim', () async {
      final line = await _line(_row(saleValue: '₹82.50', locked: false));
      final sale = line.rowMap('sale');
      expect(sale['has'], isTrue);
      expect(sale['value'], '₹82.50');
      expect(sale['label'], 'Sale price:');
      expect(sale['locked'], isFalse);
    });

    test('a withheld price is the backend\'s word, not a local rule', () async {
      final sale = (await _line(_row())).rowMap('sale');
      expect(sale['value'], 'PTR');
      expect(sale['locked'], isTrue);
    });

    test('no sale block means no price line invented', () async {
      final line = await _line(_row(sale: false));
      expect(line.rowMap('sale'), isEmpty);
      // The MRP indicator is still the payload's own string.
      expect(line.rows('mrp_qty'), '₹231.80 × 9');
    });

    test('the pill gets the number and the unit separately', () async {
      final st = (await _line(_row())).rowMap('stepper');
      expect(st['qty_text'], '9');
      expect(st['unit_label'], 'Strip');
      // The clipped "1 S…" chip was one string doing both jobs.
      expect(st.containsKey('qty_label'), isFalse);
    });

    test('the pack caption keeps prefix and amount apart so MRP can be struck',
        () async {
      final pm = (await _line(_row())).rowMap('pack_mrp');
      expect(pm['prefix'], '1 Strip · MRP');
      expect(pm['amount'], '₹231.80');
      expect(pm['strike'], isTrue);
    });

    test('the expanded body keeps payload order: sale, MRP, company, pack',
        () async {
      final line = await _line(_row());
      final keys = ((line.row['expanded_rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e['key'])
          .toList();
      expect(keys, ['sale', 'mrp', 'company', 'pack']);
    });
  });

  group('CMD #1952 — the sale line widget prints what it is handed', () {
    testWidgets('label and value, with the MRP struck beside them',
        (tester) async {
      await _pump(
          tester,
          const C1952SaleLine(
            sale: {
              'has': true,
              'label': 'Sale price:',
              'value': 'PTR',
              'locked': true,
              'tone': {'bg': '#D1FAE5', 'fg': '#065F46'},
            },
            mrpQty: '₹231.80 × 9',
          ));
      expect(find.text('Sale price: PTR'), findsOneWidget);
      expect(find.text('₹231.80 × 9'), findsOneWidget);
    });

    testWidgets('an absent sale draws nothing at all', (tester) async {
      await _pump(tester, const C1952SaleLine(sale: {}, mrpQty: ''));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('CMD #1952 — the top strip is items and the advance, nothing else', () {
    testWidgets('both halves print verbatim', (tester) async {
      await _pump(
          tester,
          const C1952TopStrip(strip: {
            'show': true,
            'items_label': 'Items × 3',
            'advance_label': 'Advance to pay:',
            'has_advance': true,
            'advance_display': '₹1,240.00',
            'advance_pct_label': '10%',
          }));
      expect(find.text('Items × 3'), findsOneWidget);
      expect(find.text('Advance to pay:'), findsOneWidget);
      expect(find.text('₹1,240.00'), findsOneWidget);
    });

    testWidgets('an empty basket draws no strip', (tester) async {
      await _pump(
          tester,
          const C1952TopStrip(strip: {
            'show': false,
            'items_label': 'Items × 0',
            'has_advance': false,
          }));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('an advance the backend did not send is not invented',
        (tester) async {
      await _pump(
          tester,
          const C1952TopStrip(strip: {
            'show': true,
            'items_label': 'Items × 2',
            'advance_label': 'Advance to pay:',
            'has_advance': false,
            'advance_display': '₹0.00',
          }));
      expect(find.text('Items × 2'), findsOneWidget);
      expect(find.text('Advance to pay:'), findsNothing);
      expect(find.text('₹0.00'), findsNothing);
    });
  });

  group('CMD #1952 — the sticky bar speaks the same line', () {
    testWidgets('sale_line prints label and value', (tester) async {
      await _pump(
          tester,
          const C1952BarSale(render: {
            'summary': {
              'sale_line': {
                'has': true,
                'label': 'Sale price (PTR)',
                'value': 'PTR',
                'locked': true,
                'tone': {'bg': '#D1FAE5', 'fg': '#065F46'},
              }
            }
          }));
      expect(find.text('Sale price (PTR)'), findsOneWidget);
      expect(find.text('PTR'), findsOneWidget);
    });

    testWidgets('no sale_line means no bar line', (tester) async {
      await _pump(tester, const C1952BarSale(render: {'summary': {}}));
      expect(find.byType(Text), findsNothing);
    });
  });
}
