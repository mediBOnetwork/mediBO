// PROTECTED — CMD #2140, Bulk Upload v4.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change pass.
//
// What this holds down:
//   1. The Bulk Upload review row is THREE lines — name, composition, and the
//      sale-price badge with the Available/Unavailable badge beside it on the
//      same line — and the photo is exactly those three lines tall. The cart's
//      three-line row (a 44px control beside the price) keeps its own height.
//   2. A shell page host clears the bottom chrome for EVERY tab, customer tabs
//      included: the last item of a page (e.g. "Add matched to cart") ends
//      above the bar and above the floating View cart pill, and the pill sits
//      above the bar. An end-of-list spacer inside that host does not count
//      the chrome a second time.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/bottom_stack.dart';
import 'package:pharma_b2b/widgets/product_row_card.dart';
import 'package:pharma_b2b/widgets/update_bar.dart';

Product _p() => Product.fromJson(const {
      'id': 'p1',
      'name': 'Erafenac 100mg/325mg Tablet',
      'image_url': '',
    });

const _barPayload = <String, dynamic>{
  'show': true,
  'platform': 'android',
  'label': 'Registration pending',
  'button_label': 'Continue',
  'updating_label': 'Continue',
  'downloaded_label': 'Continue',
  'bottom_gap': 128,
};

Map<String, dynamic> _cartPayload(bool show) => {
      'items': const [],
      'item_count': 0,
      'render': {
        'pill': {
          'show': show,
          'identifier': 'cart_pill',
          'items_label': '23 items',
          'cta': 'View cart',
          'lines': const [
            {'key': 'cta', 'text': 'View cart'},
            {'key': 'count', 'text': '23 items'},
          ],
          'thumbs': const [],
          'thumb_count': 0,
          'has_more': false,
          'more_label': '',
          'a11y': 'View cart, 23 items',
        },
      },
    };

Future<CartModel> _cart(bool show) async {
  CartModel.rpcTransport = (fn, params) async => _cartPayload(show);
  final c = CartModel.forTest();
  await c.refresh();
  return c;
}

const double _navHeight = 64;
const _lastRow = Key('c2140_last_row');

Widget _shell(CartModel cart, {required bool pill, bool withSpacer = false}) =>
    MaterialApp(
      home: Scaffold(
        bottomNavigationBar: const SizedBox(height: _navHeight),
        body: AppState(
          cart: cart,
          child: Stack(children: [
            Column(children: [
              Expanded(
                child: shellPageHost(
                  ListView(children: [
                    const SizedBox(height: 2000),
                    const SizedBox(
                        key: _lastRow, height: 48, child: Text('Add matched')),
                    if (withSpacer) const BottomStackSpacer(),
                  ]),
                  staff: false,
                  pill: pill,
                ),
              ),
            ]),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: StorefrontBottomStack(onCartTap: () {}, showPill: pill),
            ),
          ]),
        ),
      ),
    );

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(360, 800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(w);
  await t.pumpAndSettle();
}

Future<Rect> _scrollToEnd(WidgetTester t) async {
  await t.drag(find.byType(ListView), const Offset(0, -4000));
  await t.pumpAndSettle();
  return t.getRect(find.byKey(_lastRow));
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(const {});
  });
  tearDown(() {
    CartModel.rpcTransport = null;
    appUpdateBar.reset();
  });

  group('1. the bulk review row is three lines', () {
    testWidgets('name, composition, price + state badge on ONE line; photo '
        '= three lines', (t) async {
      await t.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProductRowCard(
            surface: 'bulk',
            product: _p(),
            name: 'Erafenac 100mg/325mg Tablet',
            line2: 'Aceclofenac (100mg) + Paracetamol (325mg)',
            price: const RowPriceBadge(label: 'Sale price:', value: 'PTR'),
            line4: const RowStateBadge(label: 'Unavailable', available: false),
            inlineControl: true,
          ),
        ),
      ));
      expect(find.text('Aceclofenac (100mg) + Paracetamol (325mg)'),
          findsOneWidget);
      final price = t.getCenter(find.text('PTR'));
      final badge = t.getCenter(find.text('Unavailable'));
      expect((price.dy - badge.dy).abs(), lessThan(1.0),
          reason: 'the availability badge sits beside the price, not below');
      expect(badge.dx, greaterThan(price.dx));
      final side = ProductRowCard.threeLineHeight();
      expect(side, ProductRowCard.lineH * 3);
      expect(t.getSize(find.byType(RowThumb)).height, side);
      final thumb = t.getRect(find.byType(RowThumb));
      expect(t.getRect(find.text('Unavailable')).bottom,
          lessThanOrEqualTo(thumb.bottom + 0.5),
          reason: 'no fourth line below the photo');
      expect(t.takeException(), isNull);
    });

    testWidgets('the cart keeps its 44px control line', (t) async {
      expect(ProductRowCard.threeLineHeight(controlLine: true),
          greaterThan(ProductRowCard.threeLineHeight()));
    });
  });

  group('2. every tab ends above the chrome', () {
    testWidgets('with the bar up, the last item clears the bar', (t) async {
      final cart = await _cart(false);
      await _pump(t, _shell(cart, pill: false));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      final row = await _scrollToEnd(t);
      final bar = t.getRect(find.byType(UpdateBar));
      expect(row.bottom, lessThanOrEqualTo(bar.top + 0.5));
    });

    testWidgets('with bar AND pill, the pill is above the bar and the last '
        'item is above the pill', (t) async {
      final cart = await _cart(true);
      await _pump(t, _shell(cart, pill: true));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      final row = await _scrollToEnd(t);
      final bar = t.getRect(find.byType(UpdateBar));
      final pill = t.getRect(find.byKey(kPillSlotKey));
      expect(pill.bottom, lessThanOrEqualTo(bar.top + 0.5));
      expect(row.bottom, lessThanOrEqualTo(pill.top + 0.5));
    });

    testWidgets('a spacer inside the host does not double the room',
        (t) async {
      final cart = await _cart(false);
      await _pump(t, _shell(cart, pill: false, withSpacer: true));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      final row = await _scrollToEnd(t);
      final bar = t.getRect(find.byType(UpdateBar));
      expect(t.getSize(find.byType(BottomStackSpacer, skipOffstage: false)).height, 0);
      expect(bar.top - row.bottom, closeTo(0, 0.5));
    });

    testWidgets('nothing up: the page runs to the nav', (t) async {
      final cart = await _cart(false);
      await _pump(t, _shell(cart, pill: true));
      final row = await _scrollToEnd(t);
      final screen = t.getSize(find.byType(MaterialApp));
      expect(row.bottom, closeTo(screen.height - _navHeight, 0.5));
    });
  });
}
