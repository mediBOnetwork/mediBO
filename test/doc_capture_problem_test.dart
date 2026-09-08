// CHANGE #225 — the focused test for the scanner dead-end fix.
//
// The bug: the ML Kit Document Scanner is an on-demand Play Services module. On
// a device where that module cannot be installed, Google's own activity paints
// "Something went wrong — Try again later" and then returns RESULT_CANCELED,
// which the plugin reports as a plain cancel. `captureDocument` therefore did
// nothing at all — no scan, no camera, no message. A dead end.
//
// Two halves of the fix are pinned here (the third, the native readiness gate in
// DocScanReadiness.kt, is what makes `scan` return null instead of a bogus
// cancel — its Dart side is doc_scan_stub.dart, which is Android-only and so is
// exercised through this contract rather than compiled on the test VM):
//
//   1. A scanner that THROWS is treated as unavailable, not fatal — the camera
//      fallback still runs. Previously the throw propagated out of
//      captureDocument and both call sites swallowed it into a render-log line,
//      leaving the user with a tapped button and nothing on screen.
//   2. When the camera fallback ITSELF fails there is nothing left to fall back
//      to, so the failure is reported as a COPY KEY — never a Dart sentence —
//      and permission-denied is distinguished from a generic failure.
//
// The pre-existing behaviour (pages -> handler per page; [] -> silent cancel;
// null -> camera) is locked down separately in test/protected/doc_capture_test.dart
// and is deliberately not re-asserted here.

import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/utils/doc_capture.dart';

CapturedPage _page(String name) =>
    (name: name, bytes: Uint8List.fromList([name.hashCode & 0xff]));

void main() {
  group('captureDocument — scanner failure never dead-ends', () {
    test('scanner THROWS: the camera fallback still runs and its page is handled',
        () async {
      final handled = <String>[];
      final problems = <String>[];

      await captureDocument(
        scan: () async => throw PlatformException(code: 'MODULE_UNAVAILABLE'),
        cameraFallback: () async => _page('camera.jpg'),
        handlePage: (p) async => handled.add(p.name),
        onProblem: (code) async => problems.add(code),
      );

      expect(handled, ['camera.jpg']); // fell through to the working path
      expect(problems, isEmpty); // recovered silently — nothing to tell the user
    });

    test('scanner throws and the user then cancels the camera: still silent',
        () async {
      final handled = <String>[];
      final problems = <String>[];

      await captureDocument(
        scan: () async => throw Exception('boom'),
        cameraFallback: () async => null, // user cancelled
        handlePage: (p) async => handled.add(p.name),
        onProblem: (code) async => problems.add(code),
      );

      expect(handled, isEmpty);
      expect(problems, isEmpty); // a cancel is not a problem
    });
  });

  group('captureDocument — the camera failing IS reported, as a copy key', () {
    test('permission denied maps to the camera_denied key', () async {
      final problems = <String>[];

      await captureDocument(
        scan: () async => null, // scanner unavailable
        cameraFallback: () async =>
            throw PlatformException(code: 'camera_access_denied'),
        handlePage: (_) async => fail('nothing was captured'),
        onProblem: (code) async => problems.add(code),
      );

      expect(problems, [DocCaptureProblem.cameraDenied]);
    });

    test('any other camera failure maps to the generic failed key', () async {
      final problems = <String>[];

      await captureDocument(
        scan: () async => null,
        cameraFallback: () async => throw StateError('no camera app'),
        handlePage: (_) async => fail('nothing was captured'),
        onProblem: (code) async => problems.add(code),
      );

      expect(problems, [DocCaptureProblem.captureFailed]);
    });

    test('the reported values are ui_copy KEYS, not sentences', () {
      // The screens print c(code); a Dart sentence here would be the exact
      // hardcoded-string bug the max-backend rule exists to prevent.
      for (final code in [
        DocCaptureProblem.cameraDenied,
        DocCaptureProblem.captureFailed,
      ]) {
        expect(code, startsWith('doc_capture.'));
        expect(code.contains(' '), isFalse);
      }
    });

    test('onProblem is optional — omitting it must not throw', () async {
      await captureDocument(
        scan: () async => null,
        cameraFallback: () async => throw StateError('no camera app'),
        handlePage: (_) async => fail('nothing was captured'),
      );
    });
  });
}
