// PROTECTED — CMD #2028 / #2066, the app-update bar.
//
// See CLAUDE.md: this runs before EVERY deploy and may only be edited by a
// CHANGE that deliberately changes this behaviour, never to make an unrelated
// change go green.
//
// What it holds down — the four things that made the old prompt wrong:
//
//   1. THE PILL PRINTS THE PAYLOAD. Sentence, button word, the "updating" word
//      and the Android "restarting" word all arrive in `app_update_bar()` and
//      are printed verbatim. ui_copy is the fallback for an unreachable
//      backend, never the source. The fixture deliberately uses words no Dart
//      file could have coined.
//
//   2. IT SITS IN A RESERVED SLOT, ON THE NAV, AND NOWHERE ELSE. CMD #2066
//      replaced "it floats, and the backend says how high" — `bottom_gap`
//      lifting the bar clear of the nav and the cart pill — with a column of
//      fixed boxes. The bar is FLUSH on the top of the bottom nav, exactly one
//      slot tall however long the sentence is, and `bottom_gap` is IGNORED:
//      a number the backend can change is a position that can move, and every
//      position in this chrome is static. It also renders only where a bottom
//      navigation bar exists — a route pushed over the shell has no edge for
//      it to sit on and gets no bar.
//
//   3. THERE IS NO LATER, ON ANY PLATFORM, WHATEVER THE PAYLOAD SAYS.
//      CMD #2065 made the dismiss the backend's; CMD #2112 removed it. The
//      pill carries ONE control — Update Now — and it stays up until the
//      update lands, because an update a shop can postpone for a day reaches
//      it a day late, and this slot is now shared with the registration bar
//      (where a dismissed pill would read as "nothing owed"). A payload that
//      still carries dismissible:true and a dismiss_label draws NO control:
//      the removal is in the widget, not in a flag anyone can flip back. A
//      Play flow that fails or is cancelled still hands the button BACK
//      (markIdle) rather than taking the bar away.
//
//   5. CMD #2065 — EACH PLATFORM ANSWERS ITS OWN QUESTION, AND ANDROID'S IS
//      PLAY'S. The Android driver asks the In-App Update API and reports the
//      verdict verbatim; 'unknown' and 'none' are not updates. The web watcher
//      never runs off the web at all, so a phone can no longer be told about a
//      build that lives on a CDN. These are the four lines that made "Update
//      Now does nothing" possible.
//
//   4. NEITHER PLATFORM DECIDES ANYTHING. The web watcher no longer runs a
//      countdown and reloads only after clearing caches; the Android driver
//      passes the backend's `flow` through untouched. Both are source
//      assertions, because a timer that comes back would be invisible to a
//      widget test until it fired in production.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/services/android_update_bar.dart';
import 'package:pharma_b2b/services/app_update_feed.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/bottom_stack.dart';
import 'package:pharma_b2b/widgets/update_bar.dart';

/// Backend copy. Nothing here reads like something a Dart file would say.
const _payload = <String, dynamic>{
  'show': true,
  'platform': 'android',
  'label': 'App update available',
  'button_label': 'Update Now',
  'updating_label': 'Fetching the new build…',
  'downloaded_label': 'Restarting mediBO…',
  'flow': 'flexible',
  'poll_seconds': 300,
  'bottom_gap': 128,
};

/// CMD #2112 — a payload that STILL carries the old Later. Kept deliberately:
/// the bar must draw no control for it, so the removal cannot be undone by a
/// stale `app_update_check()` on a slow-to-replay database.
const _dismissable = <String, dynamic>{
  ..._payload,
  'dismissible': true,
  'dismiss_label': 'Not right now',
  'forced': false,
};

/// A forced update: the backend withheld both, so there is no way out.
const _forced = <String, dynamic>{
  ..._payload,
  'dismissible': false,
  'dismiss_label': null,
  'forced': true,
};

/// Deliberately different words, so a test that passes on the ui_copy path
/// instead of the payload path is visible.
const _copy = <String, String>{
  'update_bar.title': 'FALLBACK TITLE',
  'update_bar.action': 'FALLBACK ACTION',
  'update_bar.updating': 'FALLBACK UPDATING',
};

/// CMD #2066 — the bar has ONE renderer: the reserved slot of the shared
/// bottom stack, which only a shell with a bottom navigation bar mounts. The
/// app-level `UpdateBarHost` that wrapped every route is deleted — wrapping
/// everything is how the bar reached login, the cart and every pushed page.
const double _navHeight = 64;

Widget _host({bool hasNav = true}) => MaterialApp(
      home: Scaffold(
        bottomNavigationBar:
            hasNav ? const SizedBox(height: _navHeight) : null,
        body: Stack(
          children: const [
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
    );

String _read(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '$path must exist');
  return f.readAsStringSync();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(_copy);
  });
  // One long-lived controller for the whole app now, so each test hands it
  // back the way it found it.
  tearDown(appUpdateBar.reset);

  group('the pill prints the backend payload', () {
    testWidgets('sentence and button word are the payload\'s, verbatim',
        (t) async {
      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      ctrl.show(onUpdate: () {}, payload: _payload);
      await t.pumpAndSettle();

      expect(find.text('App update available'), findsOneWidget);
      expect(find.text('Update Now'), findsOneWidget);
      expect(find.text('FALLBACK TITLE'), findsNothing);
      expect(find.text('FALLBACK ACTION'), findsNothing);
    });

    testWidgets('the updating word is the payload\'s, not ui_copy\'s',
        (t) async {
      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      ctrl.show(onUpdate: ctrl.markUpdating, payload: _payload);
      await t.pumpAndSettle();

      await t.tap(find.text('Update Now'));
      await t.pumpAndSettle();

      expect(find.text('Fetching the new build…'), findsOneWidget);
      expect(find.text('FALLBACK UPDATING'), findsNothing);
    });

    testWidgets('Android: the download landing swaps to the backend\'s '
        'restarting word', (t) async {
      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      ctrl.show(onUpdate: () {}, payload: _payload);
      await t.pumpAndSettle();

      ctrl.markDownloaded();
      await t.pumpAndSettle();

      expect(find.text('Restarting mediBO…'), findsOneWidget);
      expect(find.text('Update Now'), findsNothing);
    });

    testWidgets('no payload → ui_copy, so an unreachable backend still speaks',
        (t) async {
      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      ctrl.show(onUpdate: () {});
      await t.pumpAndSettle();

      expect(find.text('FALLBACK TITLE'), findsOneWidget);
      expect(find.text('FALLBACK ACTION'), findsOneWidget);
    });
  });

  group('it sits in a reserved slot, on the nav', () {
    testWidgets('flush on the nav — the backend\'s bottom_gap does not lift it',
        (t) async {
      t.view.physicalSize = const Size(412, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      ctrl.show(onUpdate: () {}, payload: _payload);
      await t.pumpAndSettle();

      final screen = t.getSize(find.byType(MaterialApp));
      final bar = t.getRect(find.byType(UpdateBar));

      // FLUSH: the bar's bottom edge IS the top of the nav. The fixture
      // carries `bottom_gap: 128` on purpose — #2066 ignores it, so a backend
      // number can never move this chrome again.
      expect(bar.bottom, closeTo(screen.height - _navHeight, 0.5),
          reason: 'bottom_gap must not lift the bar off the nav');
      expect(bar.height, closeTo(BottomStackMetrics.slot, 0.5),
          reason: 'exactly one slot tall, not a height it chose for itself');
    });

    testWidgets('no bottom nav, no bar — however loud the controller is',
        (t) async {
      t.view.physicalSize = const Size(412, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final ctrl = appUpdateBar;
      await t.pumpWidget(_host(hasNav: false));
      ctrl.show(onUpdate: () {}, payload: _payload);
      await t.pumpAndSettle();

      expect(ctrl.visible, isTrue);
      expect(find.byType(UpdateBar), findsNothing,
          reason: 'a pushed route has no nav for the bar to sit on');
      expect(find.text('App update available'), findsNothing);
    });

    testWidgets('the pill is inset from both screen edges', (t) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      ctrl.show(onUpdate: () {}, payload: _payload);
      await t.pumpAndSettle();

      // The bar is edge to edge (it is the top surface of the bottom chrome)
      // and its CONTENT keeps a margin on each side.
      final bar = t.getRect(find.byType(UpdateBar));
      final gear = t.getRect(find.byType(Icon));
      expect(gear.left - bar.left, greaterThanOrEqualTo(Ds.space.x16));
      expect(bar.width, 360);
      expect(t.takeException(), isNull, reason: 'no overflow at 360 px');
    });

    for (final width in <double>[320, 360, 412, 480]) {
      testWidgets('no overflow at $width px', (t) async {
        t.view.physicalSize = Size(width, 800);
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);

        final ctrl = appUpdateBar;
        await t.pumpWidget(_host());
        ctrl.show(onUpdate: () {}, payload: _payload);
        await t.pumpAndSettle();

        expect(t.takeException(), isNull);
        expect(t.getSize(find.byType(FilledButton)).height,
            greaterThanOrEqualTo(Ds.touch.minTarget));
      });
    }
  });

  group('there is no Later, and no payload can bring one back', () {
    testWidgets('a forced update has no dismiss control at all', (t) async {
      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      // dismissible:false is what `forced` looks like on the wire.
      ctrl.show(onUpdate: () {}, payload: _forced);
      await t.pumpAndSettle();

      expect(
          find.descendant(
              of: find.byType(UpdateBar), matching: find.byType(FilledButton)),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(UpdateBar), matching: find.byType(IconButton)),
          findsNothing);

      // Exactly two strings: the sentence and the button word. No version line.
      final texts = find
          .descendant(of: find.byType(UpdateBar), matching: find.byType(Text))
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .toList();
      expect(texts, ['App update available', 'Update Now']);
    });

    testWidgets('CMD #2112 — dismissible:true and a dismiss_label draw NOTHING',
        (t) async {
      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      ctrl.show(onUpdate: () {}, payload: _dismissable);
      await t.pumpAndSettle();

      // No close control of any kind, and the backend's old word is nowhere
      // on screen: the pill has one button and it is Update Now.
      expect(
          find.descendant(
              of: find.byType(UpdateBar), matching: find.byType(IconButton)),
          findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text('Not right now'), findsNothing);
      final texts = find
          .descendant(of: find.byType(UpdateBar), matching: find.byType(Text))
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .toList();
      expect(texts, ['App update available', 'Update Now']);
    });

    testWidgets('the controller has no dismissal to offer either', (t) async {
      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      ctrl.show(onUpdate: () {}, payload: _dismissable);
      await t.pumpAndSettle();
      // `hide()` survives — it is how a landed update, or a driver that
      // decided there is no update after all, takes the bar down. What is
      // gone is any USER path to it.
      ctrl.hide();
      await t.pumpAndSettle();
      expect(find.byType(UpdateBar), findsNothing);
      expect(find.byKey(kBarSlotKey), findsOneWidget);
    });

    testWidgets('no dismiss_label, no control — unchanged', (t) async {
      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      ctrl.show(onUpdate: () {}, payload: _payload);
      await t.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byType(UpdateBar), matching: find.byType(IconButton)),
          findsNothing);
    });

    testWidgets('while the update runs the one button is the updating word',
        (t) async {
      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      ctrl.show(onUpdate: ctrl.markUpdating, payload: _dismissable);
      await t.pumpAndSettle();

      await t.tap(find.text('Update Now'));
      await t.pumpAndSettle();
      expect(find.text('Fetching the new build…'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(UpdateBar), matching: find.byType(IconButton)),
          findsNothing);
    });

    testWidgets('a cancelled Play flow hands the button back, never the screen',
        (t) async {
      final ctrl = appUpdateBar;
      await t.pumpWidget(_host());
      ctrl.show(onUpdate: ctrl.markUpdating, payload: _payload);
      await t.pumpAndSettle();

      await t.tap(find.text('Update Now'));
      await t.pumpAndSettle();
      expect(find.text('Fetching the new build…'), findsOneWidget);

      ctrl.markIdle();
      await t.pumpAndSettle();

      // The bar is still up — the update has not happened — and it is tappable
      // again.
      expect(find.byType(UpdateBar), findsOneWidget);
      expect(find.text('Update Now'), findsOneWidget);
      expect(t.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull);
    });
  });

  group('neither platform decides anything', () {
    test('the poll cadence is the backend\'s, and is clamped', () {
      expect(AppUpdateFeed.pollInterval(_payload, const Duration(minutes: 1)),
          const Duration(seconds: 300));
      // A missing or absurd number falls back rather than becoming a loop.
      expect(AppUpdateFeed.pollInterval(const {}, const Duration(minutes: 5)),
          const Duration(minutes: 5));
      expect(
          AppUpdateFeed.pollInterval(
              const {'poll_seconds': 1}, const Duration(minutes: 5)),
          const Duration(minutes: 5));
    });

    test('the web watcher has no countdown and clears caches before reloading',
        () {
      final vw = _read('lib/services/version_watcher.dart');
      expect(vw.contains('_autoReload'), isFalse,
          reason: 'the 6 s auto-reload could yank a customer out of a cart');
      expect(vw.contains('hardReloadPage()'), isTrue,
          reason: 'Update Now must clear caches, not just reload');
      expect(vw.contains('AppUpdateFeed.pollInterval'), isTrue,
          reason: 'the cadence is the backend\'s');
      expect(vw.contains('AppLifecycleState.resumed'), isTrue,
          reason: 'a backgrounded tab must re-check on foreground');
    });

    test('the Android driver passes the backend flow through untouched', () {
      final a = _read('lib/services/android_update_bar.dart');
      expect(a.contains('PlayUpdateChannel.instance.start(flow)'), isTrue);
      // No Dart-side rule about which flow to run.
      expect(a.contains("? 'immediate'"), isFalse);
      expect(a.contains('min_version_code'), isFalse,
          reason: 'the minimum version lives in app_settings, not in Dart');
    });

    // ── CMD #2065 — each platform answers its own question ───────────────
    test('Android reports PLAY\'s verdict, and unknown is never an update', () {
      // The mapping is pure, so the words that reach the backend are held down
      // without a device. 'none' and 'unknown' are DIFFERENT facts: which of
      // them is an update is the backend's call, and neither of them is.
      expect(AndroidUpdateBar.playState(const {'available': true}),
          'update_available');
      expect(AndroidUpdateBar.playState(const {'available': false}), 'none');
      expect(
          AndroidUpdateBar.playState(
              const {'available': false, 'inProgress': true}),
          'in_progress');
      // Play could not be reached / no Play Store / sideloaded.
      expect(AndroidUpdateBar.playState(const {}), 'unknown');
    });

    test('the Android driver asks Play first and compares no web build', () {
      final a = _read('lib/services/android_update_bar.dart');
      expect(a.contains('PlayUpdateChannel.instance.check()'), isTrue,
          reason: 'Play is asked before the bar is raised');
      expect(a.contains('platformState: state'), isTrue,
          reason: 'the verdict is reported verbatim, not acted on here');
      // The three things the old path did, none of which may come back.
      expect(a.contains('app_published_release'), isFalse);
      expect(a.contains('version.json'), isFalse);
      expect(a.contains('liveVersion'), isFalse,
          reason: 'Android is never compared against the web build');
    });

    test('the web watcher never runs off the web', () {
      final vw = _read('lib/services/version_watcher.dart');
      expect(vw.contains('if (!kIsWeb) return;'), isTrue,
          reason: 'a phone must not be told about a build on a CDN');
    });

    test('the PWA asks the service worker, not version.json', () {
      final vw = _read('lib/services/version_watcher.dart');
      expect(vw.contains('waitingWorkerState()'), isTrue);
      expect(vw.contains('isStandalonePwa()'), isTrue,
          reason: 'a browser tab keeps the version.json answer it always had');
      final w = _read('lib/services/sw_probe_web.dart');
      expect(w.contains("'SKIP_WAITING'"), isTrue);
      // The stub must carry the same names or the native build will not link,
      // and it must answer 'none' — never 'waiting'.
      final stub = _read('lib/services/sw_probe_stub.dart');
      expect(stub.contains('waitingWorkerState'), isTrue);
      expect(stub.contains('isStandalonePwa'), isTrue);
      expect(stub.contains("'waiting'"), isFalse);
      // The worker itself has to let the waiting one through, or Update Now on
      // a PWA is a button that does nothing — the exact bug this command ends.
      expect(_read('web/firebase-messaging-sw.js').contains('skipWaiting()'),
          isTrue);
    });

    test('CMD #2112 — there is no dismissal to store, anywhere', () {
      final f = _read('lib/services/app_update_feed.dart');
      // No device memory of a Later: no key, no writer, no reader.
      expect(f.contains('app_update_dismissed_'), isFalse,
          reason: 'a 24 h hide is what CMD #2112 removed');
      expect(f.contains('markDismissed'), isFalse);
      expect(f.contains('dismissedAt'), isFalse);
      // Nothing is sent either, so a stale backend cannot start hiding it.
      expect(f.contains("'p_dismissed_at'"), isFalse);
      expect(f.contains('shared_preferences'), isFalse,
          reason: 'the only thing this file stored was the dismissal');
      // And the two drivers have no path to one.
      for (final path in const [
        'lib/services/version_watcher.dart',
        'lib/services/android_update_bar.dart',
      ]) {
        expect(_read(path).contains('onDismiss'), isFalse,
            reason: '\$path must not offer a Later');
      }
      // The widget itself carries no close control.
      final bar = _read('lib/widgets/update_bar.dart');
      expect(bar.contains('Icons.close'), isFalse);
      expect(bar.contains('dismissLabel'), isFalse);
    });

    test('the web clear-and-reload really drops caches and workers', () {
      final w = _read('lib/services/page_reload_web.dart');
      expect(w.contains('hardReloadPage'), isTrue);
      expect(w.contains('unregister'), isTrue);
      expect(w.contains('caches.delete'), isTrue);
      // The stub must carry the same name or the native build will not link.
      expect(_read('lib/services/page_reload_stub.dart').contains('hardReloadPage'),
          isTrue);
    });
  });
}
