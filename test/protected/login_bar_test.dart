// PROTECTED — CMD #2114, the LOGIN bar and where a login and a logout land.
//
// See CLAUDE.md: this runs before EVERY deploy and may only be edited by a
// CHANGE that deliberately changes this behaviour, never to make an unrelated
// change go green.
//
// A signed-out visitor had no way of knowing there was anything to log in to:
// the bottom-stack bar slot was empty for exactly the person who needed it
// most, because the driver took the bar DOWN when nobody was signed in. What
// this file holds down:
//
//   1. THE SAME SLOT, THE SAME PILL, A THIRD ANSWER. The login ask renders
//      through the SAME [UpdateBar] in the SAME box as the update bar and the
//      registration bar, so "same position, shape, size and colour" is one
//      renderer rather than three kept equal by hand.
//
//   2. ONE BAR AT A TIME, PRECEDENCE update > login > registration. Never two,
//      never stacked — including when a payload gets both asks wrong at once.
//
//   3. WHICH BAR IT IS, IS THE BACKEND'S WORD. `kind` comes out of
//      `customer_registration_bar()`. Nothing here reads an auth flag, and
//      nothing here infers the bar from its route.
//
//   4. EVERY STRING IS THE BACKEND'S. "New Here?" and "Login" are payload,
//      never Dart literals, and Login opens the address the payload named.
//
//   5. A SIGNED-OUT SESSION IS ASKED, NOT ASSUMED. The driver calls the RPC
//      either way; `signedIn:false` is a reason to re-ask, not an answer.
//
//   6. A LOGOUT LANDS WHERE THE BACKEND SAYS. `logout_route` is read off the
//      session payload, defaults to the app root when absent, and is NOT
//      derived from `home_route` — home is where a user lives, this is where
//      they go when they stop being that user.
//
// No network, no Supabase, no goldens: the payloads are fixtures.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/app_session.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/services/registration_bar.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/bottom_stack.dart';
import 'package:pharma_b2b/widgets/update_bar.dart';

const double _navHeight = 56;

/// Exactly what `customer_registration_bar()` returns to an anonymous caller.
const _loginPayload = <String, dynamic>{
  'show': true,
  'kind': 'login',
  'reason': 'signed_out',
  'title': 'New Here?',
  'cta': 'Login',
  'route': '/login',
  'anchor': '',
  'poll_seconds': 300,
};

const _regPayload = <String, dynamic>{
  'show': true,
  'kind': 'registration',
  'reason': 'registration_pending',
  'title': 'Registration pending',
  'cta': 'Continue',
  'route': '/complete-registration',
  'anchor': '',
  'poll_seconds': 300,
};

class _Recorder extends NavigatorObserver {
  final List<String> pushed = [];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) {
    pushed.add(route.settings.name ?? '');
  }
}

Future<CartModel> _cart() async {
  CartModel.rpcTransport = (fn, params) async => const {
        'items': [],
        'item_count': 0,
        'render': {'pill': {'show': false}},
      };
  final c = CartModel.forTest();
  await c.refresh();
  return c;
}

Widget _host(CartModel cart, _Recorder nav) => MaterialApp(
      navigatorObservers: [nav],
      routes: {
        '/login': (_) => const Scaffold(body: Center(child: Text('LOGIN'))),
        '/complete-registration': (_) =>
            const Scaffold(body: Center(child: Text('THE ONE FORM'))),
      },
      home: Scaffold(
        bottomNavigationBar:
            const SizedBox(height: _navHeight, child: Center(child: Text('nav'))),
        body: AppState(
          cart: cart,
          child: Stack(children: [
            const Center(child: Text('page content')),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: StorefrontBottomStack(onCartTap: () {}, showPill: false),
            ),
          ]),
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
  setUpAll(() => RenderLog.flushEnabled = false);

  setUp(() {
    appUpdateBar.reset();
    appRegistrationBar.reset();
    RegistrationBarFeed.rpcTransport = null;
  });

  tearDown(() {
    appUpdateBar.reset();
    appRegistrationBar.reset();
    RegistrationBarFeed.rpcTransport = null;
  });

  group('the controller carries the backend\'s kind', () {
    test('kind is the payload\'s, and empty when there is no bar', () {
      final c = RegistrationBarController();
      expect(c.kind, '');
      c.adopt(Map<String, dynamic>.from(_loginPayload));
      expect(c.kind, 'login');
      expect(c.label, 'New Here?');
      expect(c.actionLabel, 'Login');
      expect(c.route, '/login');
      c.adopt(Map<String, dynamic>.from(_regPayload));
      expect(c.kind, 'registration');
    });

    test('a wordless login payload is still no bar', () {
      final c = RegistrationBarController();
      c.adopt(const {'show': true, 'kind': 'login', 'title': ''});
      expect(c.visible, isFalse,
          reason: 'a pill with no words is not a bar, whichever ask it is');
    });

    test('a signed-out session is ASKED, never assumed', () async {
      final calls = <String>[];
      RegistrationBarFeed.rpcTransport = (fn, p) async {
        calls.add(fn);
        return Map<String, dynamic>.from(_loginPayload);
      };
      addTearDown(RegistrationBarDriver.instance.stop);
      await RegistrationBarDriver.instance.onAuth(signedIn: false);
      expect(calls, ['customer_registration_bar'],
          reason: 'signed out is the login bar\'s whole audience');
      expect(appRegistrationBar.visible, isTrue);
      expect(appRegistrationBar.kind, 'login');
    });
  });

  group('ONE slot, precedence update > login > registration', () {
    testWidgets('the login bar renders in the update bar\'s own box',
        (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(Map<String, dynamic>.from(_loginPayload));
      await t.pumpAndSettle();

      expect(find.byKey(kLoginBarKey), findsOneWidget);
      // The SAME widget as the update bar — that is what makes it one banner.
      expect(find.byType(UpdateBar), findsOneWidget);
      expect(find.text('New Here?'), findsOneWidget);
      expect(find.text('Login'), findsOneWidget);
      // ...in the one slot, at the one height.
      final slot = t.getSize(find.byKey(kBarSlotKey));
      expect(slot.height, BottomStackMetrics.slot);
    });

    testWidgets('an update outranks the login ask — one bar, never two',
        (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(Map<String, dynamic>.from(_loginPayload));
      appUpdateBar.show(
          onUpdate: () {},
          payload: const {'title': 'App update available', 'cta': 'Update Now'});
      await t.pumpAndSettle();

      expect(find.byType(UpdateBar), findsOneWidget);
      expect(find.byKey(kLoginBarKey), findsNothing);
      expect(find.text('App update available'), findsOneWidget);
      expect(find.text('New Here?'), findsNothing);

      // ...and the login ask comes back by itself once the update lands.
      appUpdateBar.hide();
      await t.pumpAndSettle();
      expect(find.byKey(kLoginBarKey), findsOneWidget);
      expect(find.text('New Here?'), findsOneWidget);
    });

    testWidgets('the bar it draws is the payload\'s kind, not its route',
        (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(Map<String, dynamic>.from(_regPayload));
      await t.pumpAndSettle();
      expect(find.byKey(kRegistrationBarKey), findsOneWidget);
      expect(find.byKey(kLoginBarKey), findsNothing);

      appRegistrationBar.adopt(Map<String, dynamic>.from(_loginPayload));
      await t.pumpAndSettle();
      expect(find.byKey(kLoginBarKey), findsOneWidget);
      expect(find.byKey(kRegistrationBarKey), findsNothing,
          reason: 'one slot holds one bar');
    });

    testWidgets('no bar without a bottom nav — the desktop layout is untouched',
        (t) async {
      final nav = _Recorder();
      final cart = await _cart();
      t.view.physicalSize = const Size(1280, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        navigatorObservers: [nav],
        home: Scaffold(
          // No bottomNavigationBar: a wide shell, or a pushed route.
          body: AppState(
            cart: cart,
            child: Stack(children: [
              const Center(child: Text('page content')),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: StorefrontBottomStack(onCartTap: () {}, showPill: false),
              ),
            ]),
          ),
        ),
      ));
      await t.pumpAndSettle();
      appRegistrationBar.adopt(Map<String, dynamic>.from(_loginPayload));
      await t.pumpAndSettle();
      expect(find.byKey(kLoginBarKey), findsNothing);
      expect(t.getSize(find.byKey(kBarSlotKey)).height, 0);
    });
  });

  group('Login opens the address the backend named', () {
    testWidgets('tapping Login pushes the payload\'s route', (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(Map<String, dynamic>.from(_loginPayload));
      await t.pumpAndSettle();

      await t.tap(find.text('Login'));
      await t.pumpAndSettle();
      expect(nav.pushed.last, '/login');
      expect(find.text('LOGIN'), findsOneWidget);
    });

    testWidgets('an empty route opens nothing rather than guessing one',
        (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(<String, dynamic>{
        ..._loginPayload,
        'route': '',
      });
      await t.pumpAndSettle();
      final before = nav.pushed.length;
      await t.tap(find.text('Login'));
      await t.pumpAndSettle();
      expect(nav.pushed.length, before);
    });

    testWidgets('the button carries its own semantics address', (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(Map<String, dynamic>.from(_loginPayload));
      await t.pumpAndSettle();
      final handle = t.ensureSemantics();
      expect(
          find.bySemanticsIdentifier(kLoginBarActionId), findsOneWidget,
          reason: 'a journey taps this bar by name, not by colour');
      handle.dispose();
    });
  });

  group('a logout lands where the backend says', () {
    test('logout_route is read off the payload, both signed in and out', () {
      final out = AppSession.fromJson(const {
        'signed_in': false,
        'home_route': '/login',
        'logout_route': '/',
      });
      expect(out.logoutRoute, '/');

      final inn = AppSession.fromJson(const {
        'signed_in': true,
        'home_route': '/dashboard',
        'logout_route': '/',
      });
      expect(inn.logoutRoute, '/');
      expect(inn.homeRoute, '/dashboard',
          reason: 'home is where a user lives; logout is a different address');
    });

    test('a backend that named none falls back to the app root', () {
      final s = AppSession.fromJson(const {
        'signed_in': true,
        'home_route': '/dashboard',
      });
      expect(s.logoutRoute, '/');
      final blank = AppSession.fromJson(const {
        'signed_in': true,
        'home_route': '/dashboard',
        'logout_route': '   ',
      });
      expect(blank.logoutRoute, '/');
    });

    test('logout_route is never derived from home_route', () {
      final s = AppSession.fromJson(const {
        'signed_in': true,
        'home_route': '/supplier',
        'logout_route': '/',
      });
      expect(s.logoutRoute, isNot(s.homeRoute));
    });
  });
}
