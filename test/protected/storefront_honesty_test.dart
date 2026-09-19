// PROTECTED — CHANGE #746: the storefront tells the truth about margin, and
// Compare lives on the product page.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour.
//
// THE FACT: medicine_pricing holds FOUR rows against 5.6 lakh products. Every
// margin the customer surface could draw came from that table, so a "Highest
// margin" sort, four "Above N%" chips and a "You earn ₹24.79" line were a
// number mediBO does not have — in this business the rate is discovered AFTER
// the purchase. And a Compare tick sat under every card in search results and
// the category grid, where a comparison has nothing to compare against yet.
//
// What this holds down:
//
//   1. THE STOREFRONT HAS NO COMPARE CONTROL. The results grid and the feed
//      carry no CompareCheckbox and no CompareBar — asserted against the file
//      itself, because the grid is a lazy canvas and a widget that was deleted
//      cannot be found by a finder either way. A file assertion is the only
//      one that fails when someone puts it back.
//   2. THE PRODUCT PAGE STILL HAS IT. The same assertion in reverse, so this
//      test can never be satisfied by deleting compare altogether — which
//      would be a different (and wrong) change.
//   3. AN ABSENT LABEL DRAWS NOTHING. storefront_labels() stopped sending
//      cmp_add, so the card surface reads '' — and '' must render no tick, no
//      empty box and no tap target. This is the payload path: even if the
//      widget came back, the backend's silence is what removes it.
//   4. THE CARD PRINTS WHAT IT IS SENT, AND NOTHING MORE. The compact card
//      computes no margin of its own: a payload with the margin stripped (the
//      shape _margin_strip now returns) renders no ribbon and no margin text,
//      and the price it shows is the backend's own string.
//
// No network, no Supabase, no goldens.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/data/storefront_labels.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';
import 'package:pharma_b2b/widgets/compare_tray.dart';

String _read(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '$path is missing — did it move?');
  return f.readAsStringSync();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  test('1 — the storefront carries no compare control', () {
    final src = _read('lib/screens/storefront_screen.dart');
    expect(src.contains('CompareCheckbox'), isFalse,
        reason: 'a Compare tick is back on the storefront cards — CHANGE #746 '
            'moved compare to the product page');
    expect(src.contains('CompareBar'), isFalse,
        reason: 'the compare tray is back above the storefront grid');
    expect(src.contains('CompareSelection'), isFalse,
        reason: 'the storefront is holding compare state again');
  });

  test('2 — the product page still has compare', () {
    // CMD #2040 changed the FORM, not the rule; #2073, #2074 and #2095 each
    // changed it again: #746 put compare on the full product page and nowhere
    // else, and it still is. The outlined button under the price became a
    // top-bar glyph beside the heart; the table became a pushed page and then,
    // in CMD #2095, an 85% bottom SHEET over the product — comparing is a
    // glance, not a destination, and /compare/:id still resolves to the same
    // table for a shared link. So what to look for is that control and the
    // door it opens.
    final src = _read('lib/screens/product_detail_screen.dart');
    expect(src.contains("ValueKey('pdp-compare-button')"), isTrue,
        reason: 'compare belongs on the full product page — removing it there '
            'is not what CHANGE #746 asked for');
    expect(src.contains('_openCompare'), isTrue,
        reason: 'the control must still make the same-salt call');
    expect(src.contains('showCompareSheet'), isTrue,
        reason: 'the control must still open the backend-composed table');
    expect(_read('lib/screens/compare_screen.dart').contains('CompareScreen'),
        isTrue,
        reason: 'and /compare/:id must still resolve to that same table');
    // CMD #2073 — and NO card anywhere draws a Compare row: the page's own
    // rail stopped passing the caption, and the shared card still takes it as
    // an opt-in parameter that defaults off.
    expect(src.contains('CompareButton'), isFalse,
        reason: 'the full-width Compare button under the price is gone — it '
            'is the top-bar glyph now');
    expect(src.contains('compareLabel:'), isFalse,
        reason: 'a card on the product page must not carry a Compare row');
    final card = _read('lib/widgets/compact_product_card.dart');
    expect(card.contains("this.compareLabel = ''"), isTrue,
        reason: 'a storefront card must not grow a Compare button by default');
  });

  testWidgets('3 — an absent cmp_add label draws no tick at all',
      (tester) async {
    // storefront_labels() no longer sends cmp_add, so this is what the card
    // surface actually reads.
    StorefrontLabels.reset();
    addTearDown(StorefrontLabels.reset);
    expect(StorefrontLabels.get('cmp_add'), '');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompareCheckbox(
          label: StorefrontLabels.get('cmp_add'),
          selected: false,
          onTap: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    final size = tester.getSize(find.byType(CompareCheckbox));
    expect(size.width == 0 || size.height == 0, isTrue,
        reason: 'an empty caption must occupy nothing, not an invisible tap '
            'target the customer can still hit');
  });

  testWidgets('4 — a margin-stripped payload renders no ribbon and no margin',
      (tester) async {
    // Exactly the shape _margin_strip returns for one of the four products
    // that DO have a real trade rate: PTR, net and GST survive; every margin
    // expression — the field, the label, the ribbon and the discount chip that
    // was the same string — is gone. Compare it with compact_card_test.dart's
    // fixture, which is the payload as it was BEFORE this change: '10% margin',
    // ribbon '10%' / 'MARGIN', 'You earn ₹259.70'.
    final row = <String, dynamic>{
      'id': 176026,
      'product_name': 'Monticope Tablet',
      'marketer': 'MANKIND PHARMA LTD',
      'pack_qty_label': '10 tablets in 1 strip',
      'pack_type_label': 'Strip',
      'image_url_1': '',
      'mrp': '117.19',
      'availability': {
        'is_available': true,
        'can_add': true,
        'cta_label': 'Add to cart',
        'cta_short': 'ADD',
        'gated': true,
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      },
      'pricing': {
        'has_price': true,
        'pricing_ready': true,
        'mrp': 117.19,
        'sale_price': 92.40,
        'price_display': '₹92.40',
        'price_caption': 'NET',
        'mrp_display': '₹117.19',
        'has_struck_mrp': true,
        // The margin is stripped, not merely empty-valued.
        'has_margin': false,
        'margin_label': '',
        'has_discount': false,
        'discount_label': '',
        'discount_pct': 0,
        'ribbon_top': '',
        'ribbon_bottom': '',
        'card_price': {
          'has_mrp': true,
          'mrp_label': 'MRP',
          'mrp_display': '₹117.19',
          'strike_mrp': true,
          'has_ptr': true,
          'ptr_label': 'PTR',
          'ptr_display': '₹82.50',
          'ptr_bg': '#1B7A43',
          'ptr_fg': '#FFFFFF',
          'has_note': false,
          'note': '',
        },
      },
    };

    // The card owns a cart control, so it needs the AppState the real tree
    // gives it — and a fake transport, so nothing reaches Supabase.
    CartModel.rpcTransport = (fn, params) async =>
        {'ok': true, 'message': '', 'cart': <String, dynamic>{}};
    addTearDown(() => CartModel.rpcTransport = null);

    await tester.pumpWidget(AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: CompactProductCard.extent,
            child:
                CompactProductCard(product: Product.fromMap(row), onTap: () {}),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('margin'), findsNothing);
    expect(find.textContaining('MARGIN'), findsNothing);
    expect(find.textContaining('You earn'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
    // What survives is the trade fact the backend really has.
    expect(find.text('₹117.19'), findsWidgets);
  });
}
