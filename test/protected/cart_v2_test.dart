// CMD #2139 — Cart v2 holds these down:
//  * the bill prints the payload verbatim (MRP line, "On your final bill",
//    the folded fees line with its struck total and FREE, the savings line,
//    the advance) and opens to the four fee rows only on tap;
//  * the receive box keeps ONE height whichever mode is selected, so switching
//    Delivery / Self pickup never moves what sits below it;
//  * the green bar prints advance label, amount and Place order verbatim;
//  * the CD strip shows nothing when the backend says has:false.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/cart_v2_widgets.dart';

Map<String, dynamic> _bill() => {
      'has': true,
      'title': 'Bill summary',
      'mrp_label': 'MRP total · 3 items',
      'mrp_value': '₹3,686.70',
      'sale_label': 'Sale price total',
      'sale_value': 'On your final bill',
      'fees_has': true,
      'fees_label': 'Fees',
      'fees_struck': '₹76.00',
      'fees_value': 'FREE',
      'fees_free': true,
      'fees': [
        for (final k in ['Handling fee', 'Packaging fee', 'Delivery fee', 'Platform fee'])
          {'key': k, 'label': k, 'struck': '₹19.00', 'value': 'FREE', 'free': true,
           'info': {'has': false}},
      ],
      'savings': {'has': true, 'text': 'You save ₹76 on fees with this order'},
      'advance_label': 'Advance to pay',
      'advance_value': '₹368.67',
    };

Map<String, dynamic> _receive(String sel) => {
      'has': true,
      'title': 'How do you want to receive it?',
      'selected': sel,
      'options': [
        {'key': 'delivery', 'icon': 'local_shipping', 'label': 'Delivery', 'sub': 'To your shop', 'enabled': true},
        {'key': 'pickup', 'icon': 'storefront', 'label': 'Self pickup', 'sub': 'Collect from our partner', 'enabled': true},
      ],
      'boxes': {
        'delivery': {'lead': 'Deliver to', 'name': 'Pomo Pharmacy', 'address': 'Shop 4, Raipur 492004', 'note': 'Pay remaining due before dispatch'},
        'pickup': {'lead': 'Collect from', 'name': 'UNIVERSAL PHARMA', 'address': 'Shop No 19, New Medical Complex, Rajbandha Maidan, Raipur 492001', 'note': 'Pay remaining due at the shop'},
      },
    };

Widget _host(Widget w) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: SizedBox(width: 360, child: w))));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('bill prints the payload verbatim and folds the fees', (t) async {
    await t.pumpWidget(_host(CartBillV2(block: _bill())));
    for (final s in ['Bill summary', 'MRP total · 3 items', '₹3,686.70', 'On your final bill',
        'Fees', '₹76.00', 'You save ₹76 on fees with this order', 'Advance to pay', '₹368.67']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.text('Handling fee'), findsNothing);
    await t.tap(find.text('Fees'));
    await t.pumpAndSettle();
    expect(find.text('Handling fee'), findsOneWidget);
    expect(find.text('Platform fee'), findsOneWidget);
  });

  testWidgets('receive box height does not change with the mode', (t) async {
    await t.pumpWidget(_host(CartReceiveBox(block: _receive('delivery'), onSelect: (_) {})));
    final h1 = t.getSize(find.byType(CartReceiveBox)).height;
    await t.pumpWidget(_host(CartReceiveBox(block: _receive('pickup'), onSelect: (_) {})));
    final h2 = t.getSize(find.byType(CartReceiveBox)).height;
    expect(h1, h2);
  });

  testWidgets('bar and empty CD strip', (t) async {
    await t.pumpWidget(_host(Column(children: [
      const CartCdStrip(block: {'has': false, 'slides': []}),
      CartV2Bar(block: const {'advance_label': 'Advance to pay', 'advance_value': '₹368.67', 'place': 'Place order'}, onPlace: () {}),
    ])));
    expect(find.text('Place order'), findsOneWidget);
    expect(find.text('₹368.67'), findsOneWidget);
    expect(find.byIcon(Icons.percent), findsNothing);
  });
}
