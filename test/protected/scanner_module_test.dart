// PROTECTED — CHANGE #225. The scanner "Something went wrong — Try again later"
// screen is Google's, not ours: it is what a Play Services ON-DEMAND MODULE
// paints when it is missing and cannot be downloaded. Two independent things
// keep it off users' phones, and each one can be undone by a single line
// somewhere far from the scanner code. This file pins both.
//
// These are source-contract assertions on purpose: the failure they prevent is
// a BUILD configuration regression, which no widget test can observe.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('barcode scanning stays BUNDLED (never an on-demand Play module)', () {
    // mobile_scanner picks its model at build time:
    //   dev.steenbakker.mobile_scanner.useUnbundled = true
    //     -> play-services-mlkit-barcode-scanning  (downloaded module — CAN FAIL)
    //   unset / false
    //     -> com.google.mlkit:barcode-scanning     (model inside the APK)
    // Setting that property would put every barcode scan back on the exact path
    // this command was raised to fix, with no code change to review.
    test('the unbundled-model flag is never enabled', () {
      for (final path in const [
        'android/gradle.properties',
        'android/local.properties',
        'gradle.properties',
      ]) {
        final f = File(path);
        if (!f.existsSync()) continue;
        final enabled = f
            .readAsLinesSync()
            .map((l) => l.trim())
            .where((l) => !l.startsWith('#'))
            .where((l) => l.startsWith('dev.steenbakker.mobile_scanner.useUnbundled'))
            .where((l) => l.split('=').last.trim().toLowerCase() == 'true');
        expect(
          enabled,
          isEmpty,
          reason: '$path enables the UNBUNDLED barcode model. That downloads a '
              'Play Services module at runtime and reintroduces the '
              '"Something went wrong" dead end. Leave it unset.',
        );
      }
    });
  });

  group('the document scanner is gated before it is launched', () {
    final stub = File('lib/utils/doc_scan_stub.dart').readAsStringSync();

    // Unlike the barcode model, the DOCUMENT scanner has no bundled artifact —
    // Google ships it only as a module. So it cannot be swapped out; it can only
    // be checked for. The gate is the entire fix.
    test('scanDocuments checks the module before launching Google\'s activity', () {
      final gate = stub.indexOf('_ensureModule');
      final launch = stub.indexOf('DocumentScanner(');
      expect(gate, greaterThan(-1),
          reason: 'the readiness gate was removed from doc_scan_stub.dart');
      expect(launch, greaterThan(-1));
      expect(
        gate,
        lessThan(launch),
        reason: 'the scanner is constructed BEFORE the module is verified, so a '
            'device without the module gets Google\'s error screen again.',
      );
    });

    test('an unavailable module returns null so the caller opens its camera', () {
      // null is the contract doc_capture.dart keys its camera fallback off. If
      // this ever became `[]` (the cancel signal), an unavailable scanner would
      // read as a user cancel and the button would silently do nothing.
      expect(
        RegExp(r'if\s*\(!await\s+_ensureModule\(\)\)\s*return null;').hasMatch(stub),
        isTrue,
        reason: 'doc_scan_stub.dart must return null — not [] — when the module '
            'is unavailable, or the camera fallback never runs.',
      );
    });

    test('the native readiness channel is registered at engine start', () {
      final main = File(
        'android/app/src/main/kotlin/in/medibo/app/MainActivity.kt',
      ).readAsStringSync();
      expect(main, contains('DocScanReadiness.register'),
          reason: 'without this the Dart channel throws, every device is judged '
              '"not ready", and the scanner silently never runs.');
    });

    test('the app module keeps the symbols the readiness check compiles against', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('com.google.android.gms:play-services-base'),
          reason: 'GoogleApiAvailability + ModuleInstall live here.');
      expect(gradle, contains('play-services-mlkit-document-scanner'),
          reason: 'DocScanReadiness compiles against GmsDocumentScanning.');
    });
  });

  group('a release artifact is never debug-signed', () {
    // The 1.1.0 incident: key.properties was absent, the release buildType fell
    // back to the debug keys, and the resulting APK could not install over the
    // release-signed build already on users' phones. The guard that now refuses
    // that build is the reason this command shipped no APK rather than a broken
    // one, so it is worth as much as the scanner fix itself.
    test('build.gradle.kts still refuses a keystore-less release build', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('RELEASE BUILD REFUSED'));
      expect(gradle, contains('gradle.taskGraph.whenReady'),
          reason: 'the guard must run against the real task graph, so debug '
              'builds and `flutter run` stay unaffected.');
    });
  });
}
