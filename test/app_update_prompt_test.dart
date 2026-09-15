// CHANGE #282 — the in-app update prompt.
//
// The two faults this pins down were both live on real pharmacy phones:
//   • a Play-installed user was sent to a Supabase-storage APK, which Chrome
//     flagged and Android then refused to install (signature clash), and
//   • the body printed the internal changelog — "the exact signing certificate
//     this build carries and the client id it sent".
//
// So the properties asserted here are: the app sends the install source and
// renders the backend's decision VERBATIM (never picking a destination or
// coining a sentence of its own), the dismissal sticks to the backend's own
// dismiss_key, and an installed update clears it.
//
// Inline mocks only — no network, no Supabase, no platform channel.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/app_update_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Play-install payload exactly as app_update_check renders it: the action is
/// the Play listing and apk_url is ABSENT, not merely ignored.
const Map<String, dynamic> kPlayPayload = {
  'update_available': true,
  'current': '1.3.10',
  'version_name': '1.3.11',
  'version_code': 24,
  'version_label': 'Version 1.3.11',
  'channel': 'play',
  'store_name': 'Google Play',
  'install_source': 'com.android.vending',
  'action_url': 'https://play.google.com/store/apps/details?id=in.medibo.app',
  'apk_url': null,
  'mandatory': false,
  'eyebrow': 'App update available',
  'title': 'A new version of mediBO is ready',
  'message': 'Google sign-in now works reliably, plus speed and stability fixes.',
  'action_label': 'Update on Google Play',
  'dismiss_label': 'Not now',
  'dismiss_key': 'app_update:android:24',
  'dismiss_seconds': 86400,
};

final Map<String, dynamic> kSideloadPayload = {
  ...kPlayPayload,
  'channel': 'direct',
  'install_source': 'sideload',
  'action_url': 'https://cdn.example/medibo-1.3.11.apk',
  'apk_url': 'https://cdn.example/medibo-1.3.11.apk',
  'action_label': 'Download update',
};

class _Run {
  final List<String> opened = [];
  final List<String?> sources = [];
  int rpcCalls = 0;
}

Future<_Run> _pump(
  WidgetTester tester, {
  required bool isAndroid,
  Map<String, dynamic>? payload,
  bool throws = false,
  String? installSource = 'com.android.vending',
}) async {
  final run = _Run();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          key: const Key('go'),
          onPressed: () => showAppUpdatePromptIfAny(
            context,
            isAndroidOverride: isAndroid,
            installSourceOverride: installSource,
            rpcOverride: (src) async {
              run.rpcCalls++;
              run.sources.add(src);
              if (throws) throw Exception('rpc down');
              return payload;
            },
            openUrlOverride: (url) async => run.opened.add(url),
          ),
          child: const Text('go'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('go')));
  await tester.pumpAndSettle();
  return run;
}

void main() {
  setUpAll(() {
    // The render-log flush is a real 800 ms Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('not Android → the RPC is never called and nothing is shown',
      (tester) async {
    final run = await _pump(tester, isAndroid: false, payload: kPlayPayload);
    expect(run.rpcCalls, 0);
    expect(find.text('A new version of mediBO is ready'), findsNothing);
  });

  testWidgets('the install source is passed to the backend verbatim',
      (tester) async {
    final run = await _pump(tester,
        isAndroid: true,
        payload: kPlayPayload,
        installSource: 'com.android.vending');
    expect(run.sources, ['com.android.vending']);
  });

  testWidgets('Play payload renders the backend strings verbatim',
      (tester) async {
    await _pump(tester, isAndroid: true, payload: kPlayPayload);
    expect(find.text('App update available'), findsOneWidget);
    expect(find.text('A new version of mediBO is ready'), findsOneWidget);
    expect(find.text(kPlayPayload['message'] as String), findsOneWidget);
    expect(find.text('Version 1.3.11'), findsOneWidget);
    expect(find.text('Update on Google Play'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('a Play install is sent to the store, never to an APK',
      (tester) async {
    final run = await _pump(tester, isAndroid: true, payload: kPlayPayload);
    await tester.tap(find.text('Update on Google Play'));
    await tester.pumpAndSettle();
    expect(run.opened, [kPlayPayload['action_url']]);
    expect(run.opened.single.contains('.apk'), isFalse);
  });

  testWidgets('a genuine sideload still gets the APK', (tester) async {
    final run = await _pump(tester,
        isAndroid: true, payload: kSideloadPayload, installSource: 'sideload');
    await tester.tap(find.text('Download update'));
    await tester.pumpAndSettle();
    expect(run.opened, [kSideloadPayload['action_url']]);
  });

  testWidgets('mandatory → no dismiss control', (tester) async {
    await _pump(tester, isAndroid: true, payload: {
      ...kPlayPayload,
      'mandatory': true,
      'dismiss_label': null,
      'dismiss_key': null,
    });
    expect(find.text('Update on Google Play'), findsOneWidget);
    expect(find.text('Not now'), findsNothing);
  });

  testWidgets('dismissing stores the backend key WITH the moment it was tapped',
      (tester) async {
    final first = await _pump(tester, isAndroid: true, payload: kPlayPayload);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(first.opened, isEmpty);

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(kUpdateDismissedPref)!;
    // CMD #1956 — "<the backend's key>|<millis>". The key alone silenced the
    // build forever; the timestamp is what lets it come back after 24 h.
    expect(stored, startsWith('app_update:android:24|'));
    final at = int.parse(stored.split('|').last);
    expect(
      DateTime.now().millisecondsSinceEpoch - at,
      lessThan(const Duration(minutes: 1).inMilliseconds),
    );

    // Same prompt again, inside the window → stays quiet.
    await _pump(tester, isAndroid: true, payload: kPlayPayload);
    expect(find.text('A new version of mediBO is ready'), findsNothing);

    // A NEWER version CODE is a different key → the prompt asks again at once,
    // without waiting out the window.
    await _pump(tester, isAndroid: true, payload: {
      ...kPlayPayload,
      'version_code': 25,
      'dismiss_key': 'app_update:android:25',
    });
    expect(find.text('A new version of mediBO is ready'), findsOneWidget);
  });

  testWidgets('the dismissal expires after the backend window and asks again',
      (tester) async {
    // Tapped 25 hours ago, window 24 h → the prompt is due again.
    final long = DateTime.now()
        .subtract(const Duration(hours: 25))
        .millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues(
        {kUpdateDismissedPref: 'app_update:android:24|$long'});
    await _pump(tester, isAndroid: true, payload: kPlayPayload);
    expect(find.text('A new version of mediBO is ready'), findsOneWidget);
  });

  testWidgets('inside the backend window the same build stays silent',
      (tester) async {
    final recent = DateTime.now()
        .subtract(const Duration(hours: 23))
        .millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues(
        {kUpdateDismissedPref: 'app_update:android:24|$recent'});
    await _pump(tester, isAndroid: true, payload: kPlayPayload);
    expect(find.text('A new version of mediBO is ready'), findsNothing);
  });

  testWidgets('the window is the backend\'s: 0 seconds never silences anything',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      kUpdateDismissedPref:
          'app_update:android:24|${DateTime.now().millisecondsSinceEpoch}',
    });
    await _pump(tester, isAndroid: true, payload: {
      ...kPlayPayload,
      'dismiss_seconds': 0,
    });
    expect(find.text('A new version of mediBO is ready'), findsOneWidget);
  });

  testWidgets('a pre-#1956 forever-dismissal is asked once more', (tester) async {
    // Stored before this change: the key with no timestamp, which used to mean
    // "never show this build again".
    SharedPreferences.setMockInitialValues(
        {kUpdateDismissedPref: 'app_update:android:24'});
    await _pump(tester, isAndroid: true, payload: kPlayPayload);
    expect(find.text('A new version of mediBO is ready'), findsOneWidget);
  });

  testWidgets('update installed (update_available:false) clears the dismissal',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {kUpdateDismissedPref: 'app_update:android:24'});

    await _pump(tester, isAndroid: true, payload: const {
      'update_available': false,
      'current': '1.3.11',
      'message': '',
      'dismiss_key': null,
    });
    expect(find.text('A new version of mediBO is ready'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kUpdateDismissedPref), isNull);
  });

  testWidgets('a failing update check is invisible to the user', (tester) async {
    await _pump(tester, isAndroid: true, throws: true);
    expect(find.text('A new version of mediBO is ready'), findsNothing);
  });

  testWidgets('the sheet writes no display string of its own', (tester) async {
    // Empty strings in the payload must render as nothing — never as a Dart
    // fallback sentence, which is how the internal changelog leaked before.
    await _pump(tester, isAndroid: true, payload: {
      ...kPlayPayload,
      'eyebrow': '',
      'message': '',
      'version_label': '',
    });
    expect(find.text('A new version of mediBO is ready'), findsOneWidget);
    expect(find.text('App update available'), findsNothing);
    expect(find.textContaining('signing certificate'), findsNothing);
    expect(find.textContaining('client id'), findsNothing);
  });
}
