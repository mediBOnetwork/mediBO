// CMD #2123 — the cart and the Bulk Upload review list draw ONE row card.
//
// Holds down: the row variant prints the payload's four lines verbatim, the
// photo is exactly as tall as the text block beside it, the locked word never
// becomes a number, the qty chip is a 44px control while a state line is one
// text line, and the Rx badge appears only when the payload sent one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/product_row_card.dart';

Product _p() => Product.fromJson(const {
      'id': 'p1',
      'name': 'aztOR 40 Tablet',
      'image_url': '',
    });

Future<void> _pump(WidgetTester t, Widget w) async {
  await t.binding.setSurfaceSize(const Size(360, 800));
  await t.pumpWidget(MaterialApp(home: Scaffold(body: w)));
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('cart shape: four payload lines, photo = block, chip is 44px',
      (t) async {
    await _pump(
        t,
        ProductRowCard(
          surface: 'cart',
          product: _p(),
          name: 'aztOR 40 Tablet',
          line2: 'Atorvastatin 40mg',
          price: RowPriceBadge.fromMap(const {
            'has': true,
            'label': 'Sale price:',
            'value': 'PTR',
            'bg': '#1B7A43',
            'fg': '#FFFFFF'
          }),
          line4: RowQtyChip(
              chip: const {'has': true, 'label': '5 strip', 'qty': 5},
              onPicked: (_) {}),
          line4IsControl: true,
          rx: const {'has': true, 'label': 'Rx'},
          trailing: const SizedBox(width: 44, height: 44),
        ));
    expect(find.text('aztOR 40 Tablet'), findsOneWidget);
    expect(find.text('Atorvastatin 40mg'), findsOneWidget);
    expect(find.text('Sale price:'), findsOneWidget);
    expect(find.text('PTR'), findsOneWidget);
    expect(find.textContaining('₹'), findsNothing);
    expect(find.text('5 strip'), findsOneWidget);
    expect(find.text('Rx'), findsOneWidget);
    final side = ProductRowCard.blockHeight(controlLine: true);
    expect(t.getSize(find.byType(RowThumb)).height, side);
    expect(t.getSize(find.byType(InkWell).last).height,
        greaterThanOrEqualTo(44.0));
    expect(t.takeException(), isNull);
  });

  testWidgets('bulk shape: state line is one text line, no Rx when absent',
      (t) async {
    await _pump(
        t,
        ProductRowCard(
          surface: 'bulk',
          product: _p(),
          name: 'Dexolan 30 Capsule MR',
          line2: '17 piece',
          price: const RowPriceBadge(label: 'Sale price:', value: '₹96.30'),
          line4: const RowStateBadge(label: 'Available'),
        ));
    expect(find.text('17 piece'), findsOneWidget);
    expect(find.text('₹96.30'), findsOneWidget);
    expect(find.text('Available'), findsOneWidget);
    expect(find.text('Rx'), findsNothing);
    expect(t.getSize(find.byType(RowThumb)).height,
        ProductRowCard.blockHeight());
  });

  testWidgets('absence is absence: empty line 2 and no badge draw nothing',
      (t) async {
    await _pump(
        t,
        ProductRowCard(
          surface: 'cart',
          product: _p(),
          name: 'X',
          line2: '',
          price: RowPriceBadge.fromMap(const {'has': false}),
        ));
    expect(find.byType(Text), findsOneWidget);
  });
}
