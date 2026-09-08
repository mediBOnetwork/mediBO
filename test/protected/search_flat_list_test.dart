// PROTECTED — CMD #1903. Search is a FLAT LIST of products, and the pack
// family lives on the product page.
//
// What this file holds down:
//
//   1. **One row per product, and the row prints the payload.** The 72pt
//      image, the name, the company, the pack line, the struck MRP, the sale
//      line and the ADD word are all strings that arrived on the card
//      payload. Nothing here formats money, decides a plural, or picks
//      between pack_qty / pack_size / pack_type.
//
//   2. **THE SALE LINE IS ONE FIELD.** `card_price.price_display` is either
//      the trade amount or the literal word "PTR", and the row prints
//      whichever came. There is no approval check in Dart. A withheld payload
//      carries no ptr number at all, so a row can never reveal one.
//
//   3. **ADD ⇄ stepper morphs off the cart's own quantity**, and the word is
//      `availability.cta_short` verbatim. `can_add:false` is the backend's
//      out-of-stock verdict — never a stock number compared here — and in
//      that state the row offers no enabled control.
//
//   4. **NO CHIPS IN A LIST.** The brand family is not on this widget in any
//      state: `ProductRowCard` has no variants parameter to give it one. The
//      family arrives only through `product_detail().other_packs`.
//
//   5. **The "Other packs" block is the backend's, and it lists the OTHER
//      packs.** Its title and every label are payload strings; the pack being
//      viewed is NOT in the list and nothing is marked selected (Om, live on
//      #1903); `has:false` when the pack has no siblings at all. It draws as
//      one sideways-scrolling row of identical outlined pills — never a stack
//      of full-width buttons.
//
// No network, no Supabase: fabricated payloads only.

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/models/product_detail.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/product_row_card.dart';

/// One storefront_search_page() item — the exact shape Product.fromMap reads.
Map<String, dynamic> _row({
  int id = 900101,
  String name = 'Monticope Tablet',
  bool canAdd = true,
  bool entitled = true,
}) =>
    {
      'id': id,
      'product_name': name,
      'marketer': 'MANKIND PHARMA LTD',
      'salt_composition': 'Levocetirizine (5mg) + Montelukast (10mg)',
      'therapeutic_class': 'RESPIRATORY',
      'pack_qty': '10 tablets',
      'pack_size': 'Strip of 10 tablets',
      'pack_type': 'Strip',
      // The two DECIDED labels. Deliberately unequal to the raw columns above:
      // a row that prints one of those instead of these fails.
      'pack_qty_label': '10.0 Tablets in 1 strip',
      'pack_type_label': 'Strip',
      'image_url_1': '',
      'mrp': '174.38',
      'availability': {
        'is_available': canAdd,
        'can_add': canAdd,
        'cta_label': 'Add to cart',
        'cta_short': 'ADD',
        'gated': true,
        if (!canAdd) 'note': 'No supplier for this product right now',
      },
      'pricing': {
        'has_price': true,
        'mrp': 174.38,
        'sale_price': 152.40,
        'price_display': '₹152.40',
        'mrp_display': '₹174.38',
        'card_price': {
          'has_mrp': true,
          'mrp_label': 'MRP',
          'mrp_display': '₹174.38',
          'strike_mrp': true,
          'has_ptr': entitled,
          if (entitled) 'ptr_label': 'PTR',
          if (entitled) 'ptr_display': '₹152.40',
          'price_display': entitled ? '₹152.40' : 'PTR',
          'price_locked': !entitled,
          if (!entitled) ...{
            'locked_title': 'Trade price',
            'locked_note': 'Register and get approved to see trade prices',
            'locked_cta': 'Register now',
            'locked_route': '/register',
          },
          'has_note': false,
          'note': '',
        },
      },
    };

Future<CartModel> _pumpRow(WidgetTester tester, Map<String, dynamic> row) async {
  final cart = CartModel.forTest();
  await tester.pumpWidget(
    AppState(
      cart: cart,
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: ProductRowCard.extent,
            child: ProductRowCard(
              product: Product.fromMap(row),
              onTap: () {},
            ),
          ),
        ),
      ),
    ),
  );
  return cart;
}

/// A list of rows, in the order the payload sent them — deliberately NOT
/// alphabetical, and deliberately with the out-of-stock exact match first,
/// which is the whole point of the backend's rank order.
Future<void> _pumpList(WidgetTester tester, List<Map<String, dynamic>> rows) async {
  final cart = CartModel.forTest();
  await tester.pumpWidget(
    AppState(
      cart: cart,
      child: MaterialApp(
        home: Scaffold(
          body: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) => ProductRowCard(
              product: Product.fromMap(rows[i]),
              onTap: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

// CMD #1903 (Om, live) — `items` is the OTHER packs. The pack being viewed is
// not one of them and nothing carries a `selected` key, so `has` is simply
// "there is at least one other pack".
Map<String, dynamic> _packs({int n = 3}) => {
      'has': n > 0,
      'title': 'Other packs',
      'items': [
        for (var i = 0; i < n; i++)
          {
            'product_id': 900101 + i,
            'label': const ['Tablet', 'A Tablet SR', 'Suspension'][i % 3],
          },
      ],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the search row prints the payload', () {
    testWidgets('name, company and BOTH decided pack labels, verbatim',
        (tester) async {
      await _pumpRow(tester, _row());
      expect(find.text('Monticope Tablet'), findsOneWidget);
      expect(find.text('MANKIND PHARMA LTD'), findsOneWidget);
      // The pack line joins the two decided labels — and neither raw column
      // ('10 tablets', 'Strip of 10 tablets') may appear anywhere.
      expect(find.text('Strip · 10.0 Tablets in 1 strip'), findsOneWidget);
      expect(find.text('Strip of 10 tablets'), findsNothing);
    });

    testWidgets('the MRP is the backend string, struck', (tester) async {
      await _pumpRow(tester, _row());
      final t = tester.widget<Text>(find.text('MRP ₹174.38'));
      expect(t.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('the sale line is ONE field — the amount when entitled',
        (tester) async {
      await _pumpRow(tester, _row());
      expect(find.text('₹152.40'), findsOneWidget);
      expect(find.text('PTR'), findsNothing);
    });

    testWidgets('withheld: the row prints the WORD and no number at all',
        (tester) async {
      await _pumpRow(tester, _row(entitled: false));
      expect(find.text('PTR'), findsOneWidget);
      expect(find.text('₹152.40'), findsNothing);
    });

    testWidgets('ADD is cta_short verbatim and morphs off the cart',
        (tester) async {
      final cart = await _pumpRow(tester, _row());
      expect(find.text('ADD'), findsOneWidget);

      await tester.tap(find.text('ADD'));
      // The swap is instant, so pumpAndSettle returns before the cart's own
      // send debounce (and the row's one-beat tick) have run. Pump past both
      // explicitly rather than leaning on an animation to hold the frame loop.
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();

      expect(cart.quantityOf('900101'), 1);
      expect(find.text('1'), findsOneWidget, reason: 'the stepper qty');
      expect(find.byIcon(Icons.remove_rounded), findsOneWidget);
      expect(find.text('ADD'), findsNothing,
          reason: 'ADD morphs in place — the two never show at once');
    });

    testWidgets('can_add:false offers no enabled control', (tester) async {
      await _pumpRow(tester, _row(canAdd: false));
      final inks = tester
          .widgetList<InkWell>(find.byType(InkWell))
          .where((w) => w.onTap != null)
          .length;
      // Only the row itself is tappable — the ADD control is not.
      expect(inks, lessThanOrEqualTo(1));
    });
  });

  group('a list is one row per product, in payload order', () {
    testWidgets('the backend order is rendered, never re-sorted here',
        (tester) async {
      await _pumpList(tester, [
        _row(id: 900101, name: 'Monticope Tablet', canAdd: false),
        _row(id: 900103, name: 'Monticope Suspension'),
        _row(id: 900102, name: 'Monticope-A Tablet SR'),
      ]);
      final names = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s.startsWith('Montic'))
          .toList();
      expect(names, [
        'Monticope Tablet',
        'Monticope Suspension',
        'Monticope-A Tablet SR',
      ]);
    });

    testWidgets('no chip row anywhere in a list — the widget cannot draw one',
        (tester) async {
      await _pumpList(tester, [
        _row(id: 900101),
        _row(id: 900103, name: 'Monticope Suspension'),
      ]);
      // The family's own labels are the ones that used to be chips. None of
      // them may appear on a list surface.
      expect(find.text('Tablet'), findsNothing);
      expect(find.text('Suspension'), findsNothing);
      expect(find.text('A Tablet SR'), findsNothing);
    });
  });

  group('other packs is the backend block', () {
    test('no other pack means no strip — one other pack is enough to draw it',
        () {
      expect(PdOtherPacks.fromMap({'has': false}).has, isFalse);
      expect(PdOtherPacks.fromMap(_packs(n: 0)).has, isFalse);
      expect(PdOtherPacks.fromMap(null).has, isFalse);
      // The old floor of two counted the pack being viewed. It is not in the
      // list any more, so a single sibling is a real row.
      expect(PdOtherPacks.fromMap(_packs(n: 1)).has, isTrue);
      expect(PdOtherPacks.fromMap(_packs(n: 1)).items.length, 1);
    });

    test('labels and title are payload strings, in payload order', () {
      final p = PdOtherPacks.fromMap(_packs());
      expect(p.has, isTrue);
      expect(p.title, 'Other packs');
      expect(p.items.map((e) => e.label).toList(),
          ['Tablet', 'A Tablet SR', 'Suspension']);
    });

    test('nothing in the row is selected, and the row is drawn all one way',
        () {
      // There is no selected state to read: the model has no such field, and
      // the chip has no branch that could colour one entry differently.
      final src =
          File('lib/screens/product_detail_screen.dart').readAsStringSync();
      final chip = src.substring(
          src.indexOf('class _PackChip'), src.indexOf('class _TitleBlock'));
      expect(chip.contains('selected'), isFalse,
          reason: 'every pack chip is the same outlined pill');
      expect(chip.contains('Ds.c.brand'), isFalse,
          reason: 'no green fill in the Other packs row');
      // A payload that still carries the old key is parsed, and ignored.
      final p = PdOtherPacks.fromMap({
        'has': true,
        'title': 'Other packs',
        'items': [
          {'product_id': 900102, 'label': 'Suspension', 'selected': true},
        ],
      });
      expect(p.items.single.label, 'Suspension');
    });

    // CMD #1903 (Om, live) — the strip is ONE SIDEWAYS ROW. A Wrap put each
    // pack on its own full-width line the moment three labels stopped fitting
    // across, and three full-width green/grey bars read as three buttons to
    // press rather than as one switch showing where you are. _OtherPacks is a
    // private widget on a screen that needs a live Supabase client to pump, so
    // the shape is held down at the source: no Wrap in the block, a horizontal
    // SingleChildScrollView instead, and a chip that is padded like the form
    // pill above the title rather than sized like a button.
    test('the strip scrolls sideways — it is never a stack of full-width rows',
        () {
      final src = File('lib/screens/product_detail_screen.dart')
          .readAsStringSync();
      final block = src.substring(
          src.indexOf('class _OtherPacks'), src.indexOf('class _TitleBlock'));
      expect(block.contains('Wrap('), isFalse,
          reason: 'a Wrap stacks the packs as soon as they stop fitting');
      expect(block.contains('scrollDirection: Axis.horizontal'), isTrue);
      expect(block.contains('BoxConstraints(minHeight: Ds.space.x32)'), isFalse,
          reason: 'a pack chip is a pill, not a button');
      expect(block.contains('vertical: Ds.space.x4'), isTrue,
          reason: 'the chip matches the form pill above the title');
    });

    test('the whole page still parses it as part of ONE payload', () {
      final d = ProductDetail.fromMap({
        'ok': true,
        'header': {'id': 900101, 'name': 'Monticope Tablet'},
        'other_packs': _packs(),
      });
      expect(d.otherPacks.has, isTrue);
      expect(d.otherPacks.items.length, 3);
    });
  });
}
