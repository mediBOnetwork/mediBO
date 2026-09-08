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
import 'package:pharma_b2b/theme.dart';
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
  Map<String, dynamic>? supply,
  Map<String, dynamic>? priceLines,
}) =>
    {
      'ok': true,
      'id': 176026,
      // CMD #1826 — the supply-confidence band and the two price lines, exactly
      // as product_detail() attaches them. Absent by default: an older backend
      // (or an untouched pack) sends neither, and the page must stay quiet.
      if (supply != null) 'supply': supply,
      if (priceLines != null) 'price_lines': priceLines,
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

/// CMD #1826 — a band whose `band` key says green while its label, tone and
/// sub-line say red. The page must print the words and paint the tone; any
/// Dart that re-derived either from `band` paints it green and fails. The two
/// decoy keys are what a leaky parser would print — the contract is silence.
const Map<String, dynamic> _contraryBand = {
  'has': true,
  'band': 'green',
  'tone': 'danger',
  'label': 'Checked recently, not confirmed',
  'has_sub': true,
  'sub': 'Last checked 3 days ago',
  'has_speed': false,
  'speed': 'Usually confirmed within 2 hours',
  'supplier_names': ['Zydus Distributors', 'Apex Pharma'],
  'supplier_count': 3,
};

/// price_lines with a pricing_ready row: the sale value deliberately differs
/// from the fixture's legacy `pricing.price_display` (₹2,597.00) so a page
/// that still printed the old single price as the hero is caught.
const Map<String, dynamic> _pricedLines = {
  'has': true,
  'mrp': {
    'caption': 'MRP',
    'value': '₹69.96',
    'has_amount': true,
    'has_note': true,
    'note': 'Printed pack ceiling — not the selling price',
    'tone': 'secondary',
  },
  'sale': {
    'caption': 'Sale price (PTR)',
    'value': '₹58.20',
    'has_amount': true,
    'has_note': true,
    'note': 'PTR ₹55.43 · GST 5%',
    'tone': 'primary',
  },
  'sticky': {
    'main': '₹58.20',
    'main_caption': 'Sale price',
    'main_tone': 'primary',
    'has_side': true,
    'side': 'MRP ₹69.96',
  },
};

/// price_lines with NO pricing_ready row: the sale slot carries the backend's
/// literal "PTR" value (Om amendment 3) — never a note, a dash, a zero or the MRP repeated.
const Map<String, dynamic> _quoteLines = {
  'has': true,
  'mrp': {
    'caption': 'MRP',
    'value': '₹69.96',
    'has_amount': true,
    'has_note': true,
    'note': 'Printed pack ceiling — not the selling price',
    'tone': 'secondary',
  },
  'sale': {
    'caption': 'Sale price',
    'value': 'PTR',
    'has_amount': false,
    'has_note': false,
    'note': '',
    'tone': 'secondary',
  },
  'sticky': {
    'main': 'PTR',
    'main_caption': 'Sale price',
    'main_tone': 'secondary',
    'has_side': true,
    'side': 'MRP ₹69.96',
  },
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

  // CMD #1835 — the Supply record block is a chip, and only a chip.
  //
  // It used to print the chip and then say the same thing again in longhand:
  // "100% fill rate" followed by "Filled 4 of 4 asks · last 180 days" — two
  // raw tallies and a window the buyer never chose, which is the exposure
  // CMD #1826 took out of the supply block next to it. The sentence was
  // deleted at the source (product_trust_strip no longer builds a `note` for
  // the fill-rate chip, and app_settings no longer holds `fill_note_fmt`), so
  // what is pinned here is that the PAGE does not put one back: a chip whose
  // payload carried no note renders nothing beside it, while a chip that DID
  // carry one — cold chain — still prints it verbatim.
  group('the Supply record block prints a chip, never a sentence', () {
    Map<String, dynamic> withTrust(List<Map<String, dynamic>> chips) =>
        _payload()..['trust'] = {
          'has': true,
          'title': 'Supply record',
          'chips': chips,
        };

    testWidgets('a fill-rate chip with no note shows the chip alone',
        (tester) async {
      await _pump(
          tester,
          withTrust([
            {'key': 'fill_rate', 'label': '100% fill rate', 'tone': 'success'},
          ]));

      // The title and the chip — the whole block.
      expect(find.text('Supply record'), findsOneWidget);
      expect(find.text('100% fill rate'), findsOneWidget);

      // And nothing that counts, tallies or dates it. These are the exact
      // shapes of the sentence that was removed; a Dart fallback that
      // re-derived any of them from the chip would land here.
      expect(find.textContaining('asks'), findsNothing);
      expect(find.textContaining('Filled'), findsNothing);
      expect(find.textContaining('180'), findsNothing);
      expect(find.textContaining('last '), findsNothing);
      // Not even an empty caption holding the space open.
      expect(find.text(''), findsNothing);
    });

    testWidgets('a chip that DID send a note still prints it verbatim',
        (tester) async {
      await _pump(
          tester,
          withTrust([
            {'key': 'fill_rate', 'label': '100% fill rate', 'tone': 'success'},
            {
              'key': 'cold_chain',
              'label': 'Cold chain',
              'note': 'Moved in a cold box',
              'tone': 'info',
            },
          ]));

      expect(find.text('Cold chain'), findsOneWidget);
      expect(find.text('Moved in a cold box'), findsOneWidget);
      // The fill-rate chip beside it is still bare.
      expect(find.text('100% fill rate'), findsOneWidget);
      expect(find.textContaining('asks'), findsNothing);
    });

    testWidgets('has:false draws no block at all', (tester) async {
      await _pump(
          tester,
          _payload()
            ..['trust'] = {'has': false, 'title': 'Supply record', 'chips': []});

      expect(find.text('Supply record'), findsNothing);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // CMD #1826 — the page never implies a price or a supply it does not have.
  // Every word below is the payload's; the fixtures are built to catch a page
  // that computes, re-derives or leaks anything.
  // ───────────────────────────────────────────────────────────────────────────
  group('supply confidence is a band, never a count (CMD #1826)', () {
    testWidgets(
        'the band prints label, tone and sub-line verbatim even when they '
        'contradict the band key', (tester) async {
      await _pump(tester, _payload(supply: _contraryBand));

      expect(find.text('Checked recently, not confirmed'), findsOneWidget,
          reason: 'the label is printed, not looked up from band');
      expect(find.text('Last checked 3 days ago'), findsOneWidget);
      expect(find.text('Supply confirmed recently'), findsNothing,
          reason: 'band:"green" must not summon the green copy');

      final band = tester.widget<Container>(
          find.byKey(const ValueKey('pdp-supply-band')));
      final color = (band.decoration as BoxDecoration).color;
      expect(color, Brand.negativeBg,
          reason: 'colour follows tone:"danger", never band:"green"');
      expect(color, isNot(Brand.positiveBg));
    });

    testWidgets('the speed line is drawn only when has_speed is true',
        (tester) async {
      await _pump(tester, _payload(supply: _contraryBand));
      expect(find.text('Usually confirmed within 2 hours'), findsNothing,
          reason: 'a speed string under has_speed:false is not a guess the '
              'page may print');

      await _pump(
          tester,
          _payload(supply: {
            ..._contraryBand,
            'has_speed': true,
          }));
      expect(find.text('Usually confirmed within 2 hours'), findsOneWidget);
    });

    testWidgets('has:false draws nothing at all', (tester) async {
      await _pump(
          tester,
          _payload(supply: const {
            'has': false,
            // Decoys: an older or buggy backend might still send words under
            // has:false. The contract is that they are not printed.
            'label': 'Supply confirmed recently',
            'sub': 'Last confirmed today',
            'tone': 'success',
          }));
      expect(find.byKey(const ValueKey('pdp-supply-band')), findsNothing);
      expect(find.text('Supply confirmed recently'), findsNothing);
      expect(find.text('Last confirmed today'), findsNothing);
    });

    testWidgets('an absent block is the same as has:false', (tester) async {
      await _pump(tester, _payload());
      expect(find.byKey(const ValueKey('pdp-supply-band')), findsNothing);
    });
  });

  group('two price lines, the sale price as hero (CMD #1826)', () {
    testWidgets('with a trade rate the hero and the sticky bar print the sale '
        'value and MRP is the captioned ceiling', (tester) async {
      await _pump(tester, _payload(priceLines: _pricedLines));

      // Hero row + sticky bar: the sale value appears exactly twice.
      expect(find.text('₹58.20'), findsNWidgets(2));
      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('pdp-sticky-main')))
              .data,
          '₹58.20');
      expect(find.text('Sale price (PTR)'), findsOneWidget);
      expect(find.text('PTR ₹55.43 · GST 5%'), findsOneWidget,
          reason: 'the sub-line is the backend sentence, not a Dart join');
      expect(find.text('₹69.96'), findsOneWidget,
          reason: 'the MRP row prints the backend rupee string');
      expect(find.text('Printed pack ceiling — not the selling price'),
          findsOneWidget);
      expect(find.text('MRP ₹69.96'), findsOneWidget,
          reason: 'the sticky side line is one backend string');
      expect(find.text('Sale price'), findsOneWidget,
          reason: 'sticky caption comes from the block');
      // The CHANGE #638 single price is deliberately a different number in
      // this fixture: if the page still printed it as the hero, this fails.
      expect(find.text('₹2,597.00'), findsNothing);
    });

    testWidgets('with no trade rate the sale row prints the on-quote copy, '
        'MRP stays a captioned reference and Add to cart stays enabled',
        (tester) async {
      await _pump(tester, _payload(priceLines: _quoteLines));

      // Om amendment 3: the caption stays "Sale price" and the VALUE is the
      // literal "PTR" — a backend string, printed twice, never re-worded.
      expect(find.text('PTR'), findsNWidgets(2),
          reason: 'hero row + sticky main, both the backend value');
      expect(find.text('Sale price'), findsNWidgets(2),
          reason: 'hero caption + sticky caption, both from ui copy');
      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('pdp-sticky-main')))
              .data,
          'PTR');
      // has_note:false — no on-quote sentence, no dash, no zero, no blank.
      expect(find.text('Trade rate is confirmed when suppliers quote'),
          findsNothing);
      expect(find.text('On quote'), findsNothing);
      expect(find.text('—'), findsNothing);
      expect(find.text('₹69.96'), findsOneWidget);
      expect(find.text('MRP ₹69.96'), findsOneWidget);
      expect(find.text('Printed pack ceiling — not the selling price'),
          findsOneWidget);
      expect(find.text('₹2,597.00'), findsNothing,
          reason: 'MRP is never presented as the price any more');
      expect(find.text('Add to cart'), findsOneWidget,
          reason: 'a quote-driven B2B buyer orders before the rate is fixed');
      expect(find.text('Unavailable'), findsNothing);
    });

    testWidgets('has_amount decides the ink: a phrase is never painted as a '
        'price, a rupee amount is', (tester) async {
      await _pump(tester, _payload(priceLines: _quoteLines));
      final phrase = tester.widget<Text>(find.descendant(
          of: find.byKey(const ValueKey('pdp-sale-line')),
          matching: find.text('PTR')));
      expect(phrase.style?.color, isNot(Brand.price),
          reason: 'has_amount:false is the secondary ink, never the price ink');

      await _pump(tester, _payload(priceLines: _pricedLines));
      final amount = tester.widget<Text>(find.descendant(
          of: find.byKey(const ValueKey('pdp-sale-line')),
          matching: find.text('₹58.20')));
      expect(amount.style?.color, Brand.price);
    });

    testWidgets('without the block an older backend still gets the '
        'CHANGE #638 single price', (tester) async {
      await _pump(tester, _payload());
      expect(find.text('₹2,597.00'), findsWidgets);
      expect(find.text('On quote'), findsNothing);
      expect(find.byKey(const ValueKey('pdp-sale-line')), findsNothing);
    });
  });

  group('nothing about sourcing leaks (CMD #1826)', () {
    testWidgets('no supplier name or supplier count appears anywhere in the '
        'rendered page', (tester) async {
      await _pump(
          tester,
          _payload(
            hasSupplierLabel: false,
            supply: _contraryBand,
            priceLines: _pricedLines,
          ));

      final rendered = tester
          .widgetList<Text>(find.byType(Text, skipOffstage: false))
          .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
          .join('\n');
      expect(rendered, isNot(contains('Zydus Distributors')));
      expect(rendered, isNot(contains('Apex Pharma')));
      expect(RegExp(r'\b\d+\s+(supplier|source)s?\b', caseSensitive: false)
              .hasMatch(rendered),
          isFalse,
          reason: 'a number of suppliers is a promise the page never makes');
      expect(find.text('3'), findsNothing,
          reason: 'the decoy supplier_count:3 must not surface as text');
      expect(rendered, isNot(contains('supplier_count')));
    });
  });

  group('the CMD #1826 parser', () {
    test('supply and price_lines carry the payload through untouched', () {
      final s = PdSupply.fromMap(_contraryBand);
      expect(s.has, isTrue);
      expect(s.band, 'green');
      expect(s.tone, 'danger');
      expect(s.label, 'Checked recently, not confirmed');
      expect(s.hasSpeed, isFalse);

      final pl = PdPriceLines.fromMap(_pricedLines);
      expect(pl.has, isTrue);
      expect(pl.sale.value, '₹58.20');
      expect(pl.sale.hasAmount, isTrue);
      expect(pl.mrp.hasAmount, isTrue);
      expect(pl.sticky.side, 'MRP ₹69.96');
    });

    test('absence parses to has:false with nothing invented', () {
      expect(PdSupply.fromMap(null).has, isFalse);
      expect(PdSupply.fromMap(const {'has': false, 'label': 'x'}).label, '');
      expect(PdPriceLines.fromMap(null).has, isFalse);
      expect(PdPriceLines.fromMap(const {'has': false}).sale.value, '');
      final d = ProductDetail.fromMap(_payload());
      expect(d.supply.has, isFalse);
      expect(d.priceLines.has, isFalse);
    });
  });
}
