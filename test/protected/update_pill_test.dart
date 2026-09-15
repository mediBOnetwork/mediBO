// PROTECTED — CMD #2028, the floating app-update pill.
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
//   2. IT FLOATS, AND THE BACKEND SAYS HOW HIGH. `bottom_gap` lifts the pill
//      clear of the bottom nav AND the floating cart pill; the pill itself is
//      inset from both screen edges. A nav that grows is an UPDATE, not a
//      deploy.
//
//   3. THERE IS NO WAY OUT BUT UPDATING. One button, no Later, no dismiss, no
//      close icon, no version text. A Play flow that fails or is cancelled
//      hands the button BACK (markIdle) — it never takes the bar away, because
//      the update is still pending.
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
import 'package:pharma_b2b/services/app_update_feed.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';
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

/// Deliberately different words, so a test that passes on the ui_copy path
/// instead of the payload path is visible.
const _copy = <String, String>{
  'update_bar.title': 'FALLBACK TITLE',
  'update_bar.action': 'FALLBACK ACTION',
  'update_bar.updating': 'FALLBACK UPDATING',
};

Widget _host(UpdateBarController ctrl) => MaterialApp(
      home: Scaffold(
        body: UpdateBarHost(
          controller: ctrl,
          child: const Center(child: Text('page content')),
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

  group('the pill prints the backend payload', () {
    testWidgets('sentence and button word are the payload\'s, verbatim',
        (t) async {
      final ctrl = UpdateBarController();
      await t.pumpWidget(_host(ctrl));
      ctrl.show(onUpdate: () {}, payload: _payload);
      await t.pumpAndSettle();

      expect(find.text('App update available'), findsOneWidget);
      expect(find.text('Update Now'), findsOneWidget);
      expect(find.text('FALLBACK TITLE'), findsNothing);
      expect(find.text('FALLBACK ACTION'), findsNothing);
    });

    testWidgets('the updating word is the payload\'s, not ui_copy\'s',
        (t) async {
      final ctrl = UpdateBarController();
      await t.pumpWidget(_host(ctrl));
      ctrl.show(onUpdate: ctrl.markUpdating, payload: _payload);
      await t.pumpAndSettle();

      await t.tap(find.text('Update Now'));
      await t.pumpAndSettle();

      expect(find.text('Fetching the new build…'), findsOneWidget);
      expect(find.text('FALLBACK UPDATING'), findsNothing);
    });

    testWidgets('Android: the download landing swaps to the backend\'s '
        'restarting word', (t) async {
      final ctrl = UpdateBarController();
      await t.pumpWidget(_host(ctrl));
      ctrl.show(onUpdate: () {}, payload: _payload);
      await t.pumpAndSettle();

      ctrl.markDownloaded();
      await t.pumpAndSettle();

      expect(find.text('Restarting mediBO…'), findsOneWidget);
      expect(find.text('Update Now'), findsNothing);
    });

    testWidgets('no payload → ui_copy, so an unreachable backend still speaks',
        (t) async {
      final ctrl = UpdateBarController();
      await t.pumpWidget(_host(ctrl));
      ctrl.show(onUpdate: () {});
      await t.pumpAndSettle();

      expect(find.text('FALLBACK TITLE'), findsOneWidget);
      expect(find.text('FALLBACK ACTION'), findsOneWidget);
    });
  });

  group('it floats, and the backend says how high', () {
    testWidgets('bottom_gap lifts the pill clear of the nav and the cart pill',
        (t) async {
      t.view.physicalSize = const Size(412, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final ctrl = UpdateBarController();
      await t.pumpWidget(_host(ctrl));
      ctrl.show(onUpdate: () {}, payload: _payload);
      await t.pumpAndSettle();

      final screen = t.getSize(find.byType(MaterialApp));
      final pill = t.getRect(find.byType(FilledButton));
      // The button's bottom edge must sit at least the backend's gap above the
      // bottom of the screen — that is the whole point of "floating above the
      // bottom nav and cart pill".
      expect(screen.height - pill.bottom,
          greaterThanOrEqualTo(_payload['bottom_gap'] as int));
    });

    testWidgets('the pill is inset from both screen edges', (t) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final ctrl = UpdateBarController();
      await t.pumpWidget(_host(ctrl));
      ctrl.show(onUpdate: () {}, payload: _payload);
      await t.pumpAndSettle();

      // The host is full-bleed (so it can overlay anything) but the white pill
      // inside it keeps a margin on each side.
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

        final ctrl = UpdateBarController();
        await t.pumpWidget(_host(ctrl));
        ctrl.show(onUpdate: () {}, payload: _payload);
        await t.pumpAndSettle();

        expect(t.takeException(), isNull);
        expect(t.getSize(find.byType(FilledButton)).height,
            greaterThanOrEqualTo(Ds.touch.minTarget));
      });
    }
  });

  group('there is no way out but updating', () {
    testWidgets('one button, no Later, no dismiss, no version text', (t) async {
      final ctrl = UpdateBarController();
      await t.pumpWidget(_host(ctrl));
      ctrl.show(onUpdate: () {}, payload: _payload);
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

    testWidgets('a cancelled Play flow hands the button back, never the screen',
        (t) async {
      final ctrl = UpdateBarController();
      await t.pumpWidget(_host(ctrl));
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
