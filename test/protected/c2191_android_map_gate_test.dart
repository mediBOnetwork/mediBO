// CMD #2191 (Om, live on Android) — the native map may only be built by a build
// that carries the key.
//
// WHAT THIS HOLDS DOWN. `map_config.native_key_android` was set on live while
// the app on Play (versionCode 54) had no `com.google.android.geo.API_KEY` in
// its manifest. map_config_get('android') therefore answered
// uses_google_js: true, the app built the NATIVE GoogleMap, and Android threw
//   java.lang.IllegalStateException: API key not found
// out of the platform view — a PROCESS KILL, on the registration location
// screen, five times in eleven minutes (crash_event 11931-11935).
//
// So the app now reports the one fact only the binary knows — its versionCode —
// and the BACKEND decides what that build may render
// (`native_key_android_min_build`). The rules this file keeps:
//
//   1. Android sends its build; web and iOS send null (there is no Android
//      versionCode to report, and the backend must not infer one).
//   2. The flavor reports ITS OWN code — the partner app has its own line.
//   3. Nothing in Dart compares that number to anything: no threshold, no
//      provider choice, no key. `uses_google_js` stays the only switch.
//   4. The manifest carries the key, so a build that clears the gate can
//      actually draw the map.

import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/map_config.dart';
import 'package:pharma_b2b/services/app_update_feed.dart' show kAndroidVersionCode;

String _src(String p) => File(p).readAsStringSync();

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android reports the versionCode it is running', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(mapPlatformName, 'android');
    expect(mapAppBuild, kAndroidVersionCode,
        reason: 'the app stopped telling the backend which build it is');
    expect(mapAppBuild, isNotNull);
  });

  test('a platform with no Android versionCode reports nothing', () {
    for (final p in const [TargetPlatform.iOS, TargetPlatform.macOS]) {
      debugDefaultTargetPlatformOverride = p;
      expect(mapAppBuild, isNull,
          reason: '$p invented an Android build number');
    }
  });

  test('the build number is sent, and nothing is decided from it', () {
    final src = _src('lib/services/map_config.dart');
    expect(src.contains("'p_app_build': mapAppBuild"), isTrue,
        reason: 'the build stopped going out with the config ask');
    // No threshold and no provider choice in Dart: the gate is SQL's.
    expect(RegExp(r'mapAppBuild\s*[<>]=?\s*\d').hasMatch(src), isFalse,
        reason: 'Dart started comparing its build to a number');
    expect(RegExp(r"keyGate\s*==\s*'").hasMatch(src), isFalse,
        reason: 'Dart started branching on the gate verdict');
    final map = _src('lib/widgets/adaptive_map.dart');
    expect(map.contains('mapAppBuild'), isFalse,
        reason: 'the map widget started reading the build number');
  });

  test('the gate verdict is carried and logged, never computed', () {
    final cfg = MapConfig.fromJson(const {
      'provider': 'google',
      'uses_google_js': false,
      'key_gate': 'build_too_old',
      'attribution': '© OpenStreetMap contributors',
      'tile_url': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    });
    expect(cfg.keyGate, 'build_too_old');
    expect(cfg.usesGoogleJs, isFalse,
        reason: 'an old build must never be sent down the native Google path');
    final missing = MapConfig.fromJson(const {'provider': 'google'});
    expect(missing.keyGate, 'n/a',
        reason: 'an absent verdict must not read as a pass');
    expect(_src('lib/services/map_config.dart').contains('c2191_map_key_gate'),
        isTrue, reason: 'the gate stopped being visible in the render log');
  });

  test('the manifest carries the key a cleared gate promises', () {
    final manifest = _src('android/app/src/main/AndroidManifest.xml');
    expect(manifest.contains('com.google.android.geo.API_KEY'), isTrue,
        reason: 'the Android manifest lost the Maps key — every native map on '
            'a build past the gate is now a process kill');
    final m = RegExp(r'com\.google\.android\.geo\.API_KEY"\s*\n?\s*android:value="([^"]*)"')
        .firstMatch(manifest);
    expect(m, isNotNull, reason: 'the Maps key meta-data has no value');
    expect(m!.group(1)!.trim(), isNotEmpty);
  });
}
