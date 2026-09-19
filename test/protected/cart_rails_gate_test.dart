// PROTECTED — CMD #2087.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes cart rail / place-order-gate behaviour.
//
// What this holds down:
//
//   1. THE PLACE ORDER TAP IS ONE BACKEND ANSWER. cart_place_gate() replies
//      with an ACTION, and the screen never reads `state` to decide anything:
//      'order' places, 'popup' prints the backend's three strings verbatim,
//      'route' opens the route AND the anchor the backend named. An action
//      this build has never heard of — and a 'route' with no route on it —
//      does nothing, rather than falling through into placing an order.
//
//   2. THE POPUP IS THE BACKEND'S WORDS. "Your account is not approved yet …"
//      is never composed, prefixed or pluralised in Dart, and neither is the
//      dismiss label.
//
//   3. THE QUANTITY ROLLS ONCE PER TAP. The local echo animates; the server's
//      reply to that tap is applied SILENTLY — that is the whole flicker fix.
//      The same number arriving re-worded (qty_text landing, or changing) is
//      not a change the customer made either.
//
//   4. A RAIL IS A CONSTANT HEIGHT. CartWishlistRail.extent is summed from the
//      card's own extent and the rail's named gaps, and CartRailSlot reserves
//      exactly that — so a rail with three cards and one with ten occupy the
//      same band and nothing under them moves.
//
//   5. THE RAIL IS THE PAYLOAD. `has:false`, an empty items list and a missing
//      block all draw NOTHING; a rail draws the backend's title and the number
//      of cards it was sent, in payload order.
//
//   6. THE CART ROWS SLOT IS A FUNCTION OF THE VIEWPORT, NOT OF THE BASKET.
//      The same screen gives the same slot height whatever is in the cart,
//      which is why adding or removing a line cannot move the rails.
//
// SCOPE NOTE: CartScreen needs five inherited states and a live Supabase client
// to mount, so per CLAUDE.md this file asserts the DECISIONS (the parsed gate,
// the animation rule, the reserved extents) rather than pumping the screen.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/screens/cart_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/cart_rail_slot.dart';
import 'package:pharma_b2b/widgets/cart_wishlist_rail.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';

Map<String, dynamic> _railPayload({
  required bool has,
  String title = 'You may also like',
  int count = 0,
}) =>
    <String, dynamic>{
      'has': has,
      'title': title,
      'empty_note': 'Nothing to suggest for this basket yet',
      'items': <Map<String, dynamic>>[
        for (var i = 0; i < count; i++)
          <String, dynamic>{
            'id': 900 + i,
            'name': 'CARD $i',
            'company': 'TEST LABS LTD',
            'pack_label': '10 tablets',
            'form_chip': 'Strip',
            'image': '',
            'pricing': <String, dynamic>{},
            'availability': <String, dynamic>{},
          },
      ],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('1 — the Place order tap is ONE backend answer', () {
    test('approved → the gate places the order and opens nothing', () {
      final g = C2087PlaceGate.from(const {
        'ok': true,
        'state': 'approved',
        'action': 'order',
        'route': '',
        'anchor': '',
        'popup': {'has': false},
      });
      expect(g.placesOrder, isTrue);
      expect(g.showsPopup, isFalse);
      expect(g.opensRoute, isFalse);
      expect(g.isUnknown, isFalse);
      expect(g.logLine, 'approved/order');
    });

    test('submitted, not approved → a popup, and NOT an order', () {
      final g = C2087PlaceGate.from(const {
        'state': 'submitted',
        'action': 'popup',
        'route': '',
        'anchor': '',
        'popup': {
          'has': true,
          'title': 'Account under verification',
          'body':
              'Your account is not approved yet — we are verifying your details',
          'dismiss': 'OK',
        },
      });
      expect(g.showsPopup, isTrue);
      expect(g.placesOrder, isFalse);
      // 2 — verbatim, every one of the three.
      expect(g.popupTitle, 'Account under verification');
      expect(g.popupBody,
          'Your account is not approved yet — we are verifying your details');
      expect(g.popupDismiss, 'OK');
    });

    test('incomplete → the backend\'s route AND its anchor', () {
      final g = C2087PlaceGate.from(const {
        'state': 'incomplete',
        'action': 'route',
        'route': '/complete-registration',
        'anchor': 'documents',
        'cta': 'Complete registration',
        'popup': {'has': false},
      });
      expect(g.opensRoute, isTrue);
      expect(g.route, '/complete-registration');
      expect(g.anchor, 'documents');
      expect(g.placesOrder, isFalse);
    });

    test('not registered → the same route, no anchor', () {
      final g = C2087PlaceGate.from(const {
        'state': 'not_registered',
        'action': 'route',
        'route': '/complete-registration',
        'anchor': '',
        'popup': {'has': false},
      });
      expect(g.opensRoute, isTrue);
      expect(g.anchor, isEmpty);
    });

    test('logged out → Login, from the backend', () {
      final g = C2087PlaceGate.from(const {
        'state': 'logged_out',
        'action': 'route',
        'route': '/login',
        'anchor': '',
        'popup': {'has': false},
      });
      expect(g.opensRoute, isTrue);
      expect(g.route, '/login');
      expect(g.logLine, 'logged_out/route');
    });

    test('an unknown action, and a route with nothing on it, place NOTHING',
        () {
      final unknown = C2087PlaceGate.from(const {
        'state': 'something_new',
        'action': 'call_the_shop',
        'popup': {'has': false},
      });
      expect(unknown.isUnknown, isTrue);
      expect(unknown.placesOrder, isFalse);
      expect(unknown.opensRoute, isFalse);

      final emptyRoute = C2087PlaceGate.from(const {
        'state': 'incomplete',
        'action': 'route',
        'route': '',
        'popup': {'has': false},
      });
      expect(emptyRoute.opensRoute, isFalse);
      expect(emptyRoute.placesOrder, isFalse);

      // An unreachable gate is not an approval either.
      expect(C2087PlaceGate.unreachable.placesOrder, isFalse);
      expect(C2087PlaceGate.unreachable.opensRoute, isFalse);
    });
  });

  group('3 — one tap, one roll', () {
    test('the local echo of a tap ANIMATES', () {
      expect(
        c2087StepperSilent(
          wasLocal: false,
          isLocal: true,
          oldQty: 2,
          newQty: 3,
          oldText: '2',
          newText: '',
        ),
        isFalse,
      );
    });

    test('the server answering that tap is applied SILENTLY', () {
      // The echo goes off and qty_text (the backend's wording of the SAME
      // number) arrives. This is the second animation that used to flicker.
      expect(
        c2087StepperSilent(
          wasLocal: true,
          isLocal: false,
          oldQty: 3,
          newQty: 3,
          oldText: '',
          newText: '3',
        ),
        isTrue,
      );
    });

    test('a server value that CLAMPS the tap also lands silently', () {
      expect(
        c2087StepperSilent(
          wasLocal: true,
          isLocal: false,
          oldQty: 9,
          newQty: 5,
          oldText: '',
          newText: '5',
        ),
        isTrue,
      );
    });

    test('the same number re-worded never rolls', () {
      expect(
        c2087StepperSilent(
          wasLocal: false,
          isLocal: false,
          oldQty: 4,
          newQty: 4,
          oldText: '4',
          newText: '4 Strip',
        ),
        isTrue,
      );
    });

    test('a fresh change with no echo involved still rolls', () {
      expect(
        c2087StepperSilent(
          wasLocal: false,
          isLocal: false,
          oldQty: 4,
          newQty: 5,
          oldText: '4',
          newText: '5',
        ),
        isFalse,
      );
    });
  });

  group('4/5 — the rails', () {
    test('a rail reserves a CONSTANT height, summed from the card', () {
      expect(CartRailSlot.railExtent, CartWishlistRail.extent);
      expect(CartWishlistRail.extent,
          greaterThan(CompactProductCard.extent));
      // The band is the card plus the rail's own gaps — nothing else.
      expect(CartWishlistRail.extent - CompactProductCard.extent, 60);
    });

    test('has:false, no items and a missing block all draw NOTHING', () {
      void open(_) {}
      expect(CartWishlistRail.fromPayload(_railPayload(has: false, count: 4),
              open),
          isNull);
      expect(CartWishlistRail.fromPayload(_railPayload(has: true, count: 0),
              open),
          isNull);
      expect(CartWishlistRail.fromPayload(const <String, dynamic>{}, open),
          isNull);
      expect(CartWishlistRail.fromPayload(null, open), isNull);
    });

    test('a rail prints the backend title and the cards it was sent', () {
      void open(_) {}
      final r = CartWishlistRail.fromPayload(
          _railPayload(has: true, title: 'You may also like', count: 3), open);
      expect(r, isNotNull);
      expect(r!.title, 'You may also like');
      expect(r.items.length, 3);
      // Payload order, not a client sort.
      expect(r.items.first.name, 'CARD 0');
      expect(r.items.last.name, 'CARD 2');
    });

    testWidgets('an empty slot draws nothing at all', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: CartRailSlot(rails: <CartWishlistRail?>[null, null]),
        ),
      ));
      // Nothing was sent, so nothing is drawn — not an empty band holding
      // 388px of whitespace open.
      final box = tester.getSize(find.byType(CartRailSlot));
      expect(box.height, 0);
    });
  });

  group('6 — the rows slot is the viewport, never the basket', () {
    test('the same screen always gives the same slot', () {
      final a = C2087CartBodyMetrics.rowsSlotFor(740);
      final b = C2087CartBodyMetrics.rowsSlotFor(740);
      expect(a, b);
    });

    test('it is clamped, so a tiny or huge viewport still behaves', () {
      expect(C2087CartBodyMetrics.rowsSlotFor(100),
          C2087CartBodyMetrics.rowsSlotMin);
      expect(C2087CartBodyMetrics.rowsSlotFor(5000),
          C2087CartBodyMetrics.rowsSlotMax);
    });

    test('a taller phone gives the rows more room, monotonically', () {
      expect(C2087CartBodyMetrics.rowsSlotFor(640),
          lessThan(C2087CartBodyMetrics.rowsSlotFor(880)));
    });
  });

  group('the payload carries the second rail', () {
    tearDown(() => CartModel.rpcTransport = null);

    test('cart_render().also_like reaches the model untouched', () async {
      CartModel.rpcTransport = (fn, params) async => <String, dynamic>{
            'items': <dynamic>[],
            'also_like': _railPayload(has: true, count: 2),
          };
      final cart = CartModel.forTest();
      await cart.refresh();
      expect(cart.alsoLikeBlock['has'], isTrue);
      expect(cart.alsoLikeBlock['title'], 'You may also like');
      expect((cart.alsoLikeBlock['items'] as List).length, 2);
    });

    test('an absent block is an absence, not a crash', () async {
      CartModel.rpcTransport =
          (fn, params) async => <String, dynamic>{'items': <dynamic>[]};
      final cart = CartModel.forTest();
      await cart.refresh();
      expect(cart.alsoLikeBlock, isEmpty);
    });
  });
}
