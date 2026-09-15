// PROTECTED — CMD #2039.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the cart opens, how it is cleared, or how a tap is
// echoed.
//
// What this holds down:
//
//   1. THE SUMMARY ROW COMES WITH THE ITEMS. `render.summary.bottom` arrives
//      in the SAME payload the lines arrive in, so the row is readable the
//      moment the cart opens — not only after a quantity tap patched it in.
//      Its four strings are printed verbatim and `has_advance` is the
//      backend's answer to "is there an advance?", never an amount inferred
//      from a number the app found lying around.
//
//   2. AN UNREAD CART IS NOT AN EMPTY CART. `hasLoaded` is false until a
//      payload lands, which is what tells the screen to draw the skeleton
//      instead of "your cart is empty"; it flips on the first adopted payload
//      and goes back to false when the account changes.
//
//   3. CLEAR ASKS NOTHING AND CAN BE TAKEN BACK. `clear()` sends `cart_clear`
//      and returns the backend's own `undo` block — the sentence, the action
//      word and the seconds — with nothing worded in Dart. A cart the backend
//      says has nothing to undo returns an EMPTY block, so no snackbar can
//      offer an Undo the server cannot honour.
//
//   4. UNDO IS THE BACKEND'S ANSWER TOO. `undoClear()` sends the snapshot id
//      to `cart_clear_undo`, adopts the cart that comes back (no re-read) and
//      returns the backend's message — including the refusal, verbatim, when
//      the window has closed.
//
//   5. THE STEPPER PRINTS THE USER'S OWN TAP WHILE ONE IS OUTSTANDING.
//      `row.stepper.qty_text` is the SERVER's number and is one tap stale
//      between the tap and the reply; `hasLocalIntent` is what the screen
//      reads to stop printing it, and it clears again once the server has
//      acknowledged the tap.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/screens/cart_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _bottom({
  String itemsLabel = 'Total items',
  String itemsValue = '2',
  String advanceLabel = 'Advance to pay',
  String advance = '₹600.00',
  bool has = true,
}) =>
    {
      'has': has,
      'items_label': itemsLabel,
      'items_value': itemsValue,
      'advance_label': advanceLabel,
      'has_advance': advance.isNotEmpty,
      'advance_display': advance,
    };

Map<String, dynamic> _item({String id = '101', int qty = 1}) => {
      'id': 1,
      'product_id': id,
      'product_name': 'Dolo 650',
      'quantity': qty,
      'mrp': 944.80,
      'image_url': '',
      'manufacturer': 'Micro Labs Ltd',
      'pack_size': '',
      'category': 'ANALGESICS',
      'row': {
        'name': 'Dolo 650',
        'stepper': {'qty': qty, 'qty_text': '$qty', 'unit_label': 'Strip'},
        'retry': {'label': 'Retry', 'note': 'Not saved'},
      },
    };

/// One OPEN read: the lines and the summary row, together, in one payload.
Map<String, dynamic> _openPayload() => {
      'items': [_item(), _item(id: '202', qty: 2)],
      'item_count': 2,
      'unit_count': 3,
      'render': {
        'item_count': 2,
        'items_label': '2 items',
        'summary': {'bottom': _bottom()},
      },
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    RenderLog.flushEnabled = false;
  });
  setUp(() =>
      SharedPreferences.setMockInitialValues({'medibo_guest_uid': 'guest-1'}));
  tearDown(() => CartModel.rpcTransport = null);

  // ── 1 ──────────────────────────────────────────────────────────────────────
  group('the summary row arrives with the items', () {
    testWidgets('the OPEN payload alone is enough to draw both halves',
        (tester) async {
      CartModel.rpcTransport = (fn, p) async => _openPayload();
      final cart = CartModel.forTest();
      await cart.refresh();

      // Nothing has been tapped. The row's strings are already here.
      final b = ((cart.render['summary'] as Map)['bottom'] as Map);
      expect(b['items_value'], '2');
      expect(b['advance_display'], '₹600.00');

      await tester.pumpWidget(_host(C2013SummaryRow(render: cart.render)));
      expect(find.text('Total items'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Advance to pay'), findsOneWidget);
      expect(find.text('₹600.00'), findsOneWidget);
    });

    testWidgets('every one of the four strings is the payload\'s, verbatim',
        (tester) async {
      await tester.pumpWidget(_host(C2013SummaryRow(render: {
        'summary': {
          'bottom': _bottom(
              itemsLabel: 'Items in basket',
              itemsValue: '11',
              advanceLabel: 'Pay now',
              advance: '₹1,234.50'),
        },
      })));
      expect(find.text('Items in basket'), findsOneWidget);
      expect(find.text('11'), findsOneWidget);
      expect(find.text('Pay now'), findsOneWidget);
      expect(find.text('₹1,234.50'), findsOneWidget);
      // Nothing the payload did not send.
      expect(find.text('Total items'), findsNothing);
    });

    testWidgets('no advance from the backend means no advance on screen',
        (tester) async {
      await tester.pumpWidget(_host(C2013SummaryRow(render: {
        'summary': {'bottom': _bottom(advance: '')},
      })));
      expect(find.text('Total items'), findsOneWidget);
      expect(find.text('Advance to pay'), findsNothing);
    });

    testWidgets('has:false draws nothing at all', (tester) async {
      await tester.pumpWidget(_host(C2013SummaryRow(render: {
        'summary': {'bottom': _bottom(has: false)},
      })));
      expect(find.text('Total items'), findsNothing);
      expect(find.text('₹600.00'), findsNothing);
    });
  });

  // ── 2 ──────────────────────────────────────────────────────────────────────
  group('an unread cart is not an empty cart', () {
    test('hasLoaded is false before the first payload and true after',
        () async {
      CartModel.rpcTransport = (fn, p) async => _openPayload();
      final cart = CartModel.forTest();
      expect(cart.hasLoaded, isFalse,
          reason: 'nothing has been read yet — this is the skeleton state');
      await cart.refresh();
      expect(cart.hasLoaded, isTrue);
    });

    testWidgets('the skeleton draws shapes and no words', (tester) async {
      await tester.pumpWidget(_host(const C2039CartSkeleton()));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(C2039CartSkeleton), findsOneWidget);
      expect(find.byType(Text), findsNothing,
          reason: 'a skeleton that guessed at labels would be writing copy');
    });
  });

  // ── 3 ──────────────────────────────────────────────────────────────────────
  group('Clear cart asks nothing and can be taken back', () {
    test('clear() sends cart_clear and returns the backend\'s undo block',
        () async {
      final calls = <String>[];
      CartModel.rpcTransport = (fn, p) async {
        calls.add(fn);
        if (fn == 'cart_render') return _openPayload();
        return {
          'ok': true,
          'message': 'Cart cleared',
          'cart': {'items': [], 'item_count': 0, 'render': {}},
          'undo': {
            'has': true,
            'snapshot_id': 'snap-7',
            'message': 'Cart cleared',
            'action_label': 'Undo',
            'seconds': 5,
            'item_count': 2,
          },
        };
      };
      final cart = CartModel.forTest();
      await cart.refresh();
      calls.clear();

      final undo = await cart.clear();
      expect(calls, contains('cart_clear'));
      expect(undo['snapshot_id'], 'snap-7');
      expect(undo['message'], 'Cart cleared');
      expect(undo['action_label'], 'Undo');
      expect(undo['seconds'], 5,
          reason: 'how long the offer stands is the backend\'s number');
      expect(cart.lines, isEmpty);
    });

    test('nothing to undo returns an EMPTY block, so no Undo is offered',
        () async {
      CartModel.rpcTransport = (fn, p) async {
        if (fn == 'cart_render') return _openPayload();
        return {
          'ok': true,
          'message': 'Cart cleared',
          'cart': {'items': [], 'item_count': 0, 'render': {}},
          'undo': {'has': false, 'snapshot_id': null},
        };
      };
      final cart = CartModel.forTest();
      await cart.refresh();
      expect(await cart.clear(), isEmpty);
    });
  });

  // ── 4 ──────────────────────────────────────────────────────────────────────
  group('Undo restores from the backend, and says so in its words', () {
    test('every line and quantity comes back from the returned cart', () async {
      final calls = <(String, Map<String, dynamic>?)>[];
      CartModel.rpcTransport = (fn, p) async {
        calls.add((fn, p));
        if (fn == 'cart_render') return _openPayload();
        if (fn == 'cart_clear') {
          return {
            'ok': true,
            'cart': {'items': [], 'item_count': 0, 'render': {}},
            'undo': {
              'has': true,
              'snapshot_id': 'snap-7',
              'message': 'Cart cleared',
              'action_label': 'Undo',
              'seconds': 5,
            },
          };
        }
        return {
          'ok': true,
          'message': 'Cart restored',
          'restored': 2,
          'cart': _openPayload(),
        };
      };
      final cart = CartModel.forTest();
      await cart.refresh();
      final undo = await cart.clear();
      expect(cart.lines, isEmpty);
      calls.clear();

      final msg = await cart.undoClear(undo['snapshot_id'].toString());

      expect(calls.map((c) => c.$1), ['cart_clear_undo'],
          reason: 'the answer IS the cart — nothing is re-read after it');
      expect(calls.single.$2?['p_snapshot_id'], 'snap-7');
      expect(msg, 'Cart restored');
      expect(cart.lines.length, 2);
      expect(cart.quantityOf('202'), 2, reason: 'the quantity comes back too');
    });

    test('a closed window shows the backend\'s refusal, verbatim', () async {
      CartModel.rpcTransport = (fn, p) async {
        if (fn == 'cart_render') return _openPayload();
        return {
          'ok': false,
          'message': 'That cart can no longer be restored',
          'cart': {'items': [], 'item_count': 0, 'render': {}},
        };
      };
      final cart = CartModel.forTest();
      await cart.refresh();
      expect(await cart.undoClear('snap-gone'),
          'That cart can no longer be restored');
    });
  });

  // ── 5 ──────────────────────────────────────────────────────────────────────
  group('the stepper prints the tap, not the stale server string', () {
    testWidgets('a local tap outstanding is what silences qty_text',
        (tester) async {
      var replies = 0;
      CartModel.rpcTransport = (fn, p) async {
        if (fn == 'cart_render') return _openPayload();
        replies++;
        return {
          'ok': true,
          'product_id': '101',
          'item': _item(qty: (p?['p_quantity'] as num).toInt()),
          'summary': {'bottom': _bottom(itemsValue: '2')},
        };
      };
      final cart = CartModel.forTest();
      await cart.refresh();

      expect(cart.hasLocalIntent('101'), isFalse,
          reason: 'with nothing outstanding the server string is the truth');

      cart.incrementId('101');
      expect(cart.quantityOf('101'), 2);
      expect(cart.hasLocalIntent('101'), isTrue,
          reason: 'qty_text still reads 1 here — the screen must not print it');

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(replies, 1);
      expect(cart.hasLocalIntent('101'), isFalse,
          reason: 'acknowledged — the payload says the same thing now');
      expect(cart.quantityOf('101'), 2);
    });
  });
}
