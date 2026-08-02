// PROTECTED — CHANGE #638.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes company-page, stock-notify or PDP-price behaviour.
//
// What this holds down:
//
//   1. The company page renders the backend's label and count_label verbatim,
//      and pages by OFFSET while the backend says has_more. Appending must
//      never duplicate a product — a repeated offset near a boundary, or a
//      shifting sort, would otherwise paint the same card twice.
//
//   2. company_not_found is an empty state, not a crash.
//
//   3. An out-of-stock card offers Notify. The tap sends stock_notify_request
//      and then renders THAT RESPONSE: the toast is printed verbatim and the
//      control flips to the subscribed label. The app invents neither string,
//      and it does not decide it is subscribed — the RPC says so.
//
//   4. The back-in-stock strip renders the payload's own title and cards, and
//      reports exactly the ids it showed to stock_notify_seen so it clears
//      next visit.
//
//   5. PDP PRICE UNIFICATION. The page prints pricing.price_display — the same
//      block every card reads — not price.mrp_label. Before #638 those were
//      two renderings of one number with nothing keeping them equal; the first
//      real discount would have made the page and the card disagree.
//
// Fixtures mirror real payloads taken off the live database on 2026-08-02.
// No network, no Supabase, no camera, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/data/storefront_labels.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/home_sections.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/models/product_detail.dart';
import 'package:pharma_b2b/models/storefront_p3.dart';
import 'package:pharma_b2b/screens/company_screen.dart';
import 'package:pharma_b2b/screens/product_detail_screen.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';
import 'package:pharma_b2b/widgets/home_sections_view.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _card({
  required int id,
  required String name,
  bool available = true,
  String ctaLabel = 'Add to cart',
  String priceDisplay = '₹85.31',
}) =>
    {
      'id': id,
      'name': name,
      'company': 'SUN PHARMACEUTICAL INDUSTRIES LTD',
      'pack_label': '',
      'form_chip': 'Tube',
      'image': '',
      'mrp_label': priceDisplay,
      'buyable': true,
      'availability': {
        'is_available': available,
        'can_add': available,
        'gated': false,
        'cta_label': ctaLabel,
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      },
      'pricing': {
        'mrp': 85.31,
        'sale_price': 85.31,
        'discount_pct': 0,
        'mrp_display': priceDisplay,
        'price_display': priceDisplay,
        'discount_label': '',
        'has_price': true,
        'has_discount': false,
      },
    };

Map<String, dynamic> _companyPage({
  required int offset,
  required List<Map<String, dynamic>> items,
  required bool hasMore,
}) =>
    {
      'ok': true,
      'company': {
        'label': 'SUN PHARMACEUTICAL INDUSTRIES LTD',
        'key': 'sun pharmaceutical industries',
        'count_label': '2,510 products',
      },
      'items': items,
      'offset': offset,
      'has_more': hasMore,
    };

Future<void> _pumpCompany(
  WidgetTester tester,
  CompanyPageLoader loader, {
  // Short by default so the grid actually overflows and can be scrolled —
  // a viewport taller than the content has maxScrollExtent 0 and would make
  // "paging never fired" look like a pass.
  Size size = const Size(400, 700),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: CompanyScreen(
          companyKey: 'sun pharmaceutical industries',
          loader: loader,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    CartModel.rpcTransport = (fn, params) async =>
        {'ok': true, 'message': '', 'cart': <String, dynamic>{}};
    StorefrontLabels.seed({
      'card_notify_label': 'Notify me',
      'notify_subscribed_label': "We'll notify you",
      'stock_out_label': 'Out of stock',
    });
  });
  tearDown(() {
    CartModel.rpcTransport = null;
    StorefrontLabels.reset();
  });

  // ── Part A ────────────────────────────────────────────────────────────────
  group('company page', () {
    testWidgets('renders label and count_label verbatim', (tester) async {
      await _pumpCompany(
        tester,
        (key, offset) async => CompanyPage.fromMap(_companyPage(
          offset: 0,
          items: [_card(id: 1, name: 'Diprovate Plus G Cream')],
          hasMore: false,
        )),
      );

      // Title appears in the app bar AND the body header, both from the payload.
      expect(find.text('SUN PHARMACEUTICAL INDUSTRIES LTD'), findsNWidgets(2));
      expect(find.text('2,510 products'), findsOneWidget);
      expect(find.text('Diprovate Plus G Cream'), findsOneWidget);
    });

    testWidgets('paging appends the next offset without duplicating',
        (tester) async {
      final requested = <int>[];

      // Page one must be long enough to overflow the viewport, otherwise
      // there is nothing to scroll and "paging never fired" would pass.
      await _pumpCompany(tester, (key, offset) async {
        requested.add(offset);
        if (offset == 0) {
          return CompanyPage.fromMap(_companyPage(
            offset: 0,
            items: [
              for (var i = 1; i <= 8; i++) _card(id: i, name: 'Product $i'),
            ],
            hasMore: true,
          ));
        }
        // Page two deliberately REPEATS id 8 — the boundary case.
        return CompanyPage.fromMap(_companyPage(
          offset: offset,
          items: [
            _card(id: 8, name: 'Product 8'),
            _card(id: 9, name: 'Product 9'),
          ],
          hasMore: false,
        ));
      });

      expect(find.text('Product 1'), findsOneWidget);

      // Drive the scroll to the end to trigger the next page.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();

      expect(requested, [0, 8], reason: 'second call asks for offset 8');
      expect(find.text('Product 9'), findsOneWidget);
      expect(find.text('Product 8'), findsOneWidget,
          reason: 'the repeated product must appear ONCE, not twice');
    });

    testWidgets('stops paging when the backend says has_more:false',
        (tester) async {
      var calls = 0;
      await _pumpCompany(tester, (key, offset) async {
        calls++;
        return CompanyPage.fromMap(_companyPage(
          offset: 0,
          items: [_card(id: 1, name: 'Only One')],
          hasMore: false,
        ));
      });

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await tester.pumpAndSettle();

      expect(calls, 1, reason: 'has_more:false ends paging — never a page size guess');
    });

    testWidgets('company_not_found renders an empty state, not a crash',
        (tester) async {
      await _pumpCompany(
        tester,
        (key, offset) async =>
            CompanyPage.fromMap({'ok': false, 'error': 'company_not_found'}),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('2,510 products'), findsNothing);
      expect(find.byIcon(Icons.storefront_outlined), findsOneWidget);
    });

    test('has_more is the backend flag, never items.length == limit', () {
      final exact = CompanyPage.fromMap(_companyPage(
        offset: 0,
        items: List.generate(24, (i) => _card(id: i, name: 'P$i')),
        hasMore: false,
      ));
      expect(exact.items.length, 24);
      expect(exact.hasMore, isFalse,
          reason: 'a full page with has_more:false is the LAST page');
    });
  });

  // ── Part B ────────────────────────────────────────────────────────────────
  group('notify on an out-of-stock card', () {
    Future<List<String>> pumpCard(
      WidgetTester tester, {
      required NotifyResult response,
    }) async {
      final asked = <String>[];
      await tester.pumpWidget(
        AppState(
          cart: CartModel.forTest(),
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 200,
                height: CompactProductCard.extent,
                child: CompactProductCard(
                  product: Product.fromHomeCard(_card(
                    id: 77,
                    name: 'Sold Out Cream',
                    available: false,
                    ctaLabel: 'Unavailable',
                  )),
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return asked;
    }

    testWidgets('an out-of-stock card shows the backend Notify label',
        (tester) async {
      await pumpCard(tester, response: NotifyResult.failed);

      expect(find.text('Notify me'), findsOneWidget,
          reason: 'card_notify_label, from storefront_ui_label');
      expect(find.text('Unavailable'), findsOneWidget,
          reason: 'the sold-out chip is still the backend cta_label');
    });

    testWidgets('an in-stock card shows no Notify control', (tester) async {
      await tester.pumpWidget(
        AppState(
          cart: CartModel.forTest(),
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 200,
                height: CompactProductCard.extent,
                child: CompactProductCard(
                  product: Product.fromHomeCard(_card(id: 1, name: 'In Stock')),
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Notify me'), findsNothing);
      expect(find.text('Add to cart'), findsOneWidget);
    });
  });

  // ── Part B, via the product page (which owns the request seam) ────────────
  group('notify on the product page', () {
    Map<String, dynamic> pdp({required bool canAdd}) => {
          'ok': true,
          'id': 77,
          'labels': {
            'card_notify_label': 'Notify me',
            'notify_subscribed_label': "We'll notify you",
            'stock_out_label': 'Out of stock',
            'pdp_overview_title': 'Overview',
          },
          'header': {
            'name': 'Sold Out Cream',
            'company': 'SUN',
            'pack_label': '',
            'form_chip': 'Tube',
            'rx_required': false,
            'images': <String>[],
          },
          'price': {
            'has_mrp': true,
            'mrp_label': '₹999.00',
            'mrp_note': 'MRP',
            'has_gst': true,
            'gst_label': 'GST 12%',
            'scheme': false,
          },
          'availability': {
            'is_available': canAdd,
            'can_add': canAdd,
            'gated': true,
            'cta_label': canAdd ? 'Add to cart' : 'Unavailable',
            'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
          },
          'pricing': {
            'mrp': 85.31,
            'sale_price': 85.31,
            'discount_pct': 0,
            'mrp_display': '₹85.31',
            'price_display': '₹85.31',
            'discount_label': '',
            'has_price': true,
            'has_discount': false,
          },
          'stock': {
            'buyable': canAdd,
            'has_supplier_label': false,
            'supplier_label': '',
          },
          'overview': <dynamic>[],
          'sections': <dynamic>[],
          'similar': <dynamic>[],
          'has_highlight': false,
          'highlight': '',
          'my_history': {'has': false, 'label': ''},
        };

    Future<List<String>> pumpPdp(
      WidgetTester tester, {
      required bool canAdd,
      bool alreadySubscribed = false,
      NotifyResult? response,
    }) async {
      final asked = <String>[];
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        AppState(
          cart: CartModel.forTest(),
          child: MaterialApp(
            home: ProductDetailScreen(
              productId: '77',
              loader: (_) async => ProductDetail.fromMap(pdp(canAdd: canAdd)),
              notifyStatusLoader: (_) async => alreadySubscribed,
              notifyRequest: (id) async {
                asked.add(id);
                return response ?? NotifyResult.failed;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return asked;
    }

    testWidgets('tap sends the request, prints the toast verbatim and flips '
        'to subscribed', (tester) async {
      final asked = await pumpPdp(
        tester,
        canAdd: false,
        response: const NotifyResult(
          ok: true,
          subscribed: true,
          toast: 'We will notify you once stock is available',
          error: '',
        ),
      );

      expect(find.text('Notify me'), findsOneWidget);

      await tester.tap(find.text('Notify me'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(asked, ['77'], reason: 'stock_notify_request with the product id');
      expect(find.text('We will notify you once stock is available'),
          findsOneWidget,
          reason: "the RPC's own toast, printed verbatim");

      await tester.pumpAndSettle();
      expect(find.text("We'll notify you"), findsOneWidget,
          reason: 'the control flips to the backend subscribed label');
      expect(find.text('Notify me'), findsNothing);

      // The toast auto-dismisses after 4s; drain it so the test does not end
      // with a live timer.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('an already-subscribed viewer sees the subscribed state on load',
        (tester) async {
      await pumpPdp(tester, canAdd: false, alreadySubscribed: true);

      expect(find.text("We'll notify you"), findsOneWidget,
          reason: 'stock_notify_status decided this, not the app');
      expect(find.text('Notify me'), findsNothing);
    });

    testWidgets('a buyable product shows Add to cart, never Notify',
        (tester) async {
      await pumpPdp(tester, canAdd: true);

      expect(find.text('Add to cart'), findsOneWidget);
      expect(find.text('Notify me'), findsNothing);
    });

    // ── Part D ──────────────────────────────────────────────────────────────
    testWidgets('PDP price is pricing.price_display, NOT price.mrp_label',
        (tester) async {
      await pumpPdp(tester, canAdd: true);

      expect(find.text('₹85.31'), findsWidgets,
          reason: 'the same block every card reads');
      expect(find.text('₹999.00'), findsNothing,
          reason: 'price.mrp_label is no longer the headline — one price '
              'source everywhere');
      expect(find.text('GST 12%'), findsOneWidget, reason: 'gst chip stays');
    });
  });

  // ── Part C ────────────────────────────────────────────────────────────────
  group('back-in-stock strip', () {
    Map<String, dynamic> sectionsPayload() => {
          'ok': true,
          'sections': [
            {
              'id': 'best_sellers',
              'layout': 'rail',
              'title': 'Best Sellers',
              'accent_word': 'Best',
              'subtitle': 'MOST ORDERED ON MEDIBO',
              'see_all': null,
              'items': [_card(id: 500, name: 'A Best Seller')],
            },
          ],
        };

    Future<List<List<int>>> pumpFeed(
      WidgetTester tester,
      BackInStock strip,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      HomeSectionsView.resetMemo();
      addTearDown(HomeSectionsView.resetMemo);

      final seen = <List<int>>[];
      await tester.pumpWidget(
        AppState(
          cart: CartModel.forTest(),
          child: MaterialApp(
            home: Scaffold(
              body: HomeSectionsView(
                loader: () async => HomeSections.fromMap(sectionsPayload()),
                notificationsLoader: () async => strip,
                onSeen: (ids) async => seen.add(ids),
                onCategoryTap: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return seen;
    }

    testWidgets('renders the payload title and cards ABOVE Best Sellers',
        (tester) async {
      await pumpFeed(
        tester,
        BackInStock.fromMap({
          'ok': true,
          'title': 'Back in stock',
          'items': [_card(id: 900, name: 'Returned Product')],
        }),
      );

      expect(find.text('Back in stock'), findsOneWidget);
      expect(find.text('Returned Product'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Back in stock')).dy,
        lessThan(tester.getTopLeft(find.text('Best Sellers')).dy),
        reason: 'the strip sits above Best Sellers',
      );
    });

    testWidgets('reports exactly the ids it showed to stock_notify_seen',
        (tester) async {
      final seen = await pumpFeed(
        tester,
        BackInStock.fromMap({
          'ok': true,
          'title': 'Back in stock',
          'items': [
            _card(id: 900, name: 'Returned One'),
            _card(id: 901, name: 'Returned Two'),
          ],
        }),
      );

      expect(seen, [
        [900, 901]
      ], reason: 'the ids on screen, exactly once');
    });

    testWidgets('no strip and no seen call when the payload is empty',
        (tester) async {
      final seen = await pumpFeed(tester, BackInStock.empty);

      expect(find.text('Back in stock'), findsNothing);
      expect(seen, isEmpty,
          reason: 'nothing was shown, so nothing was seen');
      expect(find.text('Best Sellers'), findsOneWidget,
          reason: 'the rest of the feed is unaffected');
    });
  });

  // ── model-level guards ────────────────────────────────────────────────────
  group('parsers', () {
    test('BackInStock.show is false unless the backend sent products', () {
      expect(BackInStock.fromMap({'ok': true, 'title': 'x', 'items': []}).show,
          isFalse);
      expect(BackInStock.empty.show, isFalse);
    });

    test('login_required is the one error the app acts on', () {
      const r = NotifyResult(
          ok: false, subscribed: false, toast: '', error: 'login_required');
      expect(r.loginRequired, isTrue);
      const other = NotifyResult(
          ok: false, subscribed: false, toast: '', error: 'not_found');
      expect(other.loginRequired, isFalse);
    });

    test('company_not_found is distinguishable from a transport failure', () {
      expect(
          CompanyPage.fromMap({'ok': false, 'error': 'company_not_found'})
              .notFound,
          isTrue);
      expect(CompanyPage.failed.notFound, isFalse);
    });
  });
}
