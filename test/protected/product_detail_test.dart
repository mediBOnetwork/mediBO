// PROTECTED — CHANGE #636.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes product-page behaviour, never to make an unrelated
// change go green.
//
// What this holds down:
//
//   1. The product page is ONE RPC. product_detail() returns the whole page
//      render-ready and the page prints it verbatim — name, company, price
//      strings, overview rows, section titles and bodies. A value that appears
//      on screen but not in the payload means the app started deciding again.
//
//   2. Every user-facing heading comes from the payload's `labels` block
//      (backed by the storefront_ui_label table), NOT from a string typed in
//      Dart. "Overview" and "Similar products" are data.
//
//   3. ok:false renders the backend's own not-found page and never throws.
//      Before #636 the app had no product page at all; the failure mode being
//      pinned here is a future one — someone hardcoding "Product not found".
//
//   4. Absence is explicit. product_detail() never returns null inside its
//      payload: has_mrp / has_gst / has_supplier_label / my_history.has decide
//      whether a row shows. A missing value must read as "hide", never as a
//      fabricated ₹0.00 or an invented label.
//
// Fixtures are hand-copied from a real product_detail() response taken off the
// live database on 2026-08-02. No network, no Supabase, no camera.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product_detail.dart';
import 'package:pharma_b2b/screens/product_detail_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The labels product_detail() attaches to every response, ok:true or not.
const _labels = <String, dynamic>{
  'pdp_overview_title': 'Overview',
  'pdp_similar_title': 'Similar products',
  'pdp_read_more': 'Read more',
  'pdp_read_less': 'Read less',
  'pdp_rx_banner': 'Prescription required',
  'pdp_not_found_title': 'Product not found',
  'pdp_not_found_body': 'This product is no longer available.',
  'pdp_not_found_cta': 'Go back',
  'stock_out_label': 'Out of stock',
  'card_notify_label': 'Notify me',
  'cart_pill_cta': 'View cart',
};

/// A fabricated product_detail() ok:true payload — the exact shape the RPC
/// returns, including the never-null convention.
Map<String, dynamic> _payload({
  bool hasMrp = true,
  bool hasGst = true,
  bool buyable = true,
  bool hasSupplierLabel = true,
  bool rxRequired = false,
  Map<String, dynamic>? rx,
  Map<String, dynamic>? rxLicence,
  bool hasHistory = false,
  bool showWishlist = false,
  bool isWishlisted = false,
  List<Map<String, dynamic>> similar = const [],
}) =>
    {
      'ok': true,
      'id': 176026,
      // CMD #1825 — rx_badge()'s block and the buyer's licence state, exactly
      // as product_detail() sends them side by side. Absent when null, which
      // is what an anonymous visitor or a pack with no class gets.
      if (rx != null) 'rx': rx,
      if (rxLicence != null) 'rx_licence': rxLicence,
      'labels': _labels,
      'header': {
        'name': 'Alkacel 100mg Injection',
        'company': 'CELON LABORATORIES LTD',
        'pack_label': 'Vial of 1 Injection',
        'form_chip': 'Vial',
        'rx_required': rxRequired,
        'images': <String>[],
      },
      'price': {
        'has_mrp': hasMrp,
        'mrp_label': hasMrp ? '₹2,597.00' : '',
        'mrp_note': 'MRP',
        'has_gst': hasGst,
        'gst_label': hasGst ? 'GST 12%' : '',
        'scheme': false,
      },
      // CHANGE #638 — the page reads THIS block for its price, the same one
      // every card reads. `price.mrp_label` above is still sent but is no
      // longer the headline.
      'pricing': {
        'mrp': 2597.0,
        'sale_price': 2597.0,
        'discount_pct': 0,
        'mrp_display': '₹2,597.00',
        'price_display': '₹2,597.00',
        'discount_label': '',
        'has_price': hasMrp,
        'has_discount': false,
      },
      // CHANGE #640 — the verdict now FOLLOWS `buyable` in this fixture instead
      // of being pinned to available. It used to say "available" while
      // stock.buyable said false, i.e. the fixture reproduced the live bug:
      // one payload, two answers. The page reads the verdict as its one source
      // now, so a fixture that contradicts itself no longer describes anything
      // real. The assertion below is unchanged — an unavailable product still
      // prints the backend's own out-of-stock label.
      'availability': {
        'is_available': buyable,
        'can_add': buyable,
        'cta_label': buyable ? 'Add to cart' : 'Unavailable',
        'gated': true,
        'colors': buyable
            ? {'bg': '#1B7A43', 'fg': '#FFFFFF'}
            : {'bg': '#F3F4F6', 'fg': '#9CA3AF'},
      },
      'stock': {
        'buyable': buyable,
        'has_supplier_label': hasSupplierLabel,
        'supplier_label': hasSupplierLabel ? 'Sold by MediBO Warehouse' : '',
      },
      'overview': const [
        {'label': 'Composition', 'value': 'Paclitaxel (100mg)'},
        {'label': 'Manufacturer', 'value': 'CELON LABORATORIES LTD'},
        {'label': 'Storage', 'value': 'Store below 30°C'},
      ],
      'has_highlight': false,
      'highlight': '',
      'sections': const [
        {'title': 'Introduction', 'body': 'Alkacel is used to treat cancer.'},
        {'title': 'Uses', 'body': '• Breast cancer'},
      ],
      'similar': similar,
      'similar_ready': true,
      'my_history': {
        'has': hasHistory,
        'label': hasHistory ? 'You ordered 12 in the last 90 days' : '',
      },
      'show_wishlist': showWishlist,
      'is_wishlisted': isWishlisted,
    };

/// Distinguishes successive pumps in one test. Without a fresh key Flutter
/// reuses the existing State, `initState` never runs again and the second
/// payload is silently ignored — which makes a "the label changed" assertion
/// pass against stale data.
int _pumpSeq = 0;

/// Pumps the page with the payload already parsed — no RPC, no Supabase.
///
/// The surface is deliberately tall: the page is a ListView, so a short
/// viewport simply would not build the lower sections and the assertions below
/// would pass or fail on scroll position rather than on what the page renders.
/// rx_badge('Rx') as CMD #1825 sends it: soft-info tone, never danger red.
/// `title` and `note` are still in the payload (other surfaces may want
/// them) — the assertions below prove the PDP does not print them.
const Map<String, dynamic> _rxTag = {
  'has': true,
  'is_rx': true,
  'label': 'Rx',
  'title': 'Prescription medicine',
  'note': 'Schedule H / H1 stock. Your pharmacy drug licence must be on file to order this.',
  'tone': {'bg': '#EFF6FF', 'fg': '#1E40AF'},
};

const Map<String, dynamic> _otcTag = {
  'has': true,
  'is_rx': false,
  'label': 'OTC',
  'title': 'Over the counter',
  'note': 'No prescription needed for this pack.',
  'tone': {'bg': '#D1FAE5', 'fg': '#065F46'},
};

/// Every Container painted in the danger-red the old block used.
Finder _dangerContainers(WidgetTester tester) => find.byWidgetPredicate((w) =>
    w is Container &&
    w.decoration is BoxDecoration &&
    (w.decoration as BoxDecoration).color == const Color(0xFFFEE2E2));

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: ProductDetailScreen(
          key: ValueKey('pdp-${_pumpSeq++}'),
          productId: '176026',
          loader: (_) async => ProductDetail.fromMap(payload),
          // CHANGE #640 — the seam existed but was never wired here. It did not
          // matter while the fixture's verdict was pinned to "available": the
          // page only asks about a Notify subscription for a product it cannot
          // sell, so the unavailable branch was unreachable and the real
          // MedicineRepository (and its uninitialised Supabase) was never
          // constructed. Now that an unavailable fixture is actually
          // unavailable, the probe runs — and it must stay network-free.
          notifyStatusLoader: (_) async => false,
        ),
      ),
    ),
  );
  // One extra pump to let the loader's Future resolve into setState.
  await tester.pumpAndSettle();
}

void main() {
  // CMD #410 — the page now writes `c410_reviews_block` to the render log so
  // the live build can PROVE the reviews block reached a real browser (canvas
  // cannot be clicked by a tool). RenderLog's 800 ms flush is a real Timer
  // that would outlive every test here and try to reach Supabase, so it is
  // disabled — exactly the setUpAll CLAUDE.md prescribes. No assertion below
  // is touched: this is the harness, not the contract.
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the page prints the payload verbatim', () {
    testWidgets('header, company and pack come straight from the payload',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.text('Alkacel 100mg Injection'), findsOneWidget);
      // Twice on purpose: the header line AND the overview's Manufacturer row.
      // Both are the payload's own string; neither is composed here.
      expect(find.text('CELON LABORATORIES LTD'), findsNWidgets(2));
      expect(find.text('Vial of 1 Injection'), findsOneWidget);
      expect(find.text('Vial'), findsOneWidget);
    });

    testWidgets('price row is the backend string, never a formatted number',
        (tester) async {
      await _pump(tester, _payload());

      // CHANGE #638 — the price row and the sticky buy bar both read
      // pricing.price_display, the SAME block the cards read. One price
      // source everywhere.
      expect(find.text('₹2,597.00'), findsNWidgets(2),
          reason: 'price_display verbatim, in the price row and the sticky bar');
      expect(find.text('MRP'), findsOneWidget,
          reason: 'mrp_note survives only under the sticky bar price');
      expect(find.text('GST 12%'), findsOneWidget, reason: 'gst_label verbatim');
    });

    testWidgets('overview renders every label:value row the payload sent',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.text('Composition'), findsOneWidget);
      expect(find.text('Paclitaxel (100mg)'), findsOneWidget);
      expect(find.text('Storage'), findsOneWidget);
      expect(find.text('Store below 30°C'), findsOneWidget);
    });

    testWidgets('section titles and bodies are the payload, not Dart constants',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.text('Introduction'), findsOneWidget);
      expect(find.text('Alkacel is used to treat cancer.'), findsOneWidget);
      expect(find.text('Uses'), findsOneWidget);
      expect(find.text('• Breast cancer'), findsOneWidget);
    });

    testWidgets('the Overview heading is a backend label', (tester) async {
      // If someone replaces this with a Dart literal the test still passes on
      // the default copy — so ALSO assert the page follows a changed label.
      await _pump(tester, _payload());
      expect(find.text('Overview'), findsOneWidget);

      final renamed = _payload();
      renamed['labels'] = {
        ..._labels,
        'pdp_overview_title': 'Product details',
      };
      await _pump(tester, renamed);

      expect(find.text('Product details'), findsOneWidget,
          reason: 'the heading must follow storefront_ui_label, not a literal');
      expect(find.text('Overview'), findsNothing);
    });
  });

  group('absence is explicit, never a fabricated value', () {
    testWidgets('has_mrp:false hides the price row rather than showing ₹0',
        (tester) async {
      await _pump(tester, _payload(hasMrp: false));

      expect(find.text('MRP'), findsNothing);
      expect(find.textContaining('₹'), findsNothing,
          reason: 'no price block at all beats an invented ₹0.00');
    });

    testWidgets('has_gst:false hides the GST chip', (tester) async {
      await _pump(tester, _payload(hasGst: false));
      expect(find.textContaining('GST'), findsNothing);
    });

    testWidgets('not buyable shows the backend out-of-stock label',
        (tester) async {
      await _pump(tester,
          _payload(buyable: false, hasSupplierLabel: false));

      expect(find.text('Out of stock'), findsOneWidget,
          reason: 'stock_out_label, from the payload');
      expect(find.text('Sold by MediBO Warehouse'), findsNothing);
    });

    testWidgets('buyable shows the supplier label chip', (tester) async {
      await _pump(tester, _payload());
      expect(find.text('Sold by MediBO Warehouse'), findsOneWidget);
      expect(find.text('Out of stock'), findsNothing);
    });

    testWidgets('my_history.has gates the history chip', (tester) async {
      await _pump(tester, _payload());
      expect(find.text('You ordered 12 in the last 90 days'), findsNothing);

      await _pump(tester, _payload(hasHistory: true));
      expect(find.text('You ordered 12 in the last 90 days'), findsOneWidget,
          reason: 'the sentence is composed in Postgres, printed here');
    });

  });

  // CMD #1825 — Om's decision, 6 Sep 2026: the product page shows Rx or OTC
  // ONLY. mediBO's buyers are licence-verified pharmacies, so the CHANGE #461
  // full-width red "your drug licence must be on file" block (and the older
  // `pdp_rx_banner` fallback under it) was a warning aimed at nobody, and a
  // red that fires on every Schedule H pack is a red nobody reads. The
  // licence RULE is untouched — it still speaks at the cart — this file only
  // pins where the class is shown and that nothing else is.
  //
  // This is the one command allowed to edit these assertions: it explicitly
  // changes the protected behaviour they held down.
  group('prescription class (CMD #1825)', () {
    testWidgets('an Rx product prints the backend label as a tag and nothing else',
        (tester) async {
      await _pump(
        tester,
        _payload(
          rxRequired: true,
          rx: _rxTag,
          rxLicence: const {
            'has': true,
            'reason': 'ok',
            'licence': 'MH-MUM-20B-1234',
            'ok_note': 'Licence MH-MUM-20B-1234 on file',
          },
        ),
      );
      expect(find.text('Rx'), findsOneWidget,
          reason: 'the label is rx_badge()\'s, printed verbatim');
      // No sentence of any kind: not the block title, not the licence note,
      // not the ok-note, not the legacy banner.
      expect(find.text('Prescription medicine'), findsNothing);
      expect(find.textContaining('drug licence must be on file'), findsNothing);
      expect(find.textContaining('Licence MH-MUM-20B-1234'), findsNothing);
      expect(find.text('Prescription required'), findsNothing);
      expect(find.byIcon(Icons.receipt_long_outlined), findsNothing);

      // The tag wears the payload's own tone — and it is not the danger red
      // the block used to paint.
      final tag = tester.widget<Container>(find.ancestor(
        of: find.text('Rx'),
        matching: find.byType(Container),
      ).first);
      final deco = tag.decoration as BoxDecoration;
      expect(deco.color, const Color(0xFFEFF6FF),
          reason: 'tone.bg is the backend\'s, applied verbatim');
      expect(_dangerContainers(tester), findsNothing,
          reason: 'no #FEE2E2 surface anywhere on the page');
      // A tag, not a block: it is no wider than its text plus padding.
      expect(tester.getSize(find.byWidget(tag)).width, lessThan(80));
    });

    testWidgets('an OTC product prints its own label the same way',
        (tester) async {
      await _pump(tester, _payload(rx: _otcTag));
      expect(find.text('OTC'), findsOneWidget);
      expect(find.text('Rx'), findsNothing);
      expect(find.text('Over the counter'), findsNothing);
      expect(find.text('No prescription needed for this pack.'), findsNothing);
      expect(_dangerContainers(tester), findsNothing);
    });

    testWidgets('the label is printed verbatim, never mapped in Dart',
        (tester) async {
      // A label this build has never seen: if the page decided what an Rx
      // class is called, it would print "Rx" (or nothing). It prints this.
      await _pump(
        tester,
        _payload(rx: {..._rxTag, 'label': 'Sch. H1'}),
      );
      expect(find.text('Sch. H1'), findsOneWidget);
      expect(find.text('Rx'), findsNothing);
    });

    testWidgets('rx.has false draws nothing at all, even when rx_required is set',
        (tester) async {
      await _pump(
        tester,
        _payload(
          rxRequired: true,
          rx: const {'has': false, 'is_rx': false},
        ),
      );
      expect(find.text('Rx'), findsNothing);
      expect(find.text('OTC'), findsNothing);
      expect(find.text('Prescription required'), findsNothing,
          reason: 'the pdp_rx_banner fallback is gone: header.rx_required '
              'alone no longer draws anything');
      expect(_dangerContainers(tester), findsNothing);

      // And an absent block is the same as has:false.
      await _pump(tester, _payload(rxRequired: true));
      expect(find.text('Rx'), findsNothing);
      expect(find.text('Prescription required'), findsNothing);
    });
  });

  group('similar rail', () {
    testWidgets('renders nothing at all when the payload sent no tiles',
        (tester) async {
      await _pump(tester, _payload());
      expect(find.text('Similar products'), findsNothing,
          reason: 'an empty rail must not leave a dangling heading');
    });

    testWidgets('renders the heading and the tiles the payload sent',
        (tester) async {
      await _pump(
        tester,
        _payload(similar: const [
          {
            'id': 293157,
            'name': 'Alkacel PGF 50mg Injection',
            'company': 'CELON LABORATORIES LTD',
            'pack_label': '',
            'form_chip': 'Vial',
            'image': '',
            'mrp_label': '₹2,343.75',
          },
        ]),
      );

      expect(find.text('Similar products'), findsOneWidget);
      expect(find.text('Alkacel PGF 50mg Injection'), findsOneWidget);
      expect(find.text('₹2,343.75'), findsOneWidget);
    });
  });

  group('ok:false is a page, not a crash', () {
    testWidgets('renders the backend not-found copy', (tester) async {
      await _pump(tester, {
        'ok': false,
        'error': 'not_found',
        'labels': _labels,
      });

      expect(find.text('Product not found'), findsOneWidget);
      expect(find.text('This product is no longer available.'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('not-found copy follows the label table too', (tester) async {
      await _pump(tester, {
        'ok': false,
        'error': 'not_found',
        'labels': {..._labels, 'pdp_not_found_title': 'Gone'},
      });

      expect(find.text('Gone'), findsOneWidget);
      expect(find.text('Product not found'), findsNothing);
    });

    testWidgets('a payload with no labels at all still renders, silently',
        (tester) async {
      // The RPC always sends labels; if a future one does not, the page shows
      // no copy rather than copy invented in Dart.
      await _pump(tester, {'ok': false, 'error': 'not_found'});
      expect(tester.takeException(), isNull);
      expect(find.text('Product not found'), findsNothing);
    });
  });

  group('the parser itself', () {
    test('never invents a value for a missing key', () {
      final d = ProductDetail.fromMap({'ok': true, 'id': 5});

      expect(d.ok, isTrue);
      expect(d.id, '5');
      expect(d.name, '');
      expect(d.company, '');
      expect(d.hasMrp, isFalse);
      expect(d.mrpLabel, '');
      expect(d.buyable, isFalse);
      expect(d.overview, isEmpty);
      expect(d.sections, isEmpty);
      expect(d.similar, isEmpty);
      expect(d.hasHistory, isFalse);
      expect(d.label('anything'), '');
    });

    test('ok:false keeps the labels so the not-found page can render', () {
      final d = ProductDetail.fromMap(
          {'ok': false, 'error': 'not_found', 'labels': _labels});

      expect(d.ok, isFalse);
      expect(d.label('pdp_not_found_title'), 'Product not found');
    });

    test('blank image urls are dropped, so the carousel never shows an empty '
        'slide', () {
      final p = _payload();
      (p['header'] as Map)['images'] = ['a.jpg', '', 'b.jpg'];
      final d = ProductDetail.fromMap(p);

      expect(d.images, ['a.jpg', 'b.jpg']);
    });

    test('show_wishlist and is_wishlisted default to false when absent', () {
      final d = ProductDetail.fromMap({'ok': true, 'id': 5});
      expect(d.showWishlist, isFalse);
      expect(d.isWishlisted, isFalse);
    });

    test('show_wishlist and is_wishlisted read from the payload', () {
      final d = ProductDetail.fromMap(
          _payload(showWishlist: true, isWishlisted: true));
      expect(d.showWishlist, isTrue);
      expect(d.isWishlisted, isTrue);
    });
  });

  group('wishlist button', () {
    testWidgets('hidden when show_wishlist is false (gated / not approved)',
        (tester) async {
      await _pump(tester, _payload());
      expect(find.byIcon(Icons.favorite_border), findsNothing);
      expect(find.byIcon(Icons.favorite), findsNothing);
    });

    testWidgets(
        'shows outline heart when show_wishlist:true and is_wishlisted:false',
        (tester) async {
      await _pump(tester, _payload(showWishlist: true, isWishlisted: false));
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsNothing);
    });

    testWidgets(
        'shows filled heart when show_wishlist:true and is_wishlisted:true',
        (tester) async {
      await _pump(tester, _payload(showWishlist: true, isWishlisted: true));
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsNothing);
    });
  });
}
