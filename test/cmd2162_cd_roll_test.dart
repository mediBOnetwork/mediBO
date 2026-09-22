// CMD #2162 — the cart CD strip rolls one row (pill + text) at a time, the
// Place order popup shows the selected mode as three lines, and the receive
// box shows the advance badge above the remaining-due badge.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/cart_v2_widgets.dart';

Widget _host(Widget child, {bool reduce = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: const Size(360, 780), disableAnimations: reduce),
        child: Scaffold(body: Column(children: [child])),
      ),
    );

const _slides = [
  {'lead': '3% CD', 'rest': 'on orders above ₹2,999'},
  {'lead': '5% CD', 'rest': 'on orders above ₹5,999'},
  {'lead': '8% CD', 'rest': 'on orders above ₹9,999'},
];

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('one row: pill = lead, text = rest, no % icon, lead said once',
      (t) async {
    await t.pumpWidget(_host(const CartCdStrip(
        block: {'has': true, 'interval_ms': 3000, 'slides': _slides})));
    expect(find.byIcon(Icons.percent), findsNothing);
    expect(find.text('3% CD'), findsOneWidget);
    expect(find.text('on orders above ₹2,999'), findsOneWidget);
    expect(find.textContaining('3% CD on'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('every interval pill and text roll together, in order, looping',
      (t) async {
    await t.pumpWidget(_host(const CartCdStrip(
        block: {'has': true, 'interval_ms': 3000, 'slides': _slides})));
    final strip = t.getRect(find.byType(CartCdStrip));
    await t.pump(const Duration(milliseconds: 3000));
    await t.pump(const Duration(milliseconds: 200)); // mid-roll
    // Both rows are on screen, moving together: pill and text share a dy.
    expect(find.text('3% CD'), findsOneWidget);
    expect(find.text('5% CD'), findsOneWidget);
    final pillIn = t.getRect(find.text('5% CD'));
    final textIn = t.getRect(find.text('on orders above ₹5,999'));
    expect((pillIn.center.dy - textIn.center.dy).abs(), lessThan(1));
    final pillOut = t.getRect(find.text('3% CD'));
    expect(pillOut.center.dy, lessThan(pillIn.center.dy),
        reason: 'old row goes up, new row rises from below');
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('3% CD'), findsNothing);
    expect(find.text('5% CD'), findsOneWidget);
    expect(t.getRect(find.byType(CartCdStrip)), strip, reason: 'never resizes');
    await t.pump(const Duration(milliseconds: 3000));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('8% CD'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 3000));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('3% CD'), findsOneWidget, reason: 'loops');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('touch pauses; one slab is static', (t) async {
    await t.pumpWidget(_host(const CartCdStrip(
        block: {'has': true, 'interval_ms': 3000, 'slides': _slides})));
    final g = await t.startGesture(t.getCenter(find.byType(CartCdStrip)));
    await t.pump(const Duration(milliseconds: 3000));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('3% CD'), findsOneWidget);
    expect(find.text('5% CD'), findsNothing);
    await g.up();
    await t.pumpWidget(_host(const CartCdStrip(block: {
      'has': true,
      'interval_ms': 3000,
      'slides': [
        {'lead': '8% CD', 'rest': 'on orders above ₹9,999'}
      ]
    })));
    await t.pump(const Duration(milliseconds: 7000));
    expect(find.text('8% CD'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion cross-fades in place', (t) async {
    await t.pumpWidget(_host(
        const CartCdStrip(
            block: {'has': true, 'interval_ms': 3000, 'slides': _slides}),
        reduce: true));
    final y0 = t.getRect(find.text('3% CD')).center.dy;
    await t.pump(const Duration(milliseconds: 3000));
    await t.pump(const Duration(milliseconds: 200));
    expect(t.getRect(find.text('5% CD')).center.dy, closeTo(y0, 0.5));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('popup: selected mode as three lines instead of the chip',
      (t) async {
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showCartV2Popup(ctx, {
            'key': 'confirm',
            'title': 'Place this order?',
            'chip': 'Delivery · pay remaining due before dispatch',
            'mode': {
              'has': true,
              'icon': 'local_shipping',
              'title': 'Delivery',
              'advance_note': 'Pay advance now',
              'note': 'Pay remaining due before dispatch',
            },
            'primary': {'label': 'Place order'},
            'secondary': {'has': true, 'label': 'Cancel'},
          }),
          child: const Text('open'),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Place this order?'), findsOneWidget);
    expect(find.text('Delivery'), findsOneWidget);
    expect(find.text('Pay advance now'), findsOneWidget);
    expect(find.text('Pay remaining due before dispatch'), findsOneWidget);
    expect(find.text('Delivery · pay remaining due before dispatch'), findsNothing);
  });

  testWidgets('receive box: advance badge, then remaining-due badge',
      (t) async {
    Map<String, dynamic> box(String note) => {
          'lead': 'Deliver to',
          'name': 'Shop',
          'address': 'Road',
          'advance_note': 'Pay advance now',
          'note': note,
        };
    await t.pumpWidget(_host(CartReceiveBox(block: {
      'has': true,
      'title': 'How do you want to receive it?',
      'selected': 'delivery',
      'options': [
        {'key': 'delivery', 'label': 'Delivery', 'enabled': true},
        {'key': 'pickup', 'label': 'Self pickup', 'enabled': true},
      ],
      'boxes': {
        'delivery': box('Pay remaining due before dispatch'),
        'pickup': box('Pay remaining due at the shop'),
      },
    }, onSelect: (_) {})));
    final adv = t.getRect(find.text('Pay advance now').first);
    final due = t.getRect(find.text('Pay remaining due before dispatch'));
    expect(adv.top, lessThan(due.top));
  });
}
