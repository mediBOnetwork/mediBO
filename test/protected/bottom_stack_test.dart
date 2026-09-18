// PROTECTED — CMD #2051 / #2066, the ONE bottom stack, and it is STATIC.
//
// See CLAUDE.md: this runs before EVERY deploy and may only be edited by a
// CHANGE that deliberately changes this behaviour, never to make an unrelated
// change go green.
//
// #2051 put the update bar and the floating cart pill into one column so they
// could not cover each other. #2066 took the last moving part out of that
// column. What this file holds down:
//
//   1. ORDER IS LAYOUT, NOT ARITHMETIC. Bottom-up the stack is nav, update-bar
//      slot, cart pill. It is a column, so the bar is BELOW the pill rather
//      than painted over it, and neither one needs to know the other's height.
//      The old shape (an app-level overlay for the bar, a Positioned pill in
//      each screen's own Stack, and a published number holding them apart) is
//      what let the bar cover the pill on Home and the Catalogue.
//
//   2. EVERY POSITION IS STATIC. The bar's slot is ALWAYS reserved and always
//      exactly one data row tall: no update pending means an empty transparent
//      box of the same height. So the pill's rectangle is IDENTICAL with a bar
//      and without one, on a shell and on a pushed route — it never moves, and
//      a backend `bottom_gap` cannot move it either.
//
//   3. EVERY LIST PADS BY A CONSTANT. [bottomStackHeight] is pill + gap + slot
//      and nothing else; [BottomStackSpacer] is that number as a box. It is
//      right on the FIRST frame and it never changes, so content above the
//      chrome cannot jump. #2051 measured and re-published it — that is
//      exactly what made lists re-pad when the bar arrived or a cart emptied.
//
//   4. THE BAR RENDERS ONLY WHERE THERE IS A BOTTOM NAV. The shell answers
//      that question by having one; the stack asks the Scaffold it is mounted
//      in. A pushed route (product page, cart, checkout, login) has no nav for
//      the bar to sit on and gets none — while still floating the pill at the
//      very same height. There is no app-level host any more, so "two
//      renderers at two anchors" cannot come back.
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
/// `bottom_gap` is deliberately still in the payload: #2066 IGNORES it, and a
/// test below proves the bar does not float by it.
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

/// How tall the fake nav is, so a test can say where the body ends.
const double _navHeight = 64;

/// A shell-shaped host: a Scaffold whose body Stack anchors the stack at
/// `bottom: 0`, which is the top of the bottom nav.
///
/// [hasNav] is the ONLY difference between a shell and a pushed route here,
/// because it is the only difference the stack is allowed to look at.
Widget _host(CartModel cart, {bool showPill = true, bool hasNav = true}) =>
    MaterialApp(
      home: Scaffold(
        bottomNavigationBar: hasNav
            ? const SizedBox(height: _navHeight, child: ColoredBox(
                color: Color(0xFFEEEEEE), child: Center(child: Text('nav'))))
            : null,
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
  });

  group('1. order is the layout', () {
    testWidgets('the pill sits ABOVE the bar, and the bar is on the nav',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      final pill = t.getRect(find.byKey(const Key('c2029_pill')));
      final bar = t.getRect(find.byType(UpdateBar));
      final screen = t.getSize(find.byType(MaterialApp));

      expect(pill.bottom, lessThanOrEqualTo(bar.top),
          reason: 'the pill must not be behind the bar — it is above it');
      expect(bar.bottom, closeTo(screen.height - _navHeight, 0.5),
          reason: 'FLUSH on the top of the nav, not floating above it');
    });

    testWidgets('the bar spans the full width and is exactly one row tall',
        (t) async {
      final cart = await _cart(show: false);
      await _pump(t, _host(cart), width: 412);
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      final bar = t.getRect(find.byType(UpdateBar));
      expect(bar.width, 412, reason: 'edge to edge, no side margins');
      expect(bar.height, closeTo(BottomStackMetrics.slot, 0.5),
          reason: 'the slot height is EXACT, not a minimum that can grow');
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

    testWidgets('one spacing step between the pill and the bar slot',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      // The SLOTS, not the pill's own rectangle: at 360 px a long backend
      // label makes the pill's FittedBox scale down inside its slot, which is
      // the right answer to a narrow phone. The reserved boxes are what may
      // never move.
      final slot = t.getRect(find.byKey(kPillSlotKey));
      final bar = t.getRect(find.byKey(kBarSlotKey));
      expect(bar.top - slot.bottom, closeTo(BottomStackMetrics.gap, 0.5));
      expect(slot.height, closeTo(BottomStackMetrics.pill, 0.5));

      // And the pill really is inside the box that was reserved for it.
      final pill = t.getRect(find.byKey(const Key('c2029_pill')));
      expect(slot.contains(pill.topLeft), isTrue);
      expect(slot.contains(pill.bottomRight - const Offset(0.01, 0.01)),
          isTrue);
    });
  });

  group('2. every position is static', () {
    testWidgets('the bar arriving does NOT move the pill', (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart));

      final before = t.getRect(find.byKey(const Key('c2029_pill')));
      expect(find.byType(UpdateBar), findsNothing);

      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      expect(find.byType(UpdateBar), findsOneWidget);

      expect(t.getRect(find.byKey(const Key('c2029_pill'))), before,
          reason: 'the slot was already reserved — nothing may shift');
    });

    testWidgets('the empty slot is exactly as tall as the bar would be',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart));

      // No update: the pill slot's bottom edge is one gap + one empty bar
      // slot above the top of the nav.
      final slot = t.getRect(find.byKey(kPillSlotKey));
      final screen = t.getSize(find.byType(MaterialApp));
      final navTop = screen.height - _navHeight;
      expect(navTop - slot.bottom,
          closeTo(BottomStackMetrics.gap + BottomStackMetrics.slot, 0.5),
          reason: 'the reserved slot is there even with nothing in it');
      expect(find.byKey(kBarSlotKey), findsOneWidget,
          reason: 'the bar slot is mounted with nothing in it');
      expect(t.getRect(find.byKey(kBarSlotKey)).height,
          closeTo(BottomStackMetrics.slot, 0.5));
    });

    testWidgets('an empty cart leaves the slot exactly where it was',
        (t) async {
      final full = await _cart(show: true);
      await _pump(t, _host(full));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      final withPill = t.getRect(find.byType(UpdateBar));

      final empty = await _cart(show: false);
      await _pump(t, _host(empty));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      // Nothing is printed when the backend says there is no pill…
      expect(find.text('View cart'), findsNothing);
      expect(find.text('3 items'), findsNothing);
      // …and the bar has not moved a pixel because of it.
      expect(t.getRect(find.byType(UpdateBar)), withPill);
    });

    testWidgets('the backend\'s bottom_gap does not lift the bar', (t) async {
      final cart = await _cart(show: false);
      await _pump(t, _host(cart), width: 412);
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      final bar = t.getRect(find.byType(UpdateBar));
      final screen = t.getSize(find.byType(MaterialApp));
      // `bottom_gap: 128` is in the payload and is ignored: an offset is the
      // one thing a static stack may not have.
      expect(screen.height - _navHeight - bar.bottom, closeTo(0, 0.5));
    });

    testWidgets('a surface that floats no pill keeps the same geometry',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart, showPill: false));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      expect(find.text('View cart'), findsNothing,
          reason: 'the registry said this surface does not float the pill');
      expect(find.byType(UpdateBar), findsOneWidget);
      expect(find.text('App update available'), findsOneWidget);
      // The space is still reserved — the chrome is one height everywhere.
      expect(t.getRect(find.byType(UpdateBar)).top,
          closeTo(800 - _navHeight - BottomStackMetrics.slot, 0.5));
    });
  });

  group('3. every list pads by a constant', () {
    test('the constant is pill + gap + slot, and nothing else', () {
      expect(
          bottomStackHeight,
          closeTo(
              BottomStackMetrics.pill +
                  BottomStackMetrics.gap +
                  BottomStackMetrics.slot,
              0.001));
      expect(BottomStackMetrics.slot, Ds.touch.listRowMinHeight);
      expect(BottomStackMetrics.gap, Ds.space.x16);
      expect(BottomStackMetrics.pill, CartPill.kHeight);
    });

    testWidgets('the spacer is that number on the FIRST frame', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
        bottomNavigationBar: const SizedBox(height: _navHeight),
        body: const Center(child: BottomStackSpacer()),
      )));
      // One pump: no post-frame measurement, no second frame needed.
      expect(t.getSize(find.byType(BottomStackSpacer)).height,
          closeTo(bottomStackHeight, 0.5));
    });

    testWidgets('the bar appearing does not change what a list pads by',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(
        t,
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: const SizedBox(height: _navHeight),
            body: AppState(
              cart: cart,
              child: Stack(children: [
                const Align(
                    alignment: Alignment.bottomCenter,
                    child: BottomStackSpacer()),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: StorefrontBottomStack(onCartTap: () {}),
                ),
              ]),
            ),
          ),
        ),
      );
      final before = t.getSize(find.byType(BottomStackSpacer)).height;
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      expect(t.getSize(find.byType(BottomStackSpacer)).height, before,
          reason: 'a list that re-pads is a list whose content jumps');
    });

    testWidgets('a page may add its own air on top of the chrome', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
        bottomNavigationBar: const SizedBox(height: _navHeight),
        body: Center(child: BottomStackSpacer(extra: Ds.space.x24)),
      )));
      expect(t.getSize(find.byType(BottomStackSpacer)).height,
          closeTo(bottomStackHeight + Ds.space.x24, 0.5));
    });
  });

  group('4. the bar renders only where there is a bottom nav', () {
    testWidgets('no bottom nav → no bar, however loud the controller is',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart, hasNav: false));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      expect(appUpdateBar.visible, isTrue);
      expect(find.byType(UpdateBar), findsNothing,
          reason: 'a pushed route has no nav for the bar to sit on');
      expect(find.text('App update available'), findsNothing);
    });

    testWidgets('and the pill is at exactly the same height there', (t) async {
      final cart = await _cart(show: true);

      await _pump(t, _host(cart, hasNav: true));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      final onShell = t.getRect(find.byKey(const Key('c2029_pill')));
      final screen = t.getSize(find.byType(MaterialApp));
      // Distance from the top of the nav — the edge the chrome sits on.
      final liftOnShell = (screen.height - _navHeight) - onShell.bottom;

      await _pump(t, _host(cart, hasNav: false));
      await t.pumpAndSettle();
      final pushed = t.getRect(find.byKey(const Key('c2029_pill')));
      final liftPushed = screen.height - pushed.bottom;

      expect(find.text('View cart'), findsOneWidget,
          reason: 'the pill still floats on a product page');
      expect(liftPushed, closeTo(liftOnShell, 0.5),
          reason: 'the reserved slot keeps the pill at one height everywhere');
    });

    testWidgets('the shell decides, not a screen name', (t) async {
      // The same widget, the same route, the same payload: the ONLY thing that
      // changes is whether the Scaffold has a nav.
      final cart = await _cart(show: true);
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);

      await _pump(t, _host(cart, hasNav: false));
      expect(find.byType(UpdateBar), findsNothing);

      await _pump(t, _host(cart, hasNav: true));
      expect(find.byType(UpdateBar), findsOneWidget);
    });

    // ── CMD #2066 QA round 1 ──────────────────────────────────────────────
    // Every case above pumps a FRESH tree, and a fresh tree always rebuilds —
    // which is precisely why they all passed while the bar stayed on a shell
    // that had dropped its nav. The bug needs the SAME element to stay mounted
    // while the nav changes underneath it, so this host mounts the stack the
    // way the supplier shell does (const, nav derived from the width) and then
    // only resizes the view. Nothing is re-pumped.
    Widget resizingHost(CartModel cart) => MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              // The supplier shell's own rule: no nav on a wide viewport.
              bottomNavigationBar: MediaQuery.of(context).size.width >= 900
                  ? null
                  : const SizedBox(height: _navHeight),
              body: AppState(
                cart: cart,
                child: const Stack(
                  children: [
                    Center(child: Text('page content')),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: StorefrontBottomStack(showPill: false),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

    testWidgets('the nav going away on a RESIZE takes the bar with it',
        (t) async {
      final cart = await _cart(show: false);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      t.view.physicalSize = const Size(360, 800);
      await t.pumpWidget(resizingHost(cart));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      expect(find.byType(UpdateBar), findsOneWidget,
          reason: 'a phone-width supplier shell has a nav, so it has the bar');

      // The ONLY change: the viewport. Same tree, same elements.
      t.view.physicalSize = const Size(1000, 800);
      await t.pumpAndSettle();

      expect(find.byType(UpdateBar), findsNothing,
          reason: 'no bottom nav any more -> the bar must not render. '
              'Scaffold.maybeOf registers no dependency, so the stack must '
              'take one from MediaQuery or it latches at its first answer.');
    });

    testWidgets('and the nav coming BACK brings the bar back', (t) async {
      final cart = await _cart(show: false);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      t.view.physicalSize = const Size(1000, 800);
      await t.pumpWidget(resizingHost(cart));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      expect(find.byType(UpdateBar), findsNothing);

      t.view.physicalSize = const Size(360, 800);
      await t.pumpAndSettle();

      expect(find.byType(UpdateBar), findsOneWidget,
          reason: 'the latch must not work in this direction either');
    });

    testWidgets('there is exactly one renderer — no app-level host', (t) async {
      final cart = await _cart(show: true);
      final nav = GlobalKey<NavigatorState>();
      await _pump(
        t,
        MaterialApp(
          navigatorKey: nav,
          home: Scaffold(
            bottomNavigationBar: const SizedBox(height: _navHeight),
            body: AppState(
              cart: cart,
              child: Stack(children: [
                const Center(child: Text('shell')),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: StorefrontBottomStack(onCartTap: () {}),
                ),
              ]),
            ),
          ),
        ),
      );
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      expect(find.byType(UpdateBar), findsOneWidget);

      // A pushed route with no nav of its own: the bar goes with the shell it
      // belonged to instead of being drawn over a screen with no room for it.
      nav.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('pushed')))));
      await t.pumpAndSettle();
      expect(find.text('pushed'), findsOneWidget);
      expect(find.byType(UpdateBar), findsNothing);

      // And back: the shell renders it again, exactly once.
      nav.currentState!.pop();
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
        expect(bar.height, closeTo(BottomStackMetrics.slot, 0.5));
        expect(pill.width, lessThanOrEqualTo(width));
        expect(pill.left, greaterThanOrEqualTo(0));
        expect(t.getSize(find.byType(FilledButton)).height,
            greaterThanOrEqualTo(Ds.touch.minTarget));
      });
    }

    testWidgets('a pushed route with no nav clears the gesture area itself',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart, hasNav: false));
      expect(t.takeException(), isNull);
      expect(find.text('View cart'), findsOneWidget);
    });
  });
}
