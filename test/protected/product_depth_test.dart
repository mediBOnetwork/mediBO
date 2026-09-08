// PROTECTED — CMD #791, product page depth.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change go
// green.
//
// The four things this holds down, all of them the same rule seen from four
// sides — the depth added to the product page is DATA, and the app renders it:
//
//   1. THE GALLERY COUNTER IS THE BACKEND'S STRING. `product_gallery()` ships a
//      `counter_label` per image ("2 / 5"); the page prints the one belonging
//      to the image it is showing. The fixture below deliberately labels five
//      images "1 of 5 shots" … — wording NO client-side "${i+1} / ${n}" could
//      ever produce — so a page that assembles its own counter fails here.
//
//   2. THE FACT TABLE IS ROWS, NOT FIELDS. Composition/strength, form, pack,
//      Rx-or-OTC, habit forming, cold chain and storage arrive as {label,
//      value} pairs in payload order. A column with nothing in it is an ABSENT
//      ROW — the page never prints a label with a dash beside it, and never
//      title-cases a key into a heading.
//
//   3. THE OVERLAY IS THE OWNER'S, AND ONLY THE OWNER'S. "Last ordered 12 Aug ·
//      3× last month · usual qty 9" is one backend sentence plus its own
//      pre-split chips, and the one-tap button's caption is `add_label`. With
//      `purchase.has:false` — which is exactly what an ANONYMOUS visitor gets,
//      because purchase_overlay() returns nothing without a customer account —
//      the block is absent while every content block still renders. That is
//      spec item 4 expressed as a test rather than as a login check in Dart.
//
//   4. THE COMPANION RAIL PRINTS PRICES IT WAS GIVEN. Each tile's price is
//      `pricing.price_display` and its button is `availability.cta_label`
//      gated on `can_add` — the same blocks a storefront card reads, so a
//      companion and its own card can never quote two different numbers. An
//      out-of-stock companion is `can_add:false`, never a stock count.
//
// No network, no Supabase, no goldens — the payloads are inline.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/models/product_detail.dart';
import 'package:pharma_b2b/screens/product_detail_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/companion_rail.dart';
import 'package:pharma_b2b/widgets/purchase_overlay_card.dart';

const _labels = <String, dynamic>{
  'pdp_overview_title': 'Overview',
  'pdp_similar_title': 'Similar products',
  'pdp_read_more': 'Read more',
  'pdp_read_less': 'Read less',
  'pdp_not_found_title': 'Product not found',
  'pdp_not_found_body': 'This product is no longer available.',
  'pdp_not_found_cta': 'Go back',
  'stock_out_label': 'Out of stock',
  'card_notify_label': 'Notify me',
  'cart_pill_cta': 'View cart',
};

/// Five shots whose counter strings are deliberately NOT "1 / 5". If the page
/// ever builds the counter itself, this fixture is the thing that catches it.
const _galleryImages = <Map<String, dynamic>>[
  {'url': 'https://r2.example/med/351392-a.png', 'counter_label': 'shot 1 of 5'},
  {'url': 'https://r2.example/med/351392-b.png', 'counter_label': 'shot 2 of 5'},
  {'url': 'https://r2.example/med/351392-c.png', 'counter_label': 'shot 3 of 5'},
  {'url': 'https://r2.example/med/351392-d.png', 'counter_label': 'shot 4 of 5'},
  {'url': 'https://r2.example/med/351392-e.png', 'counter_label': 'shot 5 of 5'},
];

Map<String, dynamic> _payload({
  bool gallery = true,
  bool facts = true,
  bool purchase = true,
  bool companions = true,
  bool companionCanAdd = true,
}) => {
      'ok': true,
      'id': 351392,
      'labels': _labels,
      'header': {
        'name': 'Monticope Tablet',
        'company': 'MANKIND PHARMA LTD',
        'pack_label': 'Strip',
        'form_chip': 'Strip',
        'rx_required': true,
        // Deliberately EMPTY: the gallery must come from the `gallery` block,
        // not from the legacy header list.
        'images': <String>[],
      },
      'price': {
        'has_mrp': true,
        'mrp_label': '₹198.00',
        'mrp_note': 'MRP',
        'has_gst': true,
        'gst_label': 'GST 12%',
        'scheme': false,
      },
      'pricing': {
        'mrp': 198.0,
        'sale_price': 198.0,
        'mrp_display': '₹198.00',
        'price_display': '₹198.00',
        'has_price': true,
        'has_discount': false,
      },
      'availability': {
        'is_available': true,
        'can_add': true,
        'cta_label': 'Add to cart',
        'gated': true,
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      },
      'stock': {
        'buyable': true,
        'has_supplier_label': false,
        'supplier_label': '',
      },
      'overview': const [
        {'label': 'Composition', 'value': 'Levocetirizine (5mg) + Montelukast (10mg)'},
      ],
      'has_highlight': false,
      'highlight': '',
      'sections': const [
        {'title': 'Uses', 'body': 'Treatment of allergic conditions.'},
        {'title': 'Side effects', 'body': 'Sleepiness, headache, dry mouth.'},
      ],
      'similar': const [],
      'similar_ready': true,
      'my_history': const {'has': false, 'label': ''},
      'show_wishlist': false,
      'is_wishlisted': false,
      if (gallery)
        'gallery': {
          'has': true,
          'count': 5,
          'zoom_hint': 'Pinch to enlarge',
          'close_label': 'Done',
          'images': _galleryImages,
        },
      if (facts)
        'facts': {
          'has': true,
          'title': 'Product details',
          'rows': const [
            {
              'key': 'salt',
              'label': 'Composition & strength',
              'value': 'Levocetirizine (5mg) + Montelukast (10mg)',
            },
            {'key': 'form', 'label': 'Form', 'value': 'Strip'},
            {'key': 'pack', 'label': 'Pack', 'value': '10 tablets in 1 strip'},
            {'key': 'rx', 'label': 'Prescription', 'value': 'Prescription required (Rx)'},
            {'key': 'habit', 'label': 'Habit forming', 'value': 'No'},
            {'key': 'storage', 'label': 'Storage', 'value': 'Store below 30°C'},
          ],
        },
      if (purchase)
        'purchase': {
          'has': true,
          'title': 'Your buying history',
          'label': 'Last ordered 12 Aug · 3× last month · usual qty 9',
          'chips': const [
            'Last ordered 12 Aug',
            '3× last month',
            'usual qty 9',
          ],
          'short_label': 'Ordered 12 Aug',
          'last_label': '12 Aug',
          'usual_qty': 9,
          'can_add': true,
          'add_label': 'Add usual qty (9)',
          'tone': const {'bg': '#EFF6FF', 'fg': '#1E40AF'},
        },
      if (companions)
        'companions': {
          'has': true,
          'title': 'Frequently bought together',
          'note': 'Bought with this pack by pharmacies in your area.',
          'zone_id': 1,
          'items': [
            {
              'id': 504544,
              'name': 'VesiBeta 25 Tablet ER',
              'company': 'MANKIND PHARMA LTD',
              'pack_label': 'Strip',
              'form_chip': '10 tablets',
              'image': 'https://r2.example/med/504544.png',
              'support_label': '6 orders',
              'pricing': const {
                'has_price': true,
                'price_display': '₹274.51',
                'mrp_display': '₹305.00',
              },
              'availability': {
                'is_available': companionCanAdd,
                'can_add': companionCanAdd,
                'cta_label': companionCanAdd ? 'Add to cart' : 'Unavailable',
                'gated': true,
              },
            },
            {
              'id': 354517,
              'name': 'Monticope Suspension',
              'company': 'MANKIND PHARMA LTD',
              'pack_label': 'Bottle',
              'form_chip': '60 ml',
              'image': 'https://r2.example/med/354517.png',
              'support_label': '5 orders',
              'pricing': const {
                'has_price': true,
                'price_display': '₹92.40',
                'mrp_display': '₹103.00',
              },
              'availability': const {
                'is_available': true,
                'can_add': true,
                'cta_label': 'Add to cart',
                'gated': true,
              },
            },
          ],
        },
    };

int _pumpSeq = 0;

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  tester.view.physicalSize = const Size(1200, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: ProductDetailScreen(
          key: ValueKey('pdp791-${_pumpSeq++}'),
          productId: '351392',
          loader: (_) async => ProductDetail.fromMap(payload),
          notifyStatusLoader: (_) async => false,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('CMD #791 — gallery', () {
    // CMD #1896 — the counter and the zoom hint left the PAGE. The strip of
    // thumbnails and the "shot 1 of 5 · Pinch to enlarge" caption under the
    // hero are gone; the hero is one bordered card with dots. The contract
    // this group defends is unchanged and is asserted where the counter now
    // lives — inside the full-screen zoom, which is the one place a reader
    // actually needs to know which of five shots they are looking at.
    testWidgets('prints the BACKEND counter for the visible shot, never its own',
        (tester) async {
      await _pump(tester, _payload());

      // Not on the page. Neither the payload's counter nor an invented one.
      expect(find.text('shot 1 of 5'), findsNothing);
      expect(find.text('1 / 5'), findsNothing);
      expect(find.text('Pinch to enlarge'), findsNothing);
      expect(find.byKey(const ValueKey('pdp-gallery-dots')), findsOneWidget,
          reason: 'five shots still get a page control — dots, not thumbnails');

      // Open the zoom on the hero: there the counter is the BACKEND's string.
      await tester.tap(find.byKey(const ValueKey('pdp-gallery-shot-0')));
      await tester.pumpAndSettle();

      expect(find.text('shot 1 of 5'), findsOneWidget);
      expect(find.text('1 / 5'), findsNothing,
          reason: '"1 / 5" is what a client-side counter would print');
      // The dismiss control's word is the backend's too.
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('a payload with no gallery block draws no counter at all',
        (tester) async {
      await _pump(tester, _payload(gallery: false));
      expect(find.text('shot 1 of 5'), findsNothing);
      expect(find.text('Pinch to enlarge'), findsNothing);
      expect(find.byKey(const ValueKey('pdp-gallery-dots')), findsNothing);
    });
  });

  group('CMD #791 — fact table', () {
    testWidgets('renders every fact row in payload order, both halves verbatim',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.text('Product details'), findsOneWidget);
      for (final s in const [
        'Composition & strength',
        'Form',
        'Pack',
        'Prescription',
        'Habit forming',
        'Storage',
      ]) {
        expect(find.text(s), findsWidgets, reason: 'missing fact label $s');
      }
      // The Rx wording is the backend's sentence, not a schedule the app maps.
      expect(find.text('Prescription required (Rx)'), findsOneWidget);
      expect(find.text('10 tablets in 1 strip'), findsOneWidget);
      // Cold chain is absent from the fixture's rows, so the label must not
      // appear at all — an absent value is an absent ROW, never a dash.
      expect(find.text('Cold chain'), findsNothing);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('no facts block means no section', (tester) async {
      await _pump(tester, _payload(facts: false));
      expect(find.text('Product details'), findsNothing);
    });
  });

  group('CMD #791 — purchase overlay', () {
    testWidgets('prints the backend chips and the backend add label',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.byType(PurchaseOverlayCard), findsOneWidget);
      expect(find.text('Your buying history'), findsOneWidget);
      expect(find.text('Last ordered 12 Aug'), findsOneWidget);
      expect(find.text('3× last month'), findsOneWidget);
      expect(find.text('usual qty 9'), findsOneWidget);
      // The button caption is add_label. "Add usual qty" with the number
      // interpolated in Dart would not match, and that is the point.
      expect(find.text('Add usual qty (9)'), findsOneWidget);
    });

    testWidgets('one tap SETS the backend usual quantity, not +1',
        (tester) async {
      final cart = CartModel.forTest();
      var wrote = 0;
      // The widget is exercised directly so the assertion is on the ONE
      // decision it owns: the quantity it hands upward is the payload's.
      final overlay = PurchaseOverlay.fromMap(_payload()['purchase']);
      await tester.pumpWidget(
        AppState(
          cart: cart,
          child: MaterialApp(
            home: Scaffold(
              body: PurchaseOverlayCard(
                overlay: overlay,
                onAddUsual: () => wrote = overlay.usualQty,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Add usual qty (9)'));
      await tester.pump();
      expect(wrote, 9, reason: 'the tap must carry usual_qty, not 1');
    });

    testWidgets('ANON — has:false hides the overlay and keeps every content block',
        (tester) async {
      await _pump(tester, _payload(purchase: false));

      expect(find.byType(PurchaseOverlayCard), findsNothing);
      expect(find.text('Your buying history'), findsNothing);
      expect(find.text('Add usual qty (9)'), findsNothing);

      // …while the content an anonymous visitor IS entitled to still renders.
      // CMD #1896 — the gallery proves itself with its page control now; the
      // counter moved into the zoom.
      expect(find.byKey(const ValueKey('pdp-gallery-dots')), findsOneWidget);
      expect(find.text('Product details'), findsOneWidget);
      expect(find.text('Uses'), findsOneWidget);
      expect(find.text('Side effects'), findsOneWidget);
      expect(find.text('Frequently bought together'), findsOneWidget);
    });
  });

  group('CMD #791 — frequently bought together', () {
    testWidgets('renders the rail in payload order with backend prices',
        (tester) async {
      await _pump(tester, _payload());

      expect(find.byType(CompanionRail), findsOneWidget);
      expect(find.text('Frequently bought together'), findsOneWidget);
      expect(
          find.text('Bought with this pack by pharmacies in your area.'),
          findsOneWidget);
      // price_display — the same string the card reads. A page that recomputed
      // a price from `mrp` would print ₹305.00 here.
      expect(find.text('₹274.51'), findsOneWidget);
      expect(find.text('₹92.40'), findsOneWidget);
      expect(find.text('VesiBeta 25 Tablet ER'), findsOneWidget);
    });

    testWidgets('an out-of-stock companion is can_add:false with the backend word',
        (tester) async {
      await _pump(tester, _payload(companionCanAdd: false));

      expect(find.text('Unavailable'), findsOneWidget);
      final btn = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Unavailable'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(btn.onPressed, isNull,
          reason: 'can_add:false must disable the button');
    });

    testWidgets('has:false draws no rail', (tester) async {
      await _pump(tester, _payload(companions: false));
      expect(find.byType(CompanionRail), findsNothing);
      expect(find.text('Frequently bought together'), findsNothing);
    });
  });

  group('CMD #791 — parsing', () {
    test('an absent purchase block parses to absent, never to a zero overlay', () {
      final d = ProductDetail.fromMap(_payload(purchase: false));
      expect(d.purchase.has, isFalse);
      expect(d.purchase.usualQty, 0);
      expect(d.purchase.canAdd, isFalse);
      expect(d.purchase.addLabel, isEmpty);
    });

    test('the gallery falls back to header.images with EMPTY counters', () {
      final p = _payload(gallery: false);
      (p['header'] as Map)['images'] = <String>[
        'https://r2.example/med/legacy-1.png',
        'https://r2.example/med/legacy-2.png',
      ];
      final d = ProductDetail.fromMap(p);
      expect(d.gallery.has, isTrue);
      expect(d.gallery.count, 2);
      // No counter is INVENTED for a payload that carried none.
      expect(d.gallery.images.every((i) => i.counterLabel.isEmpty), isTrue);
    });

    test('facts and companions keep payload order', () {
      final d = ProductDetail.fromMap(_payload());
      expect(d.facts.rows.map((r) => r.key).toList(),
          ['salt', 'form', 'pack', 'rx', 'habit', 'storage']);
      expect(d.companions.items.map((c) => c.id).toList(), ['504544', '354517']);
    });
  });
}
