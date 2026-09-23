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
//   2. EVERY HEIGHT IS A STATE, NEVER A MEASUREMENT (CMD #2091). A slot is the
//      size named in [BottomStackMetrics] when the thing that belongs in it is
//      showing, and 0 when it is not — decided by two booleans (an update is
//      pending on a shell with a nav; the cart payload says there is a pill)
//      and by nothing a child publishes. So a line-wrap, a longer sentence or
//      a wider phone still cannot move anything, which is #2066's point, while
//      an EMPTY stack takes no room at all, which is #2091's. A backend
//      `bottom_gap` still cannot lift the bar.
//
//   3. A LIST PADS BY WHAT THE CHROME IS ACTUALLY TAKING. [bottomStackHeight]
//      is the CEILING — pill + gap + slot; what a page holds back is
//      [BottomStackLiveMetrics.height], read through [BottomStackSpacer] and
//      [BottomStackClearance], which is 0 when the stack is empty. Before
//      #2091 a staff page reserved a whole bar slot on every day with no
//      update pending, and that dead white band above the bottom nav was on
//      every admin, super-admin and partner screen in the app. Both sides
//      travel on ONE token (`Ds.motion.sheet`), so a dismissed bar leaves no
//      gap behind it.
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
          'identifier': 'cart_pill',
          'items_label': '3 items',
          'cta': 'View cart',
          // CMD #2081 — cart_pill_block() emits the two STACKED lines; the
          // pill prints those, so the fixture carries them.
          'lines': const [
            {'key': 'cta', 'text': 'View cart'},
            {'key': 'count', 'text': '3 items'},
          ],
          'thumbs': show ? [_thumb('a'), _thumb('b')] : const [],
          'thumb_count': show ? 2 : 0,
          'has_more': show,
          'more_label': show ? '+1' : '',
          'a11y': 'View cart, 3 items',
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

  group('2. every height is a state, never a measurement', () {
    testWidgets('no update pending: the bar slot is GONE, not empty',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart));

      // The slot is the thing #2091 changed: it used to be a 56 px
      // transparent box holding room for a bar that was not there.
      expect(t.getSize(find.byKey(kBarSlotKey)).height, closeTo(0, 0.5),
          reason: 'an empty slot takes no room — this is the blank strip');

      // …so the pill floats on its own air, one gap above the nav.
      final screen = t.getSize(find.byType(MaterialApp));
      final navTop = screen.height - _navHeight;
      final slot = t.getRect(find.byKey(kPillSlotKey));
      expect(navTop - slot.bottom, closeTo(BottomStackMetrics.gap, 0.5));
    });

    testWidgets('the bar arriving lifts the pill by exactly the slot it '
        'opened', (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart));

      final before = t.getRect(find.byKey(const Key('c2029_pill')));
      expect(find.byType(UpdateBar), findsNothing);

      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      expect(find.byType(UpdateBar), findsOneWidget);

      final after = t.getRect(find.byKey(const Key('c2029_pill')));
      expect(before.top - after.top, closeTo(BottomStackMetrics.slot, 0.5),
          reason: 'the pill rides up on the slot that opened under it — one '
              'slot, not a number two widgets keep equal');
      expect(after.left, before.left,
          reason: 'nothing about the pill itself changed');
    });

    testWidgets('and dismissing it gives every one of those pixels back',
        (t) async {
      final cart = await _cart(show: true);
      await _pump(t, _host(cart));
      final atRest = t.getRect(find.byKey(const Key('c2029_pill')));

      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      expect(find.byType(UpdateBar), findsOneWidget);

      appUpdateBar.hide();
      await t.pumpAndSettle();

      expect(find.byType(UpdateBar), findsNothing);
      expect(t.getSize(find.byKey(kBarSlotKey)).height, closeTo(0, 0.5),
          reason: 'no leftover gap after the x — the slot closes with it');
      expect(t.getRect(find.byKey(const Key('c2029_pill'))), atRest);
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

  group('3. a list pads by what the chrome is actually taking', () {
    test('the CEILING is pill + gap + slot, and nothing else', () {
      expect(
          bottomStackHeight,
          closeTo(
              BottomStackMetrics.pill +
                  BottomStackMetrics.gap +
                  BottomStackMetrics.slot,
              0.001));
      expect(BottomStackMetrics.slot, Ds.touch.listRowMinHeight);
      // CMD #2172 (Om) — 10, not 12, and its own token: "View cart SEPARATE:
      // own pill 10dp above the card, never hidden". The pill is no longer
      // sitting on a bar slot — it floats above the whole floating card.
      expect(BottomStackMetrics.gap, Ds.touch.cartPillGap,
          reason: 'the pill\'s air is a Dart number again');
      expect(BottomStackMetrics.gap, 10);
      expect(BottomStackMetrics.pill, CartPill.kHeight);
    });

    testWidgets('an empty stack is reserved ZERO, on the FIRST frame',
        (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
        bottomNavigationBar: const SizedBox(height: _navHeight),
        body: const Center(child: BottomStackSpacer()),
      )));
      // One pump: no post-frame measurement, no animation to settle into.
      // Nothing is in the stack, so nothing is held back for it — this is the
      // blank strip #2091 removes, measured at its source.
      expect(t.getSize(find.byType(BottomStackSpacer)).height,
          closeTo(0, 0.5));
    });

    testWidgets('a full stack is reserved the ceiling, on the FIRST frame',
        (t) async {
      final cart = await _cart(show: true);
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: const SizedBox(height: _navHeight),
          body: AppState(
            cart: cart,
            child: const Center(child: BottomStackSpacer()),
          ),
        ),
      ));
      expect(t.getSize(find.byType(BottomStackSpacer)).height,
          closeTo(bottomStackHeight, 0.5),
          reason: 'pill + its air + the bar slot, right on the first frame');
    });

    testWidgets('the bar appearing is exactly what a list pads by', (t) async {
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
      final withBar = t.getSize(find.byType(BottomStackSpacer)).height;
      expect(withBar - before, closeTo(BottomStackMetrics.slot, 0.5),
          reason: 'the room a list holds back is the room the chrome took');

      // …and the slot the stack opened is the same number, which is the whole
      // point of reading it in one place.
      expect(t.getSize(find.byKey(kBarSlotKey)).height,
          closeTo(withBar - before, 0.5));

      appUpdateBar.hide();
      await t.pumpAndSettle();
      expect(t.getSize(find.byType(BottomStackSpacer)).height,
          closeTo(before, 0.5),
          reason: 'and it is given back — no leftover gap after dismiss');
    });

    testWidgets('a page may add its own air on top of the chrome', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
        bottomNavigationBar: const SizedBox(height: _navHeight),
        body: Center(child: BottomStackSpacer(extra: Ds.space.x24)),
      )));
      // The page's own air is the page's, chrome or no chrome.
      expect(t.getSize(find.byType(BottomStackSpacer)).height,
          closeTo(Ds.space.x24, 0.5));
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

    testWidgets('and with no update pending the pill is at exactly the same '
        'height there', (t) async {
      final cart = await _cart(show: true);

      await _pump(t, _host(cart, hasNav: true));
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
          reason: 'the pill floats on its own air, which is the same air on '
              'both — a shell has no bar slot open either when there is no '
              'update pending (CMD #2091)');
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

  // ── 6. THE STAFF SHELLS RESERVE THE BAR'S ROOM (CMD #2070) ────────────────
  //
  // #2066 reserved the chrome inside the CUSTOMER lists and left the admin,
  // supplier and partner pages hosting the very same bar with nothing held
  // back for it, so an admin's last row sat under it. A per-page spacer was
  // never going to hold across dozens of staff pages written by dozens of
  // commands, so the SHELL reserves it once for its whole page host.
  group('6. staff shells clear the bar', () {
    const lastRow = Key('c2070_last_row');

    /// A staff shell: nav, a page host, and the same stack the shells mount.
    Widget staffHost(
      CartModel cart, {
      required bool staff,
      bool hasNav = true,
      double navBreakpoint = 0,
    }) =>
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              // A nav unless this shell drops it on a wide viewport, which
              // is the supplier shell's own rule at 900.
              bottomNavigationBar: (hasNav &&
                      (navBreakpoint == 0 ||
                          MediaQuery.of(context).size.width < navBreakpoint))
                  ? const SizedBox(height: _navHeight)
                  : null,
              body: AppState(
                cart: cart,
                child: Stack(
                  children: [
                    Column(
                      children: [
                        Expanded(
                          child: staffPageHost(
                            ListView(
                              children: const [
                                SizedBox(height: 2000),
                                SizedBox(
                                  key: lastRow,
                                  height: 40,
                                  child: Text('last row'),
                                ),
                              ],
                            ),
                            staff: staff,
                          ),
                        ),
                      ],
                    ),
                    const Positioned(
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

    Future<Rect> scrolledToLastRow(WidgetTester t) async {
      await t.drag(find.byType(ListView), const Offset(0, -3000));
      await t.pumpAndSettle();
      return t.getRect(find.byKey(lastRow));
    }

    testWidgets('an admin page ends ABOVE the bar, never under it', (t) async {
      final cart = await _cart(show: false);
      await _pump(t, staffHost(cart, staff: true));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      final row = await scrolledToLastRow(t);
      final bar = t.getRect(find.byType(UpdateBar));
      expect(row.bottom, lessThanOrEqualTo(bar.top + 0.5),
          reason: 'the last row of a staff page must clear the update bar');
    });

    testWidgets('without the clearance that same row IS under the bar',
        (t) async {
      // The control: this is exactly what every admin page did before #2070.
      final cart = await _cart(show: false);
      await _pump(t, staffHost(cart, staff: false));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      final row = await scrolledToLastRow(t);
      final bar = t.getRect(find.byType(UpdateBar));
      expect(row.bottom, greaterThan(bar.top),
          reason: 'proves the assertion above is measuring the clearance '
              'and not something the ListView would have done anyway');
    });

    // ── CMD #2091 — THE BLANK STRIP ──────────────────────────────────────
    //
    // #2070 reserved the bar's room on every staff page and reserved it
    // ALWAYS. An update is pending for minutes a month, so what an admin,
    // a super admin and a partner actually saw on every screen, all the rest
    // of the time, was a dead white band above their bottom nav.
    testWidgets('no update pending: a staff page runs down to the nav — no '
        'blank strip', (t) async {
      final cart = await _cart(show: false);
      await _pump(t, staffHost(cart, staff: true));

      final row = await scrolledToLastRow(t);
      final screen = t.getSize(find.byType(MaterialApp));
      expect(row.bottom, closeTo(screen.height - _navHeight, 0.5),
          reason: 'nothing is in the stack, so nothing is held back for it');
      expect(find.byType(UpdateBar), findsNothing);
      expect(t.getSize(find.byKey(kBarSlotKey)).height, closeTo(0, 0.5));
    });

    testWidgets('the clearance is the bar\'s room — taken when it arrives, '
        'given back when it goes', (t) async {
      final cart = await _cart(show: false);
      await _pump(t, staffHost(cart, staff: true));

      final screen = t.getSize(find.byType(MaterialApp));
      final navTop = screen.height - _navHeight;

      // How much room the host is holding back: the gap between the end of
      // the page (its last row, scrolled fully into view) and the nav.
      Future<double> heldBack() async =>
          navTop - (await scrolledToLastRow(t)).bottom;

      expect(await heldBack(), closeTo(0, 0.5),
          reason: 'nothing pending, nothing held back');

      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      expect(await heldBack(), closeTo(BottomStackMetrics.slot, 0.5),
          reason: 'exactly the slot that opened, never more');
      final bar = t.getRect(find.byType(UpdateBar));
      expect(t.getRect(find.byKey(lastRow)).bottom,
          lessThanOrEqualTo(bar.top + 0.5),
          reason: 'and the row still clears the bar (spec 3)');

      // The x. #2091's second half: the room comes back with it.
      appUpdateBar.hide();
      await t.pumpAndSettle();
      expect(await heldBack(), closeTo(0, 0.5),
          reason: 'no leftover gap after dismiss');
    });

    testWidgets('it reserves the BAR slot, not the pill a staff page never '
        'floats', (t) async {
      final cart = await _cart(show: true);
      await _pump(t, staffHost(cart, staff: true));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();

      final row = await scrolledToLastRow(t);
      final screen = t.getSize(find.byType(MaterialApp));
      final held = (screen.height - _navHeight) - row.bottom;
      expect(held, closeTo(bottomBarOnlyHeight, 0.5),
          reason: 'a surface with no pill must not pay for the pill slot, '
              'even with a full cart underneath it');

      // And the two ceilings still say what they always said.
      expect(bottomBarOnlyHeight, BottomStackMetrics.slot);
      expect(
          bottomStackHeight,
          BottomStackMetrics.pill +
              BottomStackMetrics.gap +
              BottomStackMetrics.slot);
      expect(bottomBarOnlyHeight, lessThan(bottomStackHeight));
    });

    testWidgets('a wide staff shell with no nav paints no bar and owes no '
        'clearance', (t) async {
      final cart = await _cart(show: false);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      t.view.physicalSize = const Size(360, 800);
      await t.pumpWidget(
          staffHost(cart, staff: true, navBreakpoint: 900));
      appUpdateBar.show(onUpdate: () {}, payload: _barPayload);
      await t.pumpAndSettle();
      final narrow = await scrolledToLastRow(t);
      final bar = t.getRect(find.byType(UpdateBar));
      expect(narrow.bottom, lessThanOrEqualTo(bar.top + 0.5));

      // The ONLY change is the viewport — the same elements, rebuilt.
      t.view.physicalSize = const Size(1000, 800);
      await t.pumpAndSettle();
      expect(find.byType(UpdateBar), findsNothing,
          reason: 'no nav, no bar (CMD #2066 QA round 1)');

      final wide = await scrolledToLastRow(t);
      final screen = t.getSize(find.byType(MaterialApp));
      expect(wide.bottom, closeTo(screen.height, 0.5),
          reason: 'nothing paints down there any more, so the host must not '
              'keep holding room back — the clearance must not latch either');
    });
  });
}
