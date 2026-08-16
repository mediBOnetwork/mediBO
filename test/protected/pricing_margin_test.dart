// PROTECTED — CHANGE #174 (B2B net-rate / margin pricing engine).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes pricing-display behaviour, never to make an unrelated
// change go green.
//
// The rule this file exists to hold down:
//
//   A product with no captured pricing must look EXACTLY as it did before this
//   change — MRP, no net rate, no margin, no chip, no ribbon. Not a 0% margin,
//   not "₹0.00", not a greyed placeholder. "We do not know this product's PTR
//   yet" and "this product earns nothing" are different facts, and the ONLY
//   thing that separates them is `display_mode` from the backend.
//
// Why it can regress: the tempting shortcuts are all one-liners — deriving the
// mode from `margin_label.isNotEmpty`, defaulting a missing margin to 0,
// striking the MRP whenever an mrp_display arrives, or computing
// (mrp - net) / mrp in Dart to avoid a round-trip. Each of those prints a
// number mediBO never agreed to sell at.
//
//   1. mrp_only renders the pre-#174 card exactly: MRP caption + MRP price,
//      no struck line, no ribbon, no chip.
//   2. full renders the BACKEND's strings: the headline number is the net
//      rate, the struck number is the MRP, the ribbon and the chip colours
//      arrive in the payload. Nothing is computed here.
//   3. The chip's colours come from the payload's margin band, so a low margin
//      and a high one can never look alike because Dart picked one green.
//   4. A payload with no `display_mode` at all (an older RPC, a cached page)
//      degrades to mrp_only rather than throwing or inventing full mode.
//   5. The cart's margin row is the backend's `has` flag, its label and its
//      total verbatim, and un-priced lines are reported in `note` — never
//      folded into the total as zero.
//
// No network, no Supabase.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_nav_entries.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';

/// The `pricing` block exactly as `storefront_pricing()` returns it for a
/// product with NOTHING captured. Every added key states an absence.
Map<String, dynamic> _mrpOnly() => {
      'has_price': true,
      'mrp': 117.19,
      'sale_price': 117.19,
      'price_display': '₹117.19',
      'price_caption': 'MRP',
      'mrp_display': '',
      'discount_pct': 0,
      'has_discount': false,
      'discount_label': '',
      'ribbon_top': '',
      'ribbon_bottom': '',
      'margin_label': '',
      'display_mode': 'mrp_only',
      'pricing_ready': false,
      'has_net': false,
      'net_display': '',
      'net_caption': '',
      'has_margin': false,
      'margin_pct': null,
      'margin_chip': null,
      'has_ptr': false,
      'ptr_display': '',
      'ptr_caption': '',
      'has_scheme': false,
      'scheme_text': '',
      'has_struck_mrp': false,
      'gst': null,
    };

/// The same product once a PTR + GST arrive: PTR ₹82.50, GST 12%, scheme 10+1
/// → taxable ₹75.00, GST ₹9.00, net ₹84.00, margin ₹33.19 (28.3%).
/// These are the numbers the ENGINE produced; the app only prints them.
Map<String, dynamic> _full() => {
      ..._mrpOnly(),
      'display_mode': 'full',
      'pricing_ready': true,
      'sale_price': 84.00,
      'price_display': '₹84.00',
      'price_caption': 'NET',
      'has_net': true,
      'net_display': '₹84.00',
      'net_caption': 'NET',
      'has_struck_mrp': true,
      'mrp_display': '₹117.19',
      'has_discount': true,
      'discount_label': '28.3% margin',
      'has_margin': true,
      'margin_pct': 28.3,
      'margin_label': 'You earn ₹33.19',
      'margin_chip': {
        'label': '28.3% margin',
        'bg': '#D1FAE5',
        'fg': '#065F46',
        'band': 'High margin',
      },
      'ribbon_top': '28.3%',
      'ribbon_bottom': 'margin',
      'has_ptr': true,
      'ptr_display': '₹82.50',
      'ptr_caption': 'PTR',
      'has_scheme': true,
      'scheme_text': '10+1',
      'gst': {
        'title': 'GST breakup',
        'pct': 12,
        'pct_display': 'GST 12%',
        'is_igst': false,
        'taxable_display': '₹75.00',
        'amount_display': '₹9.00',
        'net_display': '₹84.00',
        'lines': [
          {'label': 'Taxable value', 'value': '₹75.00'},
          {'label': 'CGST 6%', 'value': '₹4.50'},
          {'label': 'SGST 6%', 'value': '₹4.50'},
        ],
      },
    };

Map<String, dynamic> _row(Map<String, dynamic> pricing) => {
      'id': 176044,
      'product_name': 'Tranomac MF 500mg/250mg Tablet',
      'marketer': 'MACLEODS PHARMACEUTICALS LTD',
      'pack_size': 'Strip of 10 tablets',
      'pack_type': 'Strip',
      'image_url_1': '',
      'mrp': '117.19',
      'availability': {
        'is_available': true,
        'can_add': true,
        'cta_label': 'Add to cart',
        'gated': true,
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      },
      'pricing': pricing,
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> pricing) async {
  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: CompactProductCard.extent,
            child: CompactProductCard(
              product: Product.fromMap(_row(pricing)),
              onTap: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

/// Loads a CartModel from a fabricated cart_render() payload — the same seam
/// cart_unavailable_test uses, so nothing here reaches Supabase.
Future<CartModel> _loadedCart(Map<String, dynamic> payload) async {
  CartModel.rpcTransport = (fn, params) async => payload;
  final cart = CartModel.forTest();
  await cart.refresh();
  return cart;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  setUp(() {
    CartModel.rpcTransport = (fn, params) async =>
        {'ok': true, 'message': '', 'cart': <String, dynamic>{}};
  });
  tearDown(() => CartModel.rpcTransport = null);

  group('a product with no pricing captured shows MRP and nothing else', () {
    testWidgets('the MRP is the headline number, with the MRP caption',
        (tester) async {
      await _pump(tester, _mrpOnly());

      expect(find.text('₹117.19'), findsOneWidget);
      expect(find.text('MRP'), findsOneWidget);
    });

    testWidgets('no margin chip, no ribbon, no struck price', (tester) async {
      await _pump(tester, _mrpOnly());

      expect(find.textContaining('margin'), findsNothing,
          reason: 'an unknown margin must not be rendered as any margin');
      expect(find.textContaining('%'), findsNothing,
          reason: 'no percentage exists until the backend computes one');
      expect(find.text('₹0.00'), findsNothing,
          reason: 'zero is a price, not an absence');
    });

    testWidgets('the model reports mrp_only, not full', (tester) async {
      final p = Pricing.fromMap(_mrpOnly())!;

      expect(p.isFullPricing, isFalse);
      expect(p.marginChip, isNull);
      expect(p.gst, isNull);
      expect(p.hasStruckMrp, isFalse);
    });
  });

  group('once PTR and GST arrive the card prints the engine output', () {
    testWidgets('headline is the NET rate, struck number is the MRP',
        (tester) async {
      await _pump(tester, _full());

      expect(find.text('₹84.00'), findsOneWidget,
          reason: 'price_display verbatim — the app never computes a net rate');
      expect(find.text('₹117.19'), findsOneWidget,
          reason: 'mrp_display verbatim, in the struck position');
      expect(find.text('NET'), findsOneWidget,
          reason: 'the caption is a backend word, never typed in Dart');
    });

    testWidgets('the ribbon is the payload two lines', (tester) async {
      await _pump(tester, _full());

      expect(find.text('28.3%'), findsOneWidget);
      expect(find.text('margin'), findsOneWidget);
    });

    testWidgets('chip colours come from the band, not from Dart',
        (tester) async {
      final p = Pricing.fromMap(_full())!;

      expect(p.marginChip, isNotNull);
      expect(p.marginChip!.label, '28.3% margin');
      expect(p.marginChip!.bg, 0xFFD1FAE5);
      expect(p.marginChip!.fg, 0xFF065F46);
    });

    testWidgets('the tax split is printable pairs in payload order',
        (tester) async {
      final gst = Pricing.fromMap(_full())!.gst!;

      expect(gst.lines.map((l) => l.label).toList(),
          ['Taxable value', 'CGST 6%', 'SGST 6%']);
      expect(gst.lines.map((l) => l.value).toList(),
          ['₹75.00', '₹4.50', '₹4.50']);
      expect(gst.title, 'GST breakup',
          reason: 'even the section heading is backend copy');
    });

    testWidgets('margin strings are printed, never recomputed', (tester) async {
      // Deliberately inconsistent with mrp - net: if the app ever recomputed
      // the margin instead of printing it, this expectation would fail.
      final p = Pricing.fromMap({..._full(), 'margin_label': 'You earn ₹1.00'})!;

      expect(p.marginLabel, 'You earn ₹1.00');
    });
  });

  group('forward compatibility', () {
    test('a payload with no display_mode degrades to mrp_only', () {
      final legacy = {
        'has_price': true,
        'mrp': 2597,
        'sale_price': 2597,
        'price_display': '₹2,597.00',
        'price_caption': 'MRP',
        'mrp_display': '',
        'has_discount': false,
        'discount_label': '',
      };

      final p = Pricing.fromMap(legacy)!;
      expect(p.isFullPricing, isFalse);
      expect(p.displayMode, 'mrp_only');
      expect(p.marginChip, isNull);
    });

    test('a null pricing block still parses as absent, not as zero', () {
      expect(Pricing.fromMap(null), isNull);
      expect(Pricing.fromMap(const {'no_has_price_key': 1}), isNull);
    });
  });

  group('the cart margin is the backend answer', () {
    test('no priced line → no margin row at all', () async {
      final cart = await _loadedCart({
        'render': {
          'subtotal_display': '₹1,000.00',
          'margin': {'has': false, 'label': '', 'total_display': '', 'note': ''},
        }
      });

      expect(cart.marginHas, isFalse);
    });

    test('priced lines → label and total verbatim, un-priced ones noted',
        () async {
      final cart = await _loadedCart({
        'render': {
          'margin': {
            'has': true,
            'label': 'You earn on this order',
            'total_display': '₹99.57',
            'note': '1 item not priced yet - not counted above',
          },
        }
      });

      expect(cart.marginHas, isTrue);
      expect(cart.marginLabel, 'You earn on this order');
      expect(cart.marginTotalDisplay, '₹99.57');
      expect(cart.marginNote, '1 item not priced yet - not counted above',
          reason: 'un-priced lines are named, never counted as zero margin');
    });
  });

  // A backend with no reachable frontend is a failed change (CLAUDE.md §11).
  // The historical bug (#645/#646) was an entry whose route key had no case in
  // _handleAdminNav: a perfect-looking menu row that does nothing on tap. This
  // asserts the whole chain for the pricing screen — entry exists, carries a
  // route, and that exact key is switched on in home_shell.
  group('the admin backfill screen is reachable', () {
    test('Product pricing has an overflow entry with a route', () {
      final routes =
          kAdminOverflowNav.map((e) => e.route).whereType<String>().toSet();

      expect(routes, contains('pricing_backfill'));
    });

    test('_handleAdminNav switches on that exact key', () {
      final src = File('lib/screens/home_shell.dart').readAsStringSync();

      expect(src.contains("case 'pricing_backfill':"), isTrue,
          reason: 'route key with no case = a menu row that does nothing');
      expect(src.contains('PricingBackfillScreen'), isTrue,
          reason: 'the case must actually push the screen');
    });
  });
}
