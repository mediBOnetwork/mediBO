// PROTECTED — CMD #2051, the ONE bottom stack.
//
// See CLAUDE.md: this runs before EVERY deploy and may only be edited by a
// CHANGE that deliberately changes this behaviour, never to make an unrelated
// change go green.
//
// What it holds down — the four ways two anchors for one strip of chrome went
// wrong before there was one:
//
//   1. ORDER IS LAYOUT, NOT ARITHMETIC. Bottom-up the stack is nav, update
//      bar, cart pill. It is a column, so the bar is BELOW the pill rather
//      than painted over it, and neither one needs to know the other's height.
//      The old shape (an app-level overlay for the bar, a Positioned pill in
//      each screen's own Stack, and a published number holding them apart)
//      is what let the bar cover the pill on Home and the Catalogue.
//
//   2. THE GAPS BELONG TO THE THING THAT IS THERE. The pill floats one
//      spacing step above the bar when there is a bar, and the same step above
//      the nav when there is not. No cart means no pill AND no gap where the
//      pill was — the stack shrinks to the bar alone.
//
//   3. EVERY LIST PADS BY THE MEASURED TOTAL. The stack publishes its own
//      height and [BottomStackSpacer] is that number as a box, so the last
//      card of any storefront list clears the chrome and no more — and it is
//      right again the frame after the bar appears or a cart empties. Nobody
//      pads by a constant.
//
//   4. ONE BAR, NEVER TWO. The app-level [UpdateBarHost] still raises the bar
//      on every non-storefront surface, but it stands down while a stack is
//      mounted. Two renderers painting the same bar at two anchors is the bug
//      this whole change is about.
//
// No network, no Supabase, no goldens: the cart is a fixture payload and every
// thumb url is empty, so ProductImage paints its offline fallback.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/bottom_stack.dart';
import 'package:pharma_b2b/widgets/cart_pill.dart';
import 'package:pharma_b2b/widgets/update_bar.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

/// Backend copy for the bar. Nothing here reads like something Dart coined.
const _barPayload = <String, dynamic>{
  'show': true,
  'platform': 'android',
  'label': 'App update available',
  'button_label': 'Update Now',
  'updating_label': 'Fetching the new build…',
  'downloaded_label': 'Restarting mediBO…',
  'bottom_gap': 128,
};

const _copy = <String, String>{
  'update_bar.title': 'FALLBACK TITLE',
  'update_bar.action': 'FALLBACK ACTION',
  'update_bar.updating': 'FALLBACK UPDATING',
};

Map<String, dynamic> _thumb(String id) => {
      'product_id': id,
      'name': 'Product $id',
      'image_url': '',
      'has_image': false,
    };

/// Mirrors cart_pill_block(): every string already decided by the backend.
Map<String, dynamic> _cartPayload({required bool show}) => {
      'items': const [],
      'item_count': 0,
      'render': {
        'pill': {
          'show': show,
          'items_label': '3 items',
          'cta': 'View cart',
          'thumbs': show ? [_thumb('a'), _thumb('b')] : const [],
          'thumb_count': show ? 2 : 0,
        },
      },
    };

Future<CartModel> _cart({required bool show}) async {
  CartModel.rpcTransport = (fn, params) async => _cartPayload(show: show);
  final c = CartModel.forTest();
  await c.refresh();
  return c;
}

/// A shell-shaped host: a Scaffold whose body Stack anchors the stack at
/// `bottom: 0` — which in the real shell is the top of the bottom nav.
Widget _host(CartModel cart, {bool showPill = true, bool overNav = true}) =>
    MaterialApp(
      home: Scaffold(
        body: AppState(
          cart: cart,
          child: Stack(
            children: [
              const Center(child: Text('page content')),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: StorefrontBottomStack(
                  onCartTap: () {},
                  showPill: showPill,
                  overNav: overNav,
                ),
              ),
            ],
          ),
        ),
      ),
    );

Future<void> _pump(WidgetTester t, Widget w, {double width = 360}) async {
  t.view.physicalSize = Size(width, 800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(w);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(_copy);
  });
  tearDown(() {
    CartModel.rpcTransport = null;
    appUpdateBar.reset();
    bottomStackHeight.value = 0;
  });

  group('1. order is the layout', () {
    testWidgets('the pill sits ABOVE the bar, and the bar is on the bottom',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      final pill = t.getRect(find.byType(CartPill));
      final bar = t.getRect(find.byType(UpdateBar));
      final screen = t.getSize(find.byType(MaterialApp));

      expect(pill.bottom, lessThanOrEqualTo(bar.top),
          reason: 'the pill must not be behind the bar — it is above it');
      expect(bar.bottom, closeTo(screen.height, 0.5),
          reason: 'the bar is FLUSH on whatever is under it, not floating');
    });

    testWidgets('the bar spans the full width and is one data row tall',
        (t) async {
      final cart = await _cart(show: false);
      await _pump(t, _host(cart), width: 412);
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      final bar = t.getRect(find.byType(UpdateBar));
      expect(bar.width, 412, reason: 'edge to edge, no side margins');
      expect(bar.height, greaterThanOrEqualTo(Ds.touch.listRowMinHeight));
      expect(t.takeException(), isNull);
    });

    testWidgets('the pill hugs its content — it is not a slice of the screen',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart), width: 412);

      final pill = t.getRect(find.byKey(const Key('c2029_pill')));
      expect(pill.width, lessThan(412));
      expect(pill.center.dx, closeTo(206, 1),
          reason: 'centred in the width the stack was handed');
    });
  });

  group('2. the gaps belong to the thing that is there', () {
    testWidgets('one spacing step between the pill and the bar', (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      final pill = t.getRect(find.byType(CartPill));
      final bar = t.getRect(find.byType(UpdateBar));
      expect(bar.top - pill.bottom, closeTo(Ds.space.x16, 0.5));
    });

    testWidgets('no bar → the pill floats the same step above the nav',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart));

      expect(find.byType(UpdateBar), findsNothing);
      final pill = t.getRect(find.byType(CartPill));
      final screen = t.getSize(find.byType(MaterialApp));
      expect(screen.height - pill.bottom, closeTo(Ds.space.x16, 0.5));
    });

    testWidgets('an empty cart takes the pill AND its gap away', (t) async {
      final cart = await _cart(show: false);
      await _pump(t, _host(cart));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      expect(find.byType(CartPill), findsNothing);
      final bar = t.getRect(find.byType(UpdateBar));
      // The stack is the bar and nothing else: no hole where the pill was.
      expect(bottomStackHeight.value, closeTo(bar.height, 0.5));
    });

    testWidgets('a surface that does not float the pill still gets the bar',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart, showPill: false));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      expect(find.byType(CartPill), findsNothing);
      expect(find.byType(UpdateBar), findsOneWidget);
      expect(find.text('App update available'), findsOneWidget);
    });
  });

  group('3. every list pads by the measured total', () {
    testWidgets('the published height is the whole stack, and it MOVES',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart));

      final pillOnly = bottomStackHeight.value;
      expect(pillOnly, greaterThan(0));

      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      final withBar = bottomStackHeight.value;

      expect(withBar, greaterThan(pillOnly),
          reason: 'the bar appearing must grow what every list pads by');
      final bar = t.getRect(find.byType(UpdateBar));
      expect(withBar - pillOnly, closeTo(bar.height, 0.5));
    });

    testWidgets('the spacer is exactly that number', (t) async {
      bottomStackHeight.value = 0;
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: Center(child: BottomStackSpacer()))));
      await t.pump();
      expect(t.getSize(find.byType(BottomStackSpacer)).height, 0);

      bottomStackHeight.value = 137;
      await t.pump();
      expect(t.getSize(find.byType(BottomStackSpacer)).height, 137,
          reason: 'a list re-reads the height, it does not cache a constant');
    });

    testWidgets('a page may add its own air on top of the chrome', (t) async {
      bottomStackHeight.value = 100;
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Center(child: BottomStackSpacer(extra: Ds.space.x24)))));
      await t.pump();
      expect(t.getSize(find.byType(BottomStackSpacer)).height,
          100 + Ds.space.x24);
    });
  });

  group('4. one bar, never two', () {
    testWidgets('the app-level host stands down while a stack is mounted',
        (t) async {
      final cart = await _cart(show: true);
      // The host wraps the app exactly as MaterialApp.builder installs it, and
      // the stack is mounted inside — the real arrangement on a storefront
      // screen, where BOTH renderers are alive at once.
      await _pump(
        t,
        MaterialApp(
          home: Scaffold(
            body: UpdateBarHost(
              controller: appUpdateBar,
              child: AppState(
                cart: cart,
                child: Stack(
                  children: [
                    const Center(child: Text('page content')),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: StorefrontBottomStack(onCartTap: () {}),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      expect(find.byType(UpdateBar), findsOneWidget);
      expect(find.text('Update Now'), findsOneWidget);
    });

    testWidgets('a stack COVERED by a pushed route hands the bar back',
        (t) async {
      // CMD #2051 QA round 1. The first shape of the takeover was a global
      // mount count, and the shell's stack is alive for as long as the shell
      // is — including behind an opaque pushed route. So on every pushed
      // customer route that mounts no stack of its own (a company page, an
      // order, the wishlist) the host had stood down for a stack nobody could
      // see, and the update bar vanished from a dozen screens.
      final cart = await _cart(show: true);
      final nav = GlobalKey<NavigatorState>();
      await _pump(
        t,
        MaterialApp(
          navigatorKey: nav,
          // The host is installed from `builder`, ABOVE the Navigator, exactly
          // as main.dart installs it — that is why it can still draw the bar
          // over a route pushed on top of the shell.
          builder: (_, child) =>
              UpdateBarHost(controller: appUpdateBar, child: child!),
          home: Scaffold(
            body: AppState(
              cart: cart,
              child: Stack(
                children: [
                  const Center(child: Text('shell')),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: StorefrontBottomStack(onCartTap: () {}),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      expect(find.byType(UpdateBar), findsOneWidget,
          reason: 'the shell owns the bar while it is in front');

      // A pushed route that draws no stack of its own — the case that broke.
      nav.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('pushed')))));
      await t.pumpAndSettle();

      expect(find.text('pushed'), findsOneWidget);
      expect(find.byType(UpdateBar), findsOneWidget,
          reason: 'the host takes the bar back — one renderer, never zero');
      expect(find.text('App update available'), findsOneWidget);

      // And back: the shell owns it again, exactly once.
      nav.currentState!.pop();
      await t.pumpAndSettle();
      expect(find.byType(UpdateBar), findsOneWidget);
    });

    testWidgets('with no stack mounted the host still raises it', (t) async {
      await _pump(
        t,
        MaterialApp(
          home: Scaffold(
            body: UpdateBarHost(
              controller: appUpdateBar,
              child: const Center(child: Text('page content')),
            ),
          ),
        ),
      );
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      expect(find.byType(UpdateBar), findsOneWidget);
    });
  });

  group('5. every phone, no overflow', () {
    for (final width in <double>[320, 360, 412, 480]) {
      testWidgets('nothing overflows at $width px', (t) async {
        final cart = await _cart(show: true);
        await _pump(t, _host(cart), width: width);
        appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
        await t.pumpAndSettle();

        expect(t.takeException(), isNull);
        final bar = t.getRect(find.byType(UpdateBar));
        final pill = t.getRect(find.byKey(const Key('c2029_pill')));
        expect(bar.width, width);
        expect(pill.width, lessThanOrEqualTo(width));
        expect(pill.left, greaterThanOrEqualTo(0));
        expect(t.getSize(find.byType(FilledButton)).height,
            greaterThanOrEqualTo(Ds.touch.minTarget));
      });
    }

    testWidgets('a pushed route with no nav clears the gesture area itself',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart, overNav: false));
      expect(t.takeException(), isNull);
      expect(find.byType(CartPill), findsOneWidget);
    });
  });
}
