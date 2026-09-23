// PROTECTED — CMD #2169.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the wishlist heart, never to make an unrelated change
// go green.
//
// What this holds down:
//
//   1. THE HEART IS A HEART. There is no white disc under it, no shadow, no
//      border and no background of any kind. The circle was the thing #2169
//      removed, and the only way a circle comes back unnoticed is if nothing
//      is watching for it — so this file watches the heart's whole subtree for
//      a decoration that paints.
//
//   2. EVERY NUMBER AND EVERY COLOUR IS THE PAYLOAD'S. The glyph's size is
//      `card_layout().wish_icon`, the invisible box that catches the finger is
//      `wish_tap`, the outline is `card_style().wish_fg` and the filled heart
//      is `wish_saved_fg`. The fixture below deliberately sends numbers and
//      colours that are NOT the defaults: a card that renders 24dp grey when
//      the payload said 22dp blue is rendering Dart, not the backend.
//
//   3. THE FALLBACK IS THE BACKEND'S OWN DEFAULT. A payload that predates
//      #2169 still draws a 24dp heart in a 44dp box — the same two numbers
//      `card_layout()` sends — so an old cached card never draws a 16dp heart.
//
//   4. THE TAP TARGET STAYS AT 44dp OR MORE. The mock's box is 40; the box is
//      invisible either way and the phone-viewport rule wins.
//
//   5. SAVED IS THE SERVER'S ANSWER. The heart flips when `wishlist_toggle`
//      says it flipped, and it flips to the backend's saved colour. A refused
//      toggle leaves the outline exactly where it was.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/models/storefront_p3.dart' show WishlistResult;
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/card_layout.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';

/// Deliberately not the defaults: 22 / 46 / blue / green.
const double _icon = 22;
const double _tap = 46;
const String _fg = '#4B5563';
const String _savedFg = '#E53935';

Map<String, dynamic> _row({
  bool saved = false,
  bool wish = true,
  bool sendWishNumbers = true,
  double icon = _icon,
  double tap = _tap,
  String fg = _fg,
  String savedFg = _savedFg,
}) => {
  'id': 176026,
  'product_name': 'Alkacel 100mg Injection',
  'marketer': 'CELON LABORATORIES LTD',
  'pack_qty_label': '1.0 Injection in 1 vial',
  'pack_type_label': 'Vial',
  'image_url_1': '',
  'mrp': '2597',
  'availability': {
    'is_available': true,
    'can_add': true,
    'cta_label': 'Add to cart',
    'cta_short': 'ADD',
    'gated': true,
  },
  'pricing': {
    'has_price': true,
    'card_price': {
      'has_mrp': true,
      'mrp_label': 'MRP',
      'mrp_display': '₹2,597.00',
      'strike_mrp': true,
      'has_ptr': true,
      'ptr_label': 'PTR',
      'ptr_display': '₹2,337.30',
      'price_display': '₹2,337.30',
      'price_locked': false,
      'sale_label': 'Sale price:',
      'has_note': false,
      'note': '',
    },
  },
  // `card_wish()` — the block the heart is drawn from. Nothing about the
  // wishlist is decided here: `has` is whether this viewer is offered one at
  // all, `saved` is whether this pack is in it, and both words are the
  // backend's.
  'wish': {
    'has': wish,
    'saved': saved,
    'add_label': 'Save for later',
    'remove_label': 'Saved',
  },
  // A v5 payload (style, no v6): the legacy plate, with the resolved
  // CardLayout still coming out of this block.
  'card': {
    'style': {
      'photo_bg': '#FFFFFF',
      'text_bg': '#FAFBFC',
      'border': '#E3E6EB',
      if (sendWishNumbers) 'wish_fg': fg,
      if (sendWishNumbers) 'wish_saved_fg': savedFg,
    },
    'layout': {
      if (sendWishNumbers) 'wish_icon': icon,
      if (sendWishNumbers) 'wish_tap': tap,
    },
  },
};

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> row, {
  Future<WishlistResult> Function(String id)? toggle,
  String screen = '',
}) async {
  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: CardSurface(
            screen: screen,
            child: SizedBox(
              width: 200,
              height: CompactProductCard.extent,
              child: CompactProductCard(
                product: Product.fromMap(row),
                onTap: () {},
                wishlistToggle: toggle,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Icon _heart(WidgetTester tester) => tester.widget<Icon>(
  find.byWidgetPredicate(
    (w) =>
        w is Icon &&
        (w.icon == Icons.favorite || w.icon == Icons.favorite_border),
  ),
);

final Finder _heartIcon = find.byWidgetPredicate(
  (w) =>
      w is Icon &&
      (w.icon == Icons.favorite || w.icon == Icons.favorite_border),
);

/// The heart's own tap box — the nearest SizedBox above the glyph.
Finder get _tapBox =>
    find.ancestor(of: _heartIcon, matching: find.byType(SizedBox)).first;

/// Every decoration painted INSIDE the heart's tap box. The card's own plate
/// sits outside it and is none of this test's business.
List<Decoration> _decorationsAroundHeart(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.descendant(of: _tapBox, matching: find.byType(DecoratedBox)),
    )
    .map((d) => d.decoration)
    .toList();

void main() {
  setUpAll(() {
    // The 800 ms debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  group('CMD #2169 — the wishlist heart is a heart and nothing else', () {
    testWidgets('no circle: nothing between the tap box and the glyph paints '
        'a fill, a border or a shadow', (tester) async {
      await _pump(tester, _row(), screen: 'wish_nocircle');

      // Nothing may paint inside the box at all — but if a later change adds
      // something, it may still not be a disc, a fill, a shadow or a border.
      expect(_decorationsAroundHeart(tester), isEmpty);
      for (final d in _decorationsAroundHeart(tester)) {
        if (d is BoxDecoration) {
          expect(
            d.shape,
            isNot(BoxShape.circle),
            reason: 'the white disc under the heart is gone',
          );
          expect(d.color, isNull, reason: 'the heart has no background');
          expect(
            d.boxShadow,
            anyOf(isNull, isEmpty),
            reason: 'the heart casts no shadow',
          );
          expect(d.border, isNull, reason: 'the heart has no border');
        }
      }
    });

    testWidgets('the glyph size and the tap box are the payload\'s numbers', (
      tester,
    ) async {
      await _pump(tester, _row(), screen: 'wish_numbers');

      expect(_heart(tester).size, _icon);

      final box = tester.getSize(
        find
            .ancestor(
              of: find.byWidgetPredicate(
                (w) => w is Icon && w.icon == Icons.favorite_border,
              ),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(box.width, _tap);
      expect(box.height, _tap);
    });

    testWidgets(
      'unsaved is wish_fg and saved is wish_saved_fg, both verbatim',
      (tester) async {
        await _pump(tester, _row(), screen: 'wish_fg');
        expect(_heart(tester).icon, Icons.favorite_border);
        expect(_heart(tester).color, const Color(0xFF4B5563));

        await _pump(tester, _row(saved: true), screen: 'wish_fg');
        expect(_heart(tester).icon, Icons.favorite);
        expect(_heart(tester).color, const Color(0xFFE53935));
      },
    );

    testWidgets('a payload that sends different numbers gets them', (
      tester,
    ) async {
      await _pump(
        tester,
        _row(icon: 18, tap: 52, fg: '#123456', savedFg: '#654321'),
        screen: 'wish_other',
      );
      expect(_heart(tester).size, 18);
      expect(_heart(tester).color, const Color(0xFF123456));

      await _pump(
        tester,
        _row(saved: true, icon: 18, tap: 52, fg: '#123456', savedFg: '#654321'),
        screen: 'wish_other',
      );
      expect(_heart(tester).color, const Color(0xFF654321));
    });

    testWidgets(
      'a pre-#2169 payload still draws the backend default, 24 in 44',
      (tester) async {
        await _pump(tester, _row(sendWishNumbers: false), screen: 'wish_old');
        expect(_heart(tester).size, 24);

        final box = tester.getSize(
          find
              .ancestor(
                of: find.byWidgetPredicate(
                  (w) => w is Icon && w.icon == Icons.favorite_border,
                ),
                matching: find.byType(SizedBox),
              )
              .first,
        );
        expect(box.width, 44);
      },
    );

    testWidgets('the tap goes to wishlist_toggle, and the SERVER\'s answer is '
        'what flips the heart', (tester) async {
      var calls = 0;
      await _pump(
        tester,
        _row(),
        toggle: (id) async {
          calls++;
          return const WishlistResult(
            ok: true,
            isWishlisted: true,
            toast: 'Saved for later',
            error: '',
          );
        },
        screen: 'wish_toggle',
      );

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.favorite_border,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(calls, 1);
      expect(_heart(tester).icon, Icons.favorite);
      expect(_heart(tester).color, const Color(0xFFE53935));

      // The backend's toast, printed verbatim — and pumped out so its own
      // 4-second timer does not outlive the test.
      expect(find.text('Saved for later'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('a refused toggle leaves the outline exactly where it was', (
      tester,
    ) async {
      await _pump(
        tester,
        _row(),
        toggle: (id) async => WishlistResult.failed,
        screen: 'wish_refused',
      );

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.favorite_border,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(_heart(tester).icon, Icons.favorite_border);
      expect(_heart(tester).color, const Color(0xFF4B5563));
    });

    testWidgets('wish.has false draws no heart at all', (tester) async {
      await _pump(tester, _row(wish: false), screen: 'wish_off');
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              (w.icon == Icons.favorite || w.icon == Icons.favorite_border),
        ),
        findsNothing,
      );
    });

    test('the resolved layout carries the backend\'s two heart numbers', () {
      final cl = CardLayout.of({
        'layout': {'wish_icon': 22, 'wish_tap': 46},
        'style': {'wish_fg': '#4B5563', 'wish_saved_fg': '#E53935'},
      }, screen: 'wish_pure');
      expect(cl.wishIcon, 22);
      expect(cl.wishTap, 46);
      expect(
        cl.color('wish_fg', const Color(0xFF000000)),
        const Color(0xFF4B5563),
      );
      expect(
        cl.color('wish_saved_fg', const Color(0xFF000000)),
        const Color(0xFFE53935),
      );
    });

    test('the default tap box is a real 44dp target, never the mock\'s 40', () {
      expect(CardLayout.fallback.wishTap, greaterThanOrEqualTo(44.0));
      expect(CardLayout.fallback.wishIcon, 24);
      expect(CompactProductCard.wishTapSize, greaterThanOrEqualTo(44.0));
    });
  });
}
