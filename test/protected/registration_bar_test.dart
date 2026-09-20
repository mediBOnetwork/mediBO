// PROTECTED — CMD #2112, the ONE banner slot and the ONE registration door.
//
// See CLAUDE.md: this runs before EVERY deploy and may only be edited by a
// CHANGE that deliberately changes this behaviour, never to make an unrelated
// change go green.
//
// Registration used to be advertised in an orange block at the top of Home,
// while the app update was a pill on the bottom nav. Two shapes, two places,
// and a phone could see both at once. What this file holds down:
//
//   1. ONE SLOT, ONE BAR, AND THE UPDATE WINS. Both asks render through the
//      SAME widget in the SAME box, so "same position, shape, size and colour"
//      is one renderer rather than two that have to be kept equal. When both
//      are pending only the update is on screen; the registration ask appears
//      by itself the moment the app is on the new build.
//
//   2. THE BAR IS THE BACKEND'S ANSWER, WORD FOR WORD. `show`, the sentence,
//      the button's word, the address Continue opens and the section it lands
//      on all arrive in `customer_registration_bar()`. A failed call, a
//      `show:false` and a payload with no sentence in it all mean NO BAR — a
//      pill with no words is not a bar, and an unreachable backend must never
//      tell a registered shop it is pending.
//
//   3. CONTINUE OPENS THE ROUTE THE PAYLOAD NAMED, WITH ITS ANCHOR. It never
//      guesses an address: an empty route opens nothing at all.
//
//   4. THERE IS ONE REGISTRATION SCREEN. The old self-signup screens are gone
//      from the repo, and every door — the profile page's button, the profile
//      dropdown's row, the bar's Continue and the two named routes — arrives
//      at OneRegistrationScreen.
//
// No network, no Supabase, no goldens: the payloads are fixtures.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/services/registration_bar.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/bottom_stack.dart';
import 'package:pharma_b2b/widgets/update_bar.dart';

const double _navHeight = 56;

const _regPayload = <String, dynamic>{
  'show': true,
  'reason': 'registration_pending',
  'title': 'Registration pending',
  'cta': 'Continue',
  'route': '/complete-registration',
  'anchor': '',
  'poll_seconds': 300,
};

const _regDocsPayload = <String, dynamic>{
  'show': true,
  'reason': 'documents_pending',
  'title': 'Registration pending',
  'cta': 'Continue',
  'route': '/complete-registration',
  'anchor': 'documents',
  'poll_seconds': 300,
};

const _updatePayload = <String, dynamic>{
  'show': true,
  'title': 'App update available',
  'cta': 'Update Now',
  'updating_label': 'Fetching the new build…',
};

String _read(String p) => File(p).readAsStringSync();

class _Recorder extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) {
    pushed.add(route);
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

Widget _host(CartModel cart, _Recorder nav, {bool hasNav = true}) => MaterialApp(
      navigatorObservers: [nav],
      routes: {
        '/complete-registration': (_) =>
            const Scaffold(body: Center(child: Text('THE ONE FORM'))),
      },
      home: Scaffold(
        bottomNavigationBar: hasNav
            ? const SizedBox(height: _navHeight, child: ColoredBox(
                color: Color(0xFFEEEEEE), child: Center(child: Text('nav'))))
            : null,
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

  group('the controller is the payload and nothing else', () {
    test('show:false, a null answer and a wordless payload are all no bar', () {
      final c = RegistrationBarController();
      c.adopt(null);
      expect(c.visible, isFalse);
      c.adopt(const {'show': false, 'title': 'Registration pending'});
      expect(c.visible, isFalse);
      // The dangerous one: the backend said show, but sent no sentence.
      c.adopt(const {'show': true, 'title': ''});
      expect(c.visible, isFalse,
          reason: 'a pill with no words is not a bar');
    });

    test('every string printed is read straight out of the payload', () {
      final c = RegistrationBarController();
      c.adopt(Map<String, dynamic>.from(_regDocsPayload));
      expect(c.visible, isTrue);
      expect(c.label, 'Registration pending');
      expect(c.actionLabel, 'Continue');
      expect(c.route, '/complete-registration');
      expect(c.anchor, 'documents');
    });

    test('a failed fetch leaves no bar behind', () async {
      RegistrationBarFeed.rpcTransport = (fn, p) async => throw StateError('down');
      final c = RegistrationBarController();
      c.adopt(Map<String, dynamic>.from(_regPayload));
      expect(c.visible, isTrue);
      await c.refresh();
      expect(c.visible, isFalse,
          reason: 'an unreachable backend must not keep an ask on screen');
    });

    test('the poll cadence is the backend\'s, and is clamped', () {
      const fallback = Duration(minutes: 5);
      expect(RegistrationBarFeed.pollInterval(null, fallback), fallback);
      expect(RegistrationBarFeed.pollInterval(const {'poll_seconds': 5}, fallback),
          fallback, reason: 'a bad config cannot make this a polling loop');
      expect(RegistrationBarFeed.pollInterval(const {'poll_seconds': 900}, fallback),
          const Duration(seconds: 900));
    });
  });

  group('ONE slot, and the update outranks the registration ask', () {
    testWidgets('the registration bar renders in the update bar\'s own box',
        (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(Map<String, dynamic>.from(_regPayload));
      await t.pumpAndSettle();

      expect(find.byKey(kRegistrationBarKey), findsOneWidget);
      // The SAME widget — that is what makes the two bars the same bar.
      expect(find.byType(UpdateBar), findsOneWidget);
      expect(find.text('Registration pending'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      // And the same box: one slot tall, flush, full width.
      expect(t.getSize(find.byKey(kBarSlotKey)).height,
          BottomStackMetrics.slot);
    });

    testWidgets('both pending shows ONLY the update', (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(Map<String, dynamic>.from(_regPayload));
      appUpdateBar.show(onUpdate: () {}, payload: _updatePayload);
      await t.pumpAndSettle();

      expect(find.text('App update available'), findsOneWidget);
      expect(find.text('Registration pending'), findsNothing);
      expect(find.byKey(kRegistrationBarKey), findsNothing);
      // Still ONE bar in ONE slot — never two stacked.
      expect(find.byType(UpdateBar), findsOneWidget);
      expect(t.getSize(find.byKey(kBarSlotKey)).height,
          BottomStackMetrics.slot);
    });

    testWidgets('once the app is updated the registration ask takes the slot',
        (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(Map<String, dynamic>.from(_regPayload));
      appUpdateBar.show(onUpdate: () {}, payload: _updatePayload);
      await t.pumpAndSettle();
      expect(find.text('App update available'), findsOneWidget);

      appUpdateBar.hide();
      await t.pumpAndSettle();
      expect(find.text('Registration pending'), findsOneWidget);
      expect(find.byKey(kRegistrationBarKey), findsOneWidget);
    });

    testWidgets('no nav under it, no bar — same rule as the update bar',
        (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav, hasNav: false));
      appRegistrationBar.adopt(Map<String, dynamic>.from(_regPayload));
      await t.pumpAndSettle();
      expect(find.byKey(kRegistrationBarKey), findsNothing);
    });

    testWidgets('nothing owed is an empty slot, 0 tall', (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      await t.pumpAndSettle();
      expect(find.byType(UpdateBar), findsNothing);
      expect(t.getSize(find.byKey(kBarSlotKey)).height, 0);
    });

    for (final width in const [320.0, 360.0, 412.0, 480.0]) {
      testWidgets('at ${width.toInt()}px it fits, with a 44px button', (t) async {
        final nav = _Recorder();
        await _pump(t, _host(await _cart(), nav), width: width);
        appRegistrationBar.adopt(Map<String, dynamic>.from(_regPayload));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        final button = find.descendant(
            of: find.byKey(kRegistrationBarKey),
            matching: find.byType(FilledButton));
        expect(t.getSize(button).height, greaterThanOrEqualTo(44));
      });
    }
  });

  group('Continue opens the address the backend named', () {
    testWidgets('with its anchor, when the papers are what is out', (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(Map<String, dynamic>.from(_regDocsPayload));
      await t.pumpAndSettle();

      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();

      expect(find.text('THE ONE FORM'), findsOneWidget);
      final route = nav.pushed.last;
      expect(route.settings.name, '/complete-registration');
      expect(route.settings.arguments, {'anchor': 'documents'});
    });

    testWidgets('and with no anchor when the form itself is what is out',
        (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(Map<String, dynamic>.from(_regPayload));
      await t.pumpAndSettle();

      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();
      expect(nav.pushed.last.settings.arguments, isNull);
    });

    testWidgets('an empty route opens nothing rather than guessing one',
        (t) async {
      final nav = _Recorder();
      await _pump(t, _host(await _cart(), nav));
      appRegistrationBar.adopt(<String, dynamic>{..._regPayload, 'route': ''});
      await t.pumpAndSettle();
      final before = nav.pushed.length;

      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();
      expect(nav.pushed.length, before);
      expect(t.takeException(), isNull);
    });
  });

  group('there is ONE registration screen, and every door reaches it', () {
    test('the old self-signup screens are gone from the repo', () {
      expect(File('lib/screens/auth/business_details_screen.dart').existsSync(),
          isFalse, reason: 'the old self Complete Registration screen');
      expect(
          File('lib/screens/auth/complete_registration_screen.dart').existsSync(),
          isFalse);
      // And nothing still names them.
      for (final path in const [
        'lib/screens/profile_screen.dart',
        'lib/main.dart',
      ]) {
        expect(_read(path).contains('BusinessDetailsScreen'), isFalse,
            reason: '$path still reaches the deleted screen');
      }
    });

    test('both named routes and the profile page open OneRegistrationScreen', () {
      final main = _read('lib/main.dart');
      expect(main.contains("'/complete-registration': (_) => const OneRegistrationScreen()"),
          isTrue);
      expect(main.contains("'/customer/documents': (_) => const OneRegistrationScreen()"),
          isTrue);
      expect(_read('lib/screens/profile_screen.dart')
              .contains('const OneRegistrationScreen()'),
          isTrue);
    });

    test('the profile dropdown has a door, and it is the same screen', () {
      final menu = _read('lib/screens/customer/profile_account_menu.dart');
      expect(menu.contains("'cust_registration' => const OneRegistrationScreen()"),
          isTrue,
          reason: 'the dropdown row customer_surfaces() synthesises');
    });

    test('the orange Home block is deleted, not hidden', () {
      expect(_read('lib/screens/home_shell.dart').contains('RegistrationBanner'),
          isFalse);
      expect(
          _read('lib/widgets/customer_surface_widgets.dart')
              .contains('class RegistrationBanner'),
          isFalse);
    });

    test('the shop pin is Google only, with no tile fallback behind it', () {
      final pin = _read('lib/widgets/store_pin_picker.dart');
      // The requirement is the BACKEND's word, passed through.
      expect(pin.contains('requireProvider'), isTrue);
      expect(pin.contains("_s('provider')"), isTrue);
      // The requirement is the payload's word (`geo.provider`), so the picker
      // itself never names a provider.
      expect(pin.contains("requireProvider: _s('provider')"), isTrue);
      // And the accurate fix, not the first cached one.
      expect(pin.contains('DeviceLocation.best()'), isTrue);
      final map = _read('lib/widgets/adaptive_map.dart');
      expect(map.contains("widget.requireProvider == 'google' && !cfg.usesGoogleJs"),
          isTrue, reason: 'no OSM fallback under the shop pin');
    });
  });
}
