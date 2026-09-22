// CMD #2160 — Product card v6, held down (protected).
//
//   * the plate is SQUARE (the card's own width) wherever the card is no
//     wider than plateMaxV6, and the extent the grids reserve is unchanged;
//   * the photo box is image_pct of the plate — contained, never cropped;
//   * the action spot is 36 tall: +, the qty pill (qty_tpl_one at 1,
//     qty_tpl_many above), and the red Notify me → We'll notify pill;
//   * out of stock, the pack chip reads the backend's "Unavailable";
//   * the scheme badge is the backend's short "10+1", 26 tall = chip height;
//   * the text block is 3 fixed lines and the price row never moves;
//   * the MRP is struck with the slanted line, not line-through;
//   * a v5 payload without `v6` keeps the v5 card.
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
  bool v6 = true,
  bool scheme = false,
  bool unavailable = false,
  bool notified = false,
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
      'notified': notified,
      'idle_line': 'Unavailable right now',
      'done_line': 'Unavailable right now',
    },
    'picker': {'rpc': 'card_qty_picker', 'pack_type': 'Strip'},
    'qty_tpl': '{qty} strip',
    'qty_tpl_one': '{qty} strip',
    'qty_tpl_many': '{qty} strips',
    'qty_label': '',
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
  if (v6) 'v6': {
    'image_pct': 92,
    'scheme': {'has': scheme, 'label': scheme ? '10+1' : '', 'bg': '#FEF3C7', 'fg': '#92400E'},
    'unavail_chip': {'has': unavailable, 'label': unavailable ? 'Unavailable' : '', 'bg': '#FEE2E2', 'fg': '#991B1B'},
    'notify_pill': {'bg': '#DC2626', 'fg': '#FFFFFF'},
  },
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

Future<CartModel> _pumpW(WidgetTester tester, Map<String, dynamic> row, double w) async {
  final cart = CartModel.forTest();
  await tester.pumpWidget(
    AppState(
      cart: cart,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: w,
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

  test('CardV6 reads only when the payload carries v6', () {
    expect(CardV5.of(_card())!.v6, isNotNull);
    expect(CardV5.of(_card(v6: false))!.v6, isNull);
    expect(CardV5.of(_card())!.v6!.imagePct, 92);
  });

  test('the qty pill picks qty_tpl_one at 1 and qty_tpl_many above', () {
    final a = CardAction.of(_card())!;
    expect(a.pillLabelV6(1), '1 strip');
    expect(a.pillLabelV6(4), '4 strips');
  });

  test('the v6 body fits the one extent every grid reserves', () {
    expect(CompactProductCard.textV6, 52);
    expect(CompactProductCard.plateMaxV6,
        CompactProductCard.extent - 2 - CompactProductCard.bodyV6);
    expect(CompactProductCard.actionV6, 36);
    expect(CompactProductCard.chipV6, 26);
  });

  testWidgets('the plate is square at the card width', (tester) async {
    await _pump(tester, _row(_card()));
    final plate = tester.getSize(find.byType(Opacity).first);
    expect(plate.height, plate.width, reason: 'square below plateMaxV6');
    final card = tester.getSize(find.byType(CompactProductCard));
    expect(card.height, CompactProductCard.extent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the + is a 36 circle', (tester) async {
    await _pump(tester, _row(_card()));
    final plus = find.descendant(
      of: find.byKey(const ValueKey('card-plus')),
      matching: find.byType(SizedBox),
    );
    expect(tester.getSize(plus.first).height, 36);
  });

  testWidgets('in the cart the pill is 36 tall and pluralised', (tester) async {
    final cart = await _pump(tester, _row(_card()));
    cart.setQuantityId('274472', 4);
    await tester.pumpAndSettle();
    expect(find.text('4 strips'), findsOneWidget);
    final pill = find.byKey(const ValueKey('card-qty-pill'));
    expect(tester.getSize(pill).height, 36);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('out of stock: Unavailable chip, dimmed photo, red Notify me',
      (tester) async {
    await _pump(tester, _row(_card(unavailable: true), canAdd: false));
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('Strip of 10'), findsNothing,
        reason: 'the Unavailable chip replaces the pack chip');
    expect(find.text('Notify me'), findsOneWidget);
    final op = tester.widget<Opacity>(find.byType(Opacity).first);
    expect(op.opacity, 0.45);
    final m = tester.widget<Material>(find.ancestor(
      of: find.byKey(const ValueKey('card-notify')),
      matching: find.byType(Material),
    ).first);
    expect(m.color, const Color(0xFFDC2626));
    expect(tester.getSize(find.byKey(const ValueKey('card-notify'))).height, 36);
  });

  testWidgets('notified keeps the same red and reads We\'ll notify',
      (tester) async {
    await _pump(
        tester, _row(_card(unavailable: true, notified: true), canAdd: false));
    expect(find.text("We'll notify"), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    final m = tester.widget<Material>(find.ancestor(
      of: find.byKey(const ValueKey('card-notify')),
      matching: find.byType(Material),
    ).first);
    expect(m.color, const Color(0xFFDC2626));
  });

  testWidgets('the scheme badge is the backend short label, 26 tall',
      (tester) async {
    await _pump(tester, _row(_card(scheme: true)));
    expect(find.text('10+1'), findsOneWidget);
    final badge = find.bySemanticsIdentifier('card_scheme_badge');
    expect(tester.getSize(badge).height, 26);
    final chip = find.bySemanticsIdentifier('card_pack_chip');
    expect(tester.getSize(chip).height, 26);
  });

  testWidgets('no scheme, no badge', (tester) async {
    await _pump(tester, _row(_card()));
    expect(find.bySemanticsIdentifier('card_scheme_badge'), findsNothing);
  });

  testWidgets('the MRP carries the slanted strike, not line-through',
      (tester) async {
    await _pump(tester, _row(_card()));
    expect(find.bySemanticsIdentifier('card_mrp_slant'), findsOneWidget);
    final mrp = tester.widget<Text>(find.text('₹122.06'));
    expect(mrp.style?.decoration, isNot(TextDecoration.lineThrough));
  });

  testWidgets('the price row sits at one height whatever the name length',
      (tester) async {
    await _pump(tester, _row(_card(name: 'Crocin')));
    final short = tester.getTopLeft(find.text('₹122.06')).dy;
    await _pump(tester,
        _row(_card(name: 'Voglimac MF 0.3 Forte Tablet Extended Release SR')));
    final long = tester.getTopLeft(find.text('₹122.06')).dy;
    expect(long, short);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a 2-line name leaves the composition one line', (tester) async {
    await _pump(tester,
        _row(_card(name: 'Voglimac MF 0.3 Forte Tablet Extended Release SR')));
    final sub = tester.widget<Text>(find.textContaining('Gliclazide'));
    expect(sub.maxLines, 1);
  });

  testWidgets('a v5 payload without v6 keeps the v5 card', (tester) async {
    await _pump(tester, _row(_card(v6: false)));
    expect(find.bySemanticsIdentifier('card_mrp_slant'), findsNothing);
    expect(find.text('Strip of 10'), findsOneWidget);
  });

  for (final w in const [150.0, 162.0, 184.0, 220.0]) {
    testWidgets('no overflow at card width $w', (tester) async {
      await _pumpW(tester, _row(_card(scheme: true)), w);
      expect(tester.takeException(), isNull);
      final plate = tester.getSize(find.byType(Opacity).first);
      expect(plate.height, lessThanOrEqualTo(CompactProductCard.plateMaxV6));
      if (w - 2 <= CompactProductCard.plateMaxV6) {
        expect(plate.height, plate.width);
      }
    });
  }
}
