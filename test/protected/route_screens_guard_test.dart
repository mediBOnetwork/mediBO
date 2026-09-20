// PROTECTED — CMD #2107.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change go
// green.
//
// The bug this retires: Route builder / View routes / Assign route / Today's
// visits "either did nothing, opened then closed, or closed the whole app" on
// web, PWA and Android. Three separate causes, one test file:
//
//   1. THE ANDROID PROCESS KILL. `map_config_get(p_platform)` already refuses
//      to send a platform down the Google path unless THAT platform has a key
//      — its own comment says "on Android that is a process kill, not a broken
//      map". The app never sent the argument, so Android was answered as
//      'web', told uses_google_js:true off the BROWSER key, and rendered the
//      native GoogleMap with no `com.google.android.geo.API_KEY` in the
//      manifest: IllegalStateException, PlatformException, app gone.
//      `mapPlatformName` must NAME the platform and never say 'web' off a
//      phone. It decides nothing else — which renderer a platform gets stays
//      the backend's answer.
//
//   2. THE BLANK SCREEN. Flutter's DEFAULT ErrorWidget is a bare grey
//      rectangle in a release build. Inside the shell's IndexedStack that
//      rectangle is the whole page, which on a phone reads as "it opened and
//      then closed". `installScreenGuard()` must replace it with a real error
//      state whose every word is a ui_copy row, and that state must offer a
//      way out. The exception text is NOT shown — it is already reported by
//      FlutterError.onError, and a stack trace is not an answer a pharmacy can
//      act on.
//
//   3. THE FOUR DOORS. Each Dashboard tile's `tab_screen` must resolve to a
//      section this build can land on. A key that resolves to nothing is the
//      "tap does nothing" symptom, and it is a registry row away — so the
//      pairing is asserted for all four doors as the backend actually sends
//      them today.
//
// No network, no Supabase, no camera, no goldens.

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/customer_tab_target.dart';
import 'package:pharma_b2b/services/map_config.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/screen_guard.dart';

import 'ui_copy_fixture.dart';

/// A widget that throws while building — the thing ErrorWidget.builder exists
/// for.
class _Exploding extends StatelessWidget {
  const _Exploding();
  @override
  Widget build(BuildContext context) {
    throw StateError('boom: the payload had a shape this build never saw');
  }
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    seedUiCopy();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('1 — map_config_get is told which platform is asking', () {
    test('a phone never answers "web"', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(mapPlatformName, 'android');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(mapPlatformName, 'ios');
    });

    test('a platform the backend has no key column for is still NAMED', () {
      // It must not be coerced to 'web'. map_config_get() answers `false` for
      // anything it does not key, which is the tile map — the safe path. Lying
      // about the platform is what turned a missing key into a process kill.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(mapPlatformName, 'macos');
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(mapPlatformName, 'windows');
    });
  });

  group('2 — an exception inside a screen shows an error state', () {
    testWidgets('the guard replaces Flutter\'s grey box with backend copy',
        (tester) async {
      // flutter_test asserts ErrorWidget.builder is back to the framework's
      // own before the body ends, so it is restored HERE rather than in a
      // tearDown (which runs after that check).
      final previous = ErrorWidget.builder;
      installScreenGuard();
      try {
        // The framework reports the throw; the test must not fail ON the
        // throw — surviving it is the whole point.
        await tester.pumpWidget(const MaterialApp(home: _Exploding()));
        expect(tester.takeException(), isA<StateError>());

        // The backend's words, not Dart's.
        expect(find.text('This screen hit a problem'), findsOneWidget);
        expect(find.byType(ScreenErrorState), findsOneWidget);
        // And a way out.
        expect(find.byType(OutlinedButton), findsOneWidget);
        // Never the raw exception.
        expect(find.textContaining('boom:'), findsNothing);
      } finally {
        ErrorWidget.builder = previous;
      }
    });

    testWidgets('a guarded body fails without taking the page with it',
        (tester) async {
      final previous = ErrorWidget.builder;
      installScreenGuard();
      try {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Column(children: const [
              Text('the header survives'),
              Expanded(child: ScreenGuard(child: _Exploding())),
            ]),
          ),
        ));
        expect(tester.takeException(), isA<StateError>());

        expect(find.text('the header survives'), findsOneWidget);
        expect(find.byType(ScreenErrorState), findsOneWidget);
      } finally {
        ErrorWidget.builder = previous;
      }
    });

    testWidgets('Retry is the screen\'s own action when it has one',
        (tester) async {
      var retried = 0;
      await tester.pumpWidget(MaterialApp(
        home: ScreenErrorState(onRetry: () => retried++),
      ));
      expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pump();
      expect(retried, 1);
    });

    testWidgets('with no action of its own the button goes BACK', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ScreenErrorState()));
      // The wording swaps with the action — it never offers a retry that
      // retries nothing.
      expect(find.text('Go back'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });
  });

  group('3 — the four Field & Growth doors all land somewhere', () {
    // Exactly what feature_registry.tab_screen holds for the four rows today.
    const doors = <String, String>{
      'admin.cust_tab.routes': 'routes',
      'admin.cust_tab.routes_builder': 'routes:all_plans',
      'admin.cust_tab.routes_assign': 'routes:past_plans',
      'admin.cust_tab.routes_today': 'routes:today',
    };

    test('every door opens the Routes sub-tab', () {
      for (final e in doors.entries) {
        expect(CustomerTabTarget.parse(e.value).tab, 'routes',
            reason: '${e.key} must open the Routes sub-tab');
      }
    });

    test('every SECTION a door names is one this build can land on', () {
      for (final e in doors.entries) {
        final t = CustomerTabTarget.parse(e.value);
        if (!t.hasSection) continue; // plain 'routes' names no section
        expect(kRoutesSectionModes[t.section], isNotNull,
            reason: '${e.key} names section "${t.section}", which resolves to '
                'no mode — that is the tap-does-nothing bug');
      }
    });

    test('a section this build has never heard of is IGNORED, not thrown on',
        () {
      // Forward compatibility: the registry may ship a fifth door to clients
      // already in the field.
      expect(kRoutesSectionModes['a_section_from_the_future'], isNull);
      expect(CustomerTabTarget.parse('routes:a_section_from_the_future').tab,
          'routes');
    });
  });
}
