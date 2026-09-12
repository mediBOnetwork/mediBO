// PROTECTED — CMD #1912.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how a cart row is rendered.
//
// What this holds down — the cart row computes NOTHING:
//
//   1. Every word on a row is `cart_render().items[].row`. The quantity label
//      ("4 Strip"), the pack caption, the one price line ("MRP ₹944.80 × 4")
//      and the sale-price badge are printed verbatim. The unit word in
//      particular used to be nine `contains()` tests in Dart
//      (_CartStepper._unit), so a pack of "1 Strip of 15 Tablets" whose
//      payload says "4 Box" must render "4 Box" — the backend wins.
//
//   2. Absence is absence. A line whose payload carries no `row` yields empty
//      strings and an empty detail list; the screen never falls back to a
//      locally assembled string.
//
//   3. The Rx chip is `row.rx_chip.has` — a per-line flag, not a count the
//      footer used to print once ("5 prescription items in this order").
//
//   4. Detail rows arrive in PAYLOAD ORDER and a value the record does not
//      have is simply not a row.
//
//   5. The summary block renders `summary.rows` in payload order with the
//      amounts on the right, shows the line only while `show_line` is true,
//      and prints `rate_note` ONCE. "Rate confirmed after supplier quote."
//      appearing on every row and again in the footer is the repetition this
//      change removed.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/screens/cart_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _row({
  String qtyLabel = '4 Strip',
  String packLabel = '1 Strip of 15 Tablets',
  String mrpLine = 'MRP ₹944.80 × 4',
  bool rx = false,
  bool badge = true,
  List<Map<String, dynamic>> details = const [
    {'key': 'company', 'label': 'Company', 'value': 'Micro Labs Ltd'},
    {'key': 'pack', 'label': 'Pack', 'value': '1 Strip of 15 Tablets'},
  ],
}) =>
    {
      'name': 'Dolo 650',
      'qty_label': qtyLabel,
      'pack_label': packLabel,
      'mrp_line': mrpLine,
      'price_badge': {
        'has': badge,
        'label': 'Sale price: PTR',
        'priced': false,
        'tone': {'bg': '#D1FAE5', 'fg': '#065F46'},
      },
      'rx_chip': {
        'has': rx,
        'label': 'Rx',
        'tone': {'bg': '#EFF6FF', 'fg': '#1E40AF'},
      },
      'detail_rows': details,
    };

/// One cart line, adopted the way the app adopts one: through the payload.
Future<CartLine> _line(Map<String, dynamic>? row) async {
  CartModel.rpcTransport = (fn, params) async => {
        'items': [
          {
            'id': 1,
            'product_id': '101',
            'product_name': 'Dolo 650',
            'quantity': 4,
            'mrp': 944.80,
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

Map<String, dynamic> _summary({
  bool showLine = false,
  String rateNote = 'Rate confirmed after supplier quote.',
  List<Map<String, dynamic>> rows = const [
    {'key': 'items', 'label': 'Items', 'amount': '5', 'strong': false},
    {
      'key': 'mrp_total',
      'label': 'MRP total',
      'amount': '₹4,726.00',
      'strong': false
    },
    {'key': 'delivery', 'label': 'Delivery', 'amount': 'FREE', 'strong': false},
  ],
}) =>
    {
      'summary': {
        'line': '5 items',
        'show_line': showLine,
        'has_amount': showLine,
        'amount_display': showLine ? '₹3,201.40' : '',
        'rate_note': rateNote,
        'delivery_note': '',
        'rows': rows,
      }
    };

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('CMD #1912 — a cart row prints the payload', () {
    tearDown(() => CartModel.rpcTransport = null);

    test('the quantity label is the backend\'s, not the pack string\'s',
        () async {
      // The pack says "Strip". The payload says "Box". The payload wins —
      // this is the exact disagreement _CartStepper._unit() could create.
      final line = await _line(_row(qtyLabel: '4 Box'));
      expect(line.rows('qty_label'), '4 Box');
      expect(line.rows('pack_label'), '1 Strip of 15 Tablets');
    });

    test('the price line and the badge are verbatim', () async {
      final line = await _line(_row());
      expect(line.rows('mrp_line'), 'MRP ₹944.80 × 4');
      expect(line.rowMap('price_badge')['label'], 'Sale price: PTR');
      expect(line.rowMap('price_badge')['has'], isTrue);
    });

    test('no row payload means empty strings, never a local fallback',
        () async {
      final line = await _line(null);
      expect(line.row, isEmpty);
      expect(line.rows('qty_label'), '');
      expect(line.rows('pack_label'), '');
      expect(line.rows('mrp_line'), '');
      expect(line.rowDetails, isEmpty);
      expect(line.rowMap('rx_chip'), isEmpty);
    });

    test('the Rx chip is a per-line flag', () async {
      expect((await _line(_row())).rowMap('rx_chip')['has'], isFalse);
      final rx = await _line(_row(rx: true));
      expect(rx.rowMap('rx_chip')['has'], isTrue);
      expect(rx.rowMap('rx_chip')['label'], 'Rx');
    });

    test('detail rows keep payload order and omit what is absent', () async {
      // Deliberately not alphabetical, and with no MRP row — the expanded
      // body's price line already prints the MRP.
      final line = await _line(_row());
      expect(line.rowDetails.map((d) => d['key']).toList(),
          ['company', 'pack']);
      expect(line.rowDetails.any((d) => d['key'] == 'mrp'), isFalse);

      final bare = await _line(_row(details: const []));
      expect(bare.rowDetails, isEmpty);
    });
  });

  group('CMD #1912 — the summary says the rate once', () {
    testWidgets('rows render in payload order with the rate note once',
        (tester) async {
      await _pump(tester, C572TotalsBlock(render: _summary()));

      expect(find.text('Items'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('MRP total'), findsOneWidget);
      expect(find.text('₹4,726.00'), findsOneWidget);
      expect(find.text('Delivery'), findsOneWidget);
      expect(find.text('FREE'), findsOneWidget);
      expect(find.text('Rate confirmed after supplier quote.'), findsOneWidget);

      // show_line false → the line that repeated the item count is gone.
      expect(find.text('5 items'), findsNothing);

      // Exactly one divider in the block.
      expect(find.byType(Divider), findsOneWidget);
    });

    testWidgets('the line comes back when there is an amount beside it',
        (tester) async {
      await _pump(tester, C572TotalsBlock(render: _summary(showLine: true)));
      expect(find.text('5 items'), findsOneWidget);
      expect(find.text('₹3,201.40'), findsOneWidget);
    });

    testWidgets('no rate note means no sentence invented', (tester) async {
      await _pump(tester, C572TotalsBlock(render: _summary(rateNote: '')));
      expect(find.textContaining('supplier quote'), findsNothing);
    });

    testWidgets('an empty summary draws nothing', (tester) async {
      await _pump(
          tester,
          const C572TotalsBlock(render: {
            'summary': {'rows': [], 'rate_note': '', 'show_line': false}
          }));
      expect(find.byType(Divider), findsNothing);
      expect(find.byType(Text), findsNothing);
    });
  });
}
