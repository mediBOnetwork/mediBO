// PROTECTED — CMD #2116: one rectangle for every bottom bar, and a logout that
// always arrives somewhere.
//
// See CLAUDE.md: this runs before EVERY deploy and may only be edited by a
// CHANGE that deliberately changes this behaviour, never to make an unrelated
// change go green.
//
// TWO BUGS, BOTH OF THEM "NEARLY RIGHT".
//
//   1. #2112/#2114 made the update bar, the registration bar and the login bar
//      ONE widget in ONE slot, so that "same position, same shape, same size"
//      would be structural rather than a coincidence. One measurement was
//      still left to chance: the button sized itself to its own LABEL, so
//      `Continue` drew a wider box than `Login` and the two bars did not line
//      up when a visitor saw one after the other. It also meant a backend
//      reword moved the chrome, which is the opposite of what a
//      backend-owned string is for. What is held down here: every bar's action
//      button is [Ds.touch.barActionWidth] x [Ds.touch.minTarget] EXACTLY,
//      whatever word is in it, at every phone width.
//
//   2. A logout landed only if a chain of network calls all came back. When
//      one did not — an already-expired session, an offline device, an SDK
//      call that never answered — the user was left on a role-guarded screen
//      behind a spinner with nothing able to move them. The landing is now the
//      navigator's job alone: [landOnRoute] REPLACES the whole stack, and it
//      still lands when the backend's address does not resolve.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_navigator.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/services/admin_date_scope.dart';
import 'package:pharma_b2b/services/admin_zone_scope.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/update_bar.dart';

/// The slot both bars are given by the bottom stack.
const double _slot = 56;

/// One bar, exactly as [StorefrontBottomStack] builds it: same widget, same
/// fixed slot height, differing only in icon, sentence and button word — which
/// is the whole list of things that are ALLOWED to differ.
Widget _bar({
  required String title,
  required String cta,
  required IconData icon,
}) =>
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: UpdateBar(
            title: title,
            actionLabel: cta,
            updatingLabel: cta,
            updating: false,
            leading: icon,
            fixedHeight: _slot,
            onUpdate: () {},
          ),
        ),
      ),
    );

Future<({Size bar, Size button, Offset buttonRight, Size icon})> _measure(
  WidgetTester t,
  Widget w,
  double width,
) async {
  t.view.physicalSize = Size(width, 800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(w);
  await t.pumpAndSettle();
  final button = find.byType(FilledButton);
  final bar = find.byType(UpdateBar);
  // The gear/person circle: the first Icon in the bar.
  final icon = find.descendant(of: bar, matching: find.byType(Icon)).first;
  return (
    bar: t.getSize(bar),
    button: t.getSize(button),
    buttonRight: t.getTopRight(button),
    icon: t.getSize(icon),
  );
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('1. the two bars are one rectangle', () {
    for (final width in <double>[360, 412]) {
      testWidgets('Login and Continue draw the identical box at ${width}px',
          (t) async {
        final login = await _measure(
            t,
            _bar(
                title: 'New Here?',
                cta: 'Login',
                icon: Icons.person_outline),
            width);
        final reg = await _measure(
            t,
            _bar(
                title: 'Registration pending',
                cta: 'Continue',
                icon: Icons.assignment_outlined),
            width);

        expect(login.bar, reg.bar,
            reason: 'the bar itself is one box at one height');
        expect(login.button, reg.button,
            reason:
                'the button is a TOKEN-sized rectangle, never sized to its own '
                'word — "Login" is shorter than "Continue" and that must not '
                'show');
        expect(login.buttonRight, reg.buttonRight,
            reason: 'and it sits in the same place, so the bars line up');
        expect(login.icon, reg.icon,
            reason: 'the icon circle is one size; only the GLYPH differs');
      });
    }

    testWidgets('the button is exactly the backend design token, not its label',
        (t) async {
      for (final cta in const ['Login', 'Continue', 'Update Now', 'Go']) {
        final m = await _measure(
            t,
            _bar(title: 'New Here?', cta: cta, icon: Icons.person_outline),
            360);
        expect(m.button.width, Ds.touch.barActionWidth,
            reason: '"$cta" must not change how wide the button is');
        expect(m.button.height, Ds.touch.minTarget,
            reason: '"$cta" must not change how tall the button is');
      }
    });

    testWidgets('an over-long word scales down — it never widens or clips',
        (t) async {
      final m = await _measure(
          t,
          _bar(
              title: 'New Here?',
              cta: 'A very long button label indeed',
              icon: Icons.person_outline),
          360);
      expect(m.button.width, Ds.touch.barActionWidth);
      expect(m.button.height, Ds.touch.minTarget);
      expect(find.text('A very long button label indeed'), findsOneWidget,
          reason: 'the backend word is printed, shrunk to fit, never ellipsed '
              'away and never allowed to push the box wider');
    });

    testWidgets('the tap target is still at least 44 px', (t) async {
      final m = await _measure(
          t,
          _bar(title: 'New Here?', cta: 'Login', icon: Icons.person_outline),
          360);
      expect(m.button.height, greaterThanOrEqualTo(44.0));
      expect(m.button.width, greaterThanOrEqualTo(44.0));
    });

    test('the width is a backend token, so retuning it is an UPDATE', () {
      final was = Ds.touch.barActionWidth;
      expect(was, 120,
          reason: 'the shipped default, matching the ui_design seed');
      addTearDown(() => Ds.apply({
            'touch': {'barActionWidth': was}
          }));
      Ds.apply(const {
        'touch': {'barActionWidth': 148}
      });
      expect(Ds.touch.barActionWidth, 148,
          reason: 'ui_design_set retunes the button with no deploy');
    });
  });

  group('2. a logout always arrives somewhere', () {
    Widget app(GlobalKey<NavigatorState> key) => MaterialApp(
          navigatorKey: key,
          routes: {
            '/store': (_) => const Scaffold(body: Text('STORE')),
            '/dashboard': (_) => const Scaffold(body: Text('DASHBOARD')),
          },
          home: const Scaffold(body: Text('PUBLIC HOME')),
        );

    testWidgets('it replaces the WHOLE stack — nothing pushed survives',
        (t) async {
      await t.pumpWidget(app(appNavigatorKey));
      final nav = appNavigatorKey.currentState!;
      nav.pushNamed('/dashboard');
      await t.pumpAndSettle();
      nav.pushNamed('/store');
      await t.pumpAndSettle();
      expect(find.text('STORE'), findsOneWidget);

      landOnRoute('/');
      await t.pumpAndSettle();

      expect(find.text('PUBLIC HOME'), findsOneWidget);
      expect(find.text('STORE'), findsNothing);
      expect(find.text('DASHBOARD'), findsNothing);
      expect(nav.canPop(), isFalse,
          reason: 'a role-guarded screen left one pop away is a screen the '
              'signed-out user can still reach');
    });

    testWidgets('an empty route from the backend still lands on the root',
        (t) async {
      await t.pumpWidget(app(appNavigatorKey));
      appNavigatorKey.currentState!.pushNamed('/dashboard');
      await t.pumpAndSettle();
      landOnRoute('   ');
      await t.pumpAndSettle();
      expect(find.text('PUBLIC HOME'), findsOneWidget);
      expect(appNavigatorKey.currentState!.canPop(), isFalse);
    });

    testWidgets('an address that does not resolve still lands on the root',
        (t) async {
      await t.pumpWidget(app(appNavigatorKey));
      appNavigatorKey.currentState!.pushNamed('/dashboard');
      await t.pumpAndSettle();
      landOnRoute('/a-route-this-build-does-not-have');
      await t.pumpAndSettle();
      expect(find.text('PUBLIC HOME'), findsOneWidget,
          reason: 'a mis-seeded logout_route must not strand the user on the '
              'previous account\'s screen');
      expect(appNavigatorKey.currentState!.canPop(), isFalse);
    });

    testWidgets('landing is repeatable — logout, login, logout', (t) async {
      await t.pumpWidget(app(appNavigatorKey));
      for (var i = 0; i < 3; i++) {
        appNavigatorKey.currentState!.pushNamed('/dashboard');
        await t.pumpAndSettle();
        expect(find.text('DASHBOARD'), findsOneWidget);
        landOnRoute('/');
        await t.pumpAndSettle();
        expect(find.text('PUBLIC HOME'), findsOneWidget);
      }
    });

    test('no navigator yet is nothing to do, never a throw', () {
      expect(() => landOnRoute('/'), returnsNormally);
    });
  });

  group('3. nothing of the previous account survives the switch', () {
    test('the zone scope forgets its answer, so the next account is asked', () {
      final z = AdminZoneScope.instance;
      expect(z.isLoaded, isFalse);
      z.clear();
      expect(z.isLoaded, isFalse);
      expect(z.show, isFalse);
      expect(z.selectedZoneId, isNull);
      expect(z.selectedLabel, '');
      expect(z.options, isEmpty);
    });

    test('so does the date scope', () {
      final d = AdminDateScope.instance;
      d.clear();
      expect(d.isLoaded, isFalse,
          reason: 'ensureLoaded() only ever asks once — a date left loaded is '
              'the date the NEXT account\'s lists open on');
      expect(d.dateYmd, isNull);
      expect(d.options, isEmpty);
    });
  });
}
