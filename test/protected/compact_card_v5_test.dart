// PROTECTED — CMD #2146, Product card v5.
//
// Holds down the v5 card, which is the ONE shared card on Home rails,
// Catalogue, Search, Wishlist and Cart "You may also like":
//   * pack_chip.label is the top-left chip; has:false draws no chip.
//   * sub_line.label sits under the name; name + sub line share
//     layout.text_lines (1-line name → 2 sub lines, 2-line name → 1).
//   * image.placeholder:true draws the pack-type icon, never a photo box.
//   * rx is never drawn; the heart sits top-right.
//   * the MRP is struck when price.mrp_struck says so, in price.mrp_fg.
//   * foot.has:false → nothing under the price row.
//   * in the cart the control is the qty chip ("2 strip") that reopens the
//     sheet; out of stock it is the backend's "Notify me".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/models/product_card_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/card_pack_icon.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';

Map<String, dynamic> _card({
  bool packChip = true,
  bool subLine = true,
  bool placeholder = true,
  bool footHas = false,
  bool wish = true,
  String name = 'Gally M 40mg/500mg Tablet',
}) => {
  'v': 1,
  'id': 274472,
  'name': name,
  'rx': {'has': false, 'is_rx': true, 'label': 'Rx'},
  'wish': {
    'has': wish,
    'saved': false,
    'add_label': 'Save',
    'remove_label': 'Saved',
  },
  'image': {'url': '', 'placeholder': placeholder, 'placeholder_letter': 'G'},
  'offer': {'has': false, 'label': ''},
  'price': {
    'has_mrp': true,
    'mrp_display': '₹122.06',
    'strike_mrp': false,
    'price_display': 'PTR',
    'price_locked': true,
    'mrp_struck': true,
    'mrp_fg': '#111827',
  },
  'style': {
    'border': '#E3E6EB',
    'mrp_fg': '#111827',
    'sub_fg': '#111827',
    'name_fg': '#111827',
    'text_bg': '#FAFBFC',
    'photo_bg': '#FFFFFF',
  },
  'action': {
    'notify': {
      'rpc': 'stock_notify_request',
      'label': 'Notify me',
      'done_label': "We'll notify",
      'notified': false,
      'idle_line': 'Unavailable right now',
      'done_line': 'Unavailable right now',
    },
    'picker': {'rpc': 'card_qty_picker', 'pack_type': 'Strip'},
    'qty_tpl': '{qty} strip',
    'qty_foot_tpl': '',
  },
  'layout': {'text_lines': 3, 'name_max_lines': 2},
  'foot': {'has': footHas, 'label': footHas ? 'Earn 18%' : ''},
  'foot_idle': {'has': false, 'label': ''},
  'pack_chip': {'has': packChip, 'label': packChip ? 'Strip of 10' : ''},
  'sub_line': {
    'has': subLine,
    'kind': 'composition',
    'label': subLine ? 'Gliclazide (40mg) + Metformin (500mg)' : '',
    'fg': '#111827',
  },
  'placeholder': {'kind': 'strip'},
  'qty_in_cart': 0,
  'notified': false,
};

Map<String, dynamic> _row(Map<String, dynamic> card, {bool canAdd = true}) => {
  'id': 274472,
  'product_name': card['name'],
  'marketer': 'NOVALAB HEALTHCARE PVT LTD',
  'image_url_1': '',
  'wish': card['wish'],
  'availability': {
    'is_available': canAdd,
    'can_add': canAdd,
    'cta_label': canAdd ? 'Add to cart' : 'Unavailable',
    'cta_short': canAdd ? 'ADD' : 'Notify',
    'gated': true,
  },
  'card': card,
};

Future<CartModel> _pump(WidgetTester tester, Map<String, dynamic> row) async {
  final cart = CartModel.forTest();
  await tester.pumpWidget(
    AppState(
      cart: cart,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 170,
              height: CompactProductCard.extent,
              child: CompactProductCard(
                product: Product.fromMap(row),
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return cart;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  setUp(() {
    CartModel.rpcTransport = (fn, params) async => {
      'ok': true,
      'message': '',
      'cart': <String, dynamic>{},
    };
  });
  tearDown(() => CartModel.rpcTransport = null);

  test('CardV5 reads only when the payload carries style', () {
    expect(CardV5.of(_card()), isNotNull);
    final old = Map<String, dynamic>.from(_card())..remove('style');
    expect(CardV5.of(old), isNull, reason: 'an older payload keeps its card');
  });

  test('name + sub line share layout.text_lines', () {
    final v = CardV5.of(_card())!;
    expect(v.subLinesFor(1), 2);
    expect(v.subLinesFor(2), 1);
    expect(v.subLinesFor(3), 0);
  });

  testWidgets('pack chip, sub line and the no-photo pack icon are verbatim',
      (tester) async {
    await _pump(tester, _row(_card()));
    expect(find.text('Strip of 10'), findsOneWidget);
    expect(find.text('Gliclazide (40mg) + Metformin (500mg)'), findsOneWidget);
    expect(find.byType(CardPackIcon), findsOneWidget);
    expect(find.text('Rx'), findsNothing, reason: 'no Rx / OTC on the card');
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('has:false draws no chip and no sub line', (tester) async {
    await _pump(tester, _row(_card(packChip: false, subLine: false)));
    expect(find.text('Strip of 10'), findsNothing);
    expect(find.textContaining('Gliclazide'), findsNothing);
  });

  testWidgets('the heart sits top-right of the plate', (tester) async {
    await _pump(tester, _row(_card()));
    final card = tester.getRect(find.byType(CompactProductCard));
    final heart = tester.getCenter(find.byIcon(Icons.favorite_border));
    expect(heart.dx, greaterThan(card.center.dx));
    expect(heart.dy, lessThan(card.top + CompactProductCard.wishTapSize));
  });

  testWidgets('the MRP is struck in mrp_fg and nothing sits under the price',
      (tester) async {
    await _pump(tester, _row(_card()));
    final mrp = tester.widget<Text>(find.text('₹122.06'));
    expect(mrp.style?.decoration, TextDecoration.lineThrough);
    expect(mrp.style?.color, const Color(0xFF111827));
    expect(find.text('Unavailable right now'), findsNothing);
  });

  testWidgets('foot.has:true prints the backend line', (tester) async {
    await _pump(tester, _row(_card(footHas: true)));
    expect(find.text('Earn 18%'), findsOneWidget);
  });

  testWidgets('in the cart the + becomes the qty chip', (tester) async {
    final cart = await _pump(tester, _row(_card()));
    expect(find.bySemanticsIdentifier('card_plus'), findsOneWidget);
    cart.setQuantityId('274472', 2);
    await tester.pumpAndSettle();
    expect(find.text('2 strip'), findsOneWidget);
    expect(find.byKey(const ValueKey('card-qty-pill')), findsOneWidget);
    // Let the cart's own write debounce run out before the tree is torn down.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('out of stock offers the backend\'s Notify me', (tester) async {
    await _pump(tester, _row(_card(), canAdd: false));
    expect(find.text('Notify me'), findsOneWidget);
    expect(find.bySemanticsIdentifier('card_plus'), findsNothing);
  });
}
