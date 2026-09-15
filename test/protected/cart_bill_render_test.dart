// PROTECTED — CMD #2047.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the cart's bill summary and suggested rail reach
// the screen.
//
// WHY THIS FILE EXISTS. #2014 built both blocks correctly and they still were
// not in the app. They rode a SECOND call — cart_bill_view() — made by the
// cart screen next to the cart_render() it was already making, and every one
// of that call's failure modes is silent: a customer resolved differently from
// the basket being described, a rail that throws on real catalogue data, a
// response that loses the race with a quantity tap. Nothing was logged and
// nothing was drawn. So the rule this file holds down is not "the bill looks
// right" — it is THE BLOCKS RIDE THE CART PAYLOAD.
//
// What this holds down:
//
//   1. ONE payload, ONE call. Loading the cart calls cart_render() and nothing
//      else, and `bill` / `rail` are read off that payload. A second RPC for
//      either block is the bug this command fixed.
//
//   2. Absence is the BACKEND's word. has:false, a missing key, an empty rows
//      list — each makes the block null so the cart omits it, rather than
//      drawing an empty card. The app never decides a row is "not applicable";
//      a row that is in the payload is drawn, in payload order.
//
//   3. Payload ORDER, not a Dart sort. The fixture is deliberately not in
//      alphabetical or numeric order.
//
//   4. A waived fee is the backend's two strings: struck amount + its own word
//      for free. "FREE" is never written in Dart, and a row with no free_label
//      prints none.
//
//   5. Tappable is a payload flag, and the popup prints the backend's title,
//      body and dismiss label verbatim.
//
//   6. An icon NAME the build has never seen renders the row WITHOUT a glyph —
//      a new row ships to an old build rather than crashing it.
//
//   7. The rail is the storefront's own CompactProductCard, in payload order.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';
import 'package:pharma_b2b/widgets/cart_bill_summary.dart';
import 'package:pharma_b2b/widgets/cart_wishlist_rail.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _billRow(
  String key,
  String label,
  String value, {
  String icon = 'local_offer_outlined',
  String tone = 'default',
  bool bold = false,
  bool dividerBefore = false,
  bool waived = false,
  String struck = '',
  String free = '',
  String popupTitle = '',
  String popupBody = '',
  String popupDismiss = '',
}) =>
    {
      'key': key,
      'label': label,
      'icon': icon,
      'value': value,
      'struck_value': struck,
      'free_label': free,
      'waived': waived,
      'tone': tone,
      'bold': bold,
      'divider_before': dividerBefore,
      'tappable': popupTitle.isNotEmpty || popupBody.isNotEmpty,
      'popup': {
        'title': popupTitle,
        'body': popupBody,
        'dismiss': popupDismiss,
      },
    };

/// The bill exactly as cart_render() sends it: already ordered by the admin's
/// sort_order, which is NOT the alphabetical order of the keys.
Map<String, dynamic> _bill() => {
      'has': true,
      'title': 'Bill summary',
      'empty_note': 'Add items to see your bill.',
      'rows': [
        _billRow('mrp_total', 'MRP total', '₹1,800.00'),
        _billRow('trade_total', 'Sale price (PTR)', '₹806.40',
            icon: 'sell_outlined'),
        _billRow('advance', 'Advance amount', '₹180.00',
            icon: 'account_balance_wallet_outlined', tone: 'brand', bold: true),
        _billRow('handling_fee', 'Handling fee', '₹25.00',
            icon: 'inventory_2_outlined',
            popupTitle: 'Handling fee',
            popupBody: 'Covers picking, packing and cold-chain handling.',
            popupDismiss: 'Got it'),
        _billRow('delivery_fee', 'Delivery fee', '',
            icon: 'local_shipping_outlined',
            waived: true,
            struck: '₹49.00',
            free: 'FREE',
            popupTitle: 'Delivery fee',
            popupBody: 'Waived once the order crosses the free-delivery slab.',
            popupDismiss: 'Got it'),
        _billRow('grand_total', 'Grand total', '₹831.40',
            icon: 'receipt_long_outlined',
            tone: 'total',
            bold: true,
            dividerBefore: true),
      ],
    };

Map<String, dynamic> _railCard(int id, String name) => {
      'id': id,
      'name': name,
      'company': 'CIPLA LTD',
      'image': '',
      'pack_label': 'strip',
      'form_chip': '10',
      'mrp_label': 'MRP ₹100.00',
      'pricing': {
        'has_price': true,
        'mrp': 100,
        'sale_price': 40.00,
        'price_display': '₹40.00',
        'mrp_display': '₹100.00',
        'price_caption': 'PTR',
        'has_struck_mrp': true,
        'has_discount': false,
        'discount_label': '',
        'ribbon_top': '',
        'ribbon_bottom': '',
      },
      'availability': {
        'is_available': true,
        'can_add': true,
        'cta_label': 'Add to cart',
        'cta_short': 'ADD',
        'gated': true,
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      },
    };

Map<String, dynamic> _rail() => {
      'has': true,
      'title': 'You may also need',
      'items': [
        _railCard(22, 'Zincovit Tablet'),
        _railCard(7, 'Azee 500 Tablet'),
        _railCard(15, 'Dolo 650 Tablet'),
      ],
    };

/// A cart_render() payload. The two blocks sit on it, beside the items — there
/// is no second payload anywhere in this file, because there is no second call.
Map<String, dynamic> _cartPayload({
  Object? bill,
  Object? rail,
}) =>
    {
      'items': [
        {
          'id': 1,
          'product_id': 1,
          'product_name': 'Azee 500 Tablet',
          'quantity': 9,
          'mrp': 100.0,
          'image_url': '',
          'manufacturer': 'CIPLA LTD',
          'pack_size': 'strip',
          'category': 'ANTI INFECTIVES',
          'buyable': true,
        },
      ],
      'item_count': 1,
      'unit_count': 9,
      'render': {'subtotal_display': '₹806.40'},
      'unavailable_count': 0,
      if (bill != null) 'bill': bill,
      if (rail != null) 'rail': rail,
    };

Future<CartModel> _loaded(Map<String, dynamic> payload, List<String> calls) async {
  CartModel.rpcTransport = (fn, params) async {
    calls.add(fn);
    return payload;
  };
  final cart = CartModel.forTest();
  await cart.refresh();
  return cart;
}

Future<void> _pumpBill(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(
    children: [child],
  ))));
  await tester.pump();
}

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  tearDown(() => CartModel.rpcTransport = null);

  group('1. the blocks ride the ONE cart payload', () {
    test('loading the cart calls cart_render and nothing else', () async {
      final calls = <String>[];
      final cart = await _loaded(_cartPayload(bill: _bill(), rail: _rail()), calls);

      expect(calls, ['cart_render'],
          reason: 'a second RPC for the bill or the rail is the #2014 bug');
      expect(cart.billBlock['has'], isTrue);
      expect(cart.railBlock['has'], isTrue);
    });

    test('bill and rail come off the payload verbatim', () async {
      final cart = await _loaded(
          _cartPayload(bill: _bill(), rail: _rail()), <String>[]);

      expect(cart.billBlock['title'], 'Bill summary');
      expect((cart.billBlock['rows'] as List).length, 6);
      expect(cart.railBlock['title'], 'You may also need');
      expect((cart.railBlock['items'] as List).length, 3);
    });

    test('a payload without the blocks yields empty maps, never a throw',
        () async {
      final cart = await _loaded(_cartPayload(), <String>[]);

      expect(cart.billBlock, isEmpty);
      expect(cart.railBlock, isEmpty);
      expect(CartBillSummary.fromPayload(cart.billBlock), isNull);
      expect(CartWishlistRail.fromPayload(cart.railBlock, (_) {}), isNull);
    });
  });

  group('2. absence is the backend\'s word', () {
    test('has:false omits the block', () {
      expect(
          CartBillSummary.fromPayload(
              {'has': false, 'title': 'Bill summary', 'rows': [_billRow('x', 'X', '₹1')]}),
          isNull);
      expect(
          CartWishlistRail.fromPayload(
              {'has': false, 'title': 'T', 'items': [_railCard(1, 'A')]}, (_) {}),
          isNull);
    });

    test('has:true with no rows omits the block rather than drawing an empty card',
        () {
      expect(CartBillSummary.fromPayload({'has': true, 'title': 'Bill', 'rows': []}),
          isNull);
      expect(CartWishlistRail.fromPayload({'has': true, 'title': 'T', 'items': []},
              (_) {}),
          isNull);
    });
  });

  group('3. rows render in PAYLOAD order', () {
    testWidgets('the fixture order survives — no Dart sort', (tester) async {
      final bill = CartBillSummary.fromPayload(_bill())!;
      expect(bill.rows.map((r) => r.key).toList(), [
        'mrp_total',
        'trade_total',
        'advance',
        'handling_fee',
        'delivery_fee',
        'grand_total',
      ]);

      await _pumpBill(tester, bill);
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      expect(labels.indexOf('MRP total') < labels.indexOf('Advance amount'),
          isTrue);
      expect(labels.indexOf('Advance amount') < labels.indexOf('Grand total'),
          isTrue);
    });
  });

  group('4. a waived fee is the backend\'s two strings', () {
    testWidgets('struck amount + the backend\'s own word for free',
        (tester) async {
      await _pumpBill(tester, CartBillSummary.fromPayload(_bill())!);

      expect(find.text('₹49.00'), findsOneWidget);
      expect(find.text('FREE'), findsOneWidget);

      final struck = tester.widget<Text>(find.text('₹49.00'));
      expect(struck.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('no free_label prints no free word — "FREE" is never a literal',
        (tester) async {
      final rows = _bill();
      (rows['rows'] as List)[4] = _billRow('delivery_fee', 'Delivery fee', '',
          icon: 'local_shipping_outlined',
          waived: true,
          struck: '₹49.00',
          free: '');
      await _pumpBill(tester, CartBillSummary.fromPayload(rows)!);

      expect(find.text('₹49.00'), findsOneWidget);
      expect(find.text('FREE'), findsNothing);
      expect(find.text('Free'), findsNothing);
    });
  });

  group('5. the popup is the backend\'s copy', () {
    testWidgets('tapping a tappable row opens title/body/dismiss verbatim',
        (tester) async {
      await _pumpBill(tester, CartBillSummary.fromPayload(_bill())!);

      await tester.tap(find.text('Handling fee'));
      await tester.pumpAndSettle();

      expect(find.text('Covers picking, packing and cold-chain handling.'),
          findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(find.text('Covers picking, packing and cold-chain handling.'),
          findsNothing);
    });

    testWidgets('a row the payload did not mark tappable opens nothing',
        (tester) async {
      await _pumpBill(tester, CartBillSummary.fromPayload(_bill())!);

      await tester.tap(find.text('MRP total'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('6. an unknown icon name does not crash an old build', () {
    testWidgets('the row renders, just without a glyph', (tester) async {
      final rows = _bill();
      (rows['rows'] as List).add(
          _billRow('loyalty_credit', 'Loyalty credit', '₹10.00',
              icon: 'a_glyph_this_build_has_never_heard_of'));

      expect(CartBillSummary.glyphFor('a_glyph_this_build_has_never_heard_of'),
          isNull);

      await _pumpBill(tester, CartBillSummary.fromPayload(rows)!);
      expect(find.text('Loyalty credit'), findsOneWidget);
      expect(find.text('₹10.00'), findsOneWidget);
    });
  });

  group('7. the rail is the storefront card, in payload order', () {
    testWidgets('CompactProductCard, one per payload item, same order',
        (tester) async {
      final tapped = <String>[];
      final rail = CartWishlistRail.fromPayload(_rail(), (p) => tapped.add(p.id))!;

      expect(rail.items.map((p) => p.id).toList(), ['22', '7', '15']);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AppState(
            cart: CartModel.forTest(),
            child: SizedBox(width: 360, child: rail),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('You may also need'), findsOneWidget);
      expect(find.byType(CompactProductCard), findsWidgets);
    });
  });
}
