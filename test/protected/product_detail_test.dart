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
  bool hasHistory = false,
  List<Map<String, dynamic>> similar = const [],
}) =>
    {
      'ok': true,
      'id': 176026,
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
      'availability': {
        'is_available': true,
        'can_add': true,
        'cta_label': 'Add to cart',
        'gated': true,
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
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
        ),
      ),
    ),
  );
  // One extra pump to let the loader's Future resolve into setState.
  await tester.pumpAndSettle();
}

void main() {
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

      // The price row and the sticky buy bar both show the price, and both
      // print the same two payload strings rather than reformatting them.
      expect(find.text('₹2,597.00'), findsNWidgets(2),
          reason: 'mrp_label verbatim, in the price row and the sticky bar');
      expect(find.text('MRP'), findsNWidgets(2), reason: 'mrp_note verbatim');
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

    testWidgets('rx_required gates the Rx banner and uses the backend wording',
        (tester) async {
      await _pump(tester, _payload());
      expect(find.text('Prescription required'), findsNothing);

      await _pump(tester, _payload(rxRequired: true));
      expect(find.text('Prescription required'), findsOneWidget);
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
  });
}
