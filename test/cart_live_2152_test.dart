// CMD #2152 — Cart live totals, instant receive mode, swipe-tip "Got it",
// CD strip in the scroll with its burst.
//
//  1. cart_update_item's summary.v2 is adopted whole: the v2 bill's MRP total
//     and the bar's advance move on the tap, with no cart_render re-read.
//  2. Delivery / Self pickup selects in the tap's own frame; the saved
//     `receive` block the RPC returns is adopted, and a refusal falls back to
//     the server's block without a second read.
//  3. "Got it" hides the tip before cart_swipe_tip_seen answers, and the
//     button actually receives the tap.
//  4. The CD burst badge animates over ~900 ms without changing its size.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/cart_v2_widgets.dart';

Map<String, dynamic> _receive(String sel) => {
      'has': true,
      'title': 'How do you want to receive it?',
      'selected': sel,
      'options': [
        {'key': 'delivery', 'label': 'Delivery', 'sub': 'To your shop', 'icon': 'local_shipping', 'enabled': true},
        {'key': 'pickup', 'label': 'Self pickup', 'sub': 'From partner', 'icon': 'storefront', 'enabled': true},
      ],
      'boxes': {
        'delivery': {'lead': 'Deliver to', 'name': 'A', 'address': '', 'note': 'n'},
        'pickup': {'lead': 'Collect from', 'name': 'B', 'address': '', 'note': 'n'},
      },
    };

Map<String, dynamic> _v2({String mrp = '₹100.00', String adv = '₹30.00', bool tip = true, String sel = 'delivery'}) => {
      'has': true,
      'cd_strip': {'has': true, 'interval_ms': 0, 'slides': [{'lead': '3% CD', 'rest': 'on orders above ₹3K'}]},
      'swipe_tip': {'show': tip, 'bold': 'Swipe left', 'rest': 'on a product to remove it', 'ok': 'Got it'},
      'bill': {'has': true, 'mrp_value': mrp},
      'bar': {'advance_label': 'Advance to pay', 'advance_value': adv, 'place': 'Place order'},
      'receive': _receive(sel),
    };

Map<String, dynamic> _item(int qty) => {
      'id': 1,
      'product_id': '101',
      'product_name': 'Azee 500',
      'quantity': qty,
      'mrp': 100.0,
      'image_url': '',
      'buyable': true,
    };

Map<String, dynamic> _open() => {
      'items': [_item(1)],
      'item_count': 1,
      'unit_count': 1,
      'render': {'subtotal_display': '₹100.00'},
      'unavailable_count': 0,
      'v2': _v2(),
    };

Future<(CartModel, List<String>)> _opened(
    Future<dynamic> Function(String fn, Map<String, dynamic>? p) onWrite) async {
  final calls = <String>[];
  CartModel.rpcTransport = (fn, params) async {
    calls.add(fn);
    if (fn == 'cart_render') return _open();
    return onWrite(fn, params);
  };
  final cart = CartModel.forTest();
  await cart.refresh();
  calls.clear();
  return (cart, calls);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    RenderLog.flushEnabled = false;
  });
  setUp(() =>
      SharedPreferences.setMockInitialValues({'medibo_guest_uid': 'guest-1'}));
  tearDown(() => CartModel.rpcTransport = null);

  testWidgets('1. a qty tap adopts summary.v2 — MRP total and advance move',
      (tester) async {
    final (cart, calls) = await _opened((fn, p) async => {
          'ok': true,
          'product_id': '101',
          'removed': false,
          'item': _item(3),
          'summary': {
            'item_count': 1,
            'unit_count': 3,
            'mrp_total': 300,
            'bottom': {'has': true, 'advance_display': '₹90.00'},
            'v2': _v2(mrp: '₹300.00', adv: '₹90.00'),
          },
        });
    expect((cart.v2Block['bill'] as Map)['mrp_value'], '₹100.00');

    cart.setQuantityId('101', 3);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(calls, ['cart_update_item'], reason: 'no cart_render re-read');
    expect((cart.v2Block['bill'] as Map)['mrp_value'], '₹300.00');
    expect((cart.v2Block['bar'] as Map)['advance_value'], '₹90.00');
  });

  test('2a. receive mode selects before the save answers', () async {
    final (cart, calls) = await _opened((fn, p) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return {'ok': true, 'receive': _receive('pickup')};
    });
    final f = cart.setReceiveMode('pickup');
    expect((cart.v2Block['receive'] as Map)['selected'], 'pickup',
        reason: 'the tap is on screen before the RPC answers');
    await f;
    expect(calls, ['cart_set_receive_mode'], reason: 'no re-read after save');
    expect((cart.v2Block['receive'] as Map)['selected'], 'pickup');
  });

  test('2b. a refused pick falls back to the server block', () async {
    final (cart, calls) = await _opened((fn, p) async =>
        {'ok': false, 'error': 'no_partner', 'receive': _receive('delivery')});
    await cart.setReceiveMode('pickup');
    expect(calls, ['cart_set_receive_mode']);
    expect((cart.v2Block['receive'] as Map)['selected'], 'delivery');
  });

  testWidgets('3. Got it receives the tap and hides the tip instantly',
      (tester) async {
    final (cart, calls) = await _opened((fn, p) async => {'ok': true});
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: cart,
          builder: (_, _) => Column(children: [
            CartSwipeTip(
                block: (cart.v2Block['swipe_tip'] as Map).cast<String, dynamic>(),
                onOk: cart.swipeTipSeen),
          ]),
        ),
      ),
    ));
    expect(find.text('Got it'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pump();
    expect(find.text('Got it'), findsNothing, reason: 'hidden in the tap frame');
    expect(calls, ['cart_swipe_tip_seen']);
  });

  testWidgets('4. the CD burst plays ~900 ms and never resizes the badge',
      (tester) async {
    final c = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: kCdBurstMs));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: CdBurstBadge(progress: c, label: '5% CD', ink: Colors.orange),
        ),
      ),
    ));
    final rest = tester.getSize(find.byType(CdBurstBadge));
    expect(find.text('5% CD'), findsNothing, reason: 'at rest: the % tile only');
    c.forward(from: 0);
    await tester.pump(); // the ticker's first frame
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('5% CD'), findsOneWidget, reason: 'risen');
    expect(tester.getSize(find.byType(CdBurstBadge)), rest);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('5% CD'), findsNothing, reason: 'floated up and faded');
    c.dispose();
  });
}
