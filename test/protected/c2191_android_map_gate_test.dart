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

  // Om, mid-build: "the new mediBO logo should show in the Android app, the
  // one the website shows". Same artwork, different presentation: a LEGACY
  // launcher icon is shrunk onto a white plate by Android 8+, so the phone
  // looked a logo behind the site. The adaptive icon below is generated from
  // the website's own file by tool/c2191_android_icon.dart.
  test('the launcher icon is adaptive, and made from the site\'s own artwork',
      () {
    for (final f in const [
      'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
      'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml',
    ]) {
      final xml = _src(f);
      for (final layer in const ['background', 'foreground', 'monochrome']) {
        expect(xml.contains('<$layer android:drawable="@mipmap/ic_launcher_$layer"/>'),
            isTrue, reason: '$f lost its $layer layer');
      }
    }
    for (final d in const ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      for (final n in const [
        'ic_launcher',
        'ic_launcher_background',
        'ic_launcher_foreground',
        'ic_launcher_monochrome',
      ]) {
        final f = File('android/app/src/main/res/mipmap-$d/$n.png');
        expect(f.existsSync(), isTrue, reason: 'mipmap-$d/$n.png is missing');
        expect(f.lengthSync(), greaterThan(200), reason: 'mipmap-$d/$n.png is empty');
      }
    }
    // The status bar and the launch screen carry the same mark.
    for (final d in const ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      final f = File('android/app/src/main/res/drawable-$d/ic_stat_medibo.png');
      expect(f.existsSync(), isTrue, reason: 'drawable-$d/ic_stat_medibo.png is missing');
    }
    final manifest = _src('android/app/src/main/AndroidManifest.xml');
    expect(manifest.contains('default_notification_icon'), isTrue,
        reason: 'Firebase is drawing a white square again');
    expect(manifest.contains('@drawable/ic_stat_medibo'), isTrue);
    expect(_src('android/app/src/main/res/values/colors.xml').contains('medibo_brand'),
        isTrue, reason: 'the notification tint colour went missing');
    for (final d in const ['drawable', 'drawable-v21']) {
      expect(_src('android/app/src/main/res/$d/launch_background.xml')
              .contains('@mipmap/ic_launcher'),
          isTrue, reason: '$d/launch_background.xml opens on a blank sheet');
    }
    // The generator names the one source, so the two can never drift.
    expect(_src('tool/c2191_android_icon.dart').contains('web/icons/Icon-512.v4.png'),
        isTrue, reason: 'the icon stopped being made from the website artwork');
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
