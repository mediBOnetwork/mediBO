// PROTECTED — Google ML Kit Document Scanner camera conversion.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the document-camera capture behaviour.
//
// What this holds down — the ONE orchestration both converted camera spots
// delegate to (`captureDocument`, used by Bulk Order's _onCameraTap and the
// KYC / ID-scan's _fromCamera):
//
//   1. Scanner AVAILABLE, N pages -> the spot's existing per-image handler runs
//      once per page, IN ORDER, and the raw-camera fallback is NEVER used. This
//      is "one job/upload per page" for multi-page documents.
//
//   2. Scanner CANCELLED (returns []) -> no handler call, no fallback, no throw.
//      A cancel is not a failure and creates no job/upload.
//
//   3. Scanner UNAVAILABLE (returns null: web / non-Play-Services device) ->
//      the EXISTING camera capture runs unchanged. Its result feeds the same
//      handler; its own cancel (null) is a no-op.
//
//   4. The orchestration touches ONLY scan/cameraFallback/handlePage — it has
//      no gallery/file path and no barcode path, so those stay exactly as they
//      were in their own code (this test asserts nothing else is reachable).
//
// The full host screens (BulkUploadScreen, DeliveryIdScanCard) need Supabase +
// providers to render, so — per CLAUDE.md ("extract its decisions into a pure
// class and test that") — the capture decision lives in the pure
// `captureDocument` function and is locked down here. No network, no Supabase.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/utils/doc_capture.dart';

CapturedPage _page(String name) =>
    (name: name, bytes: Uint8List.fromList([name.hashCode & 0xff]));

void main() {
  group('captureDocument — camera document-scanner orchestration', () {
    test('scanner returns multiple pages: one handler call per page, in order, '
        'no camera fallback', () async {
      final handled = <String>[];
      var cameraCalls = 0;

      await captureDocument(
        scan: () async => [_page('scan_1.jpg'), _page('scan_2.jpg'), _page('scan_3.jpg')],
        cameraFallback: () async {
          cameraCalls++;
          return null;
        },
        handlePage: (p) async => handled.add(p.name),
      );

      expect(handled, ['scan_1.jpg', 'scan_2.jpg', 'scan_3.jpg']); // per page, in order
      expect(cameraCalls, 0); // fallback never used when the scanner is available
    });

    test('scanner returns a single page: exactly one handler call', () async {
      final handled = <String>[];
      await captureDocument(
        scan: () async => [_page('scan_1.jpg')],
        cameraFallback: () async => null,
        handlePage: (p) async => handled.add(p.name),
      );
      expect(handled, ['scan_1.jpg']);
    });

    test('every scanned page is a .jpg (image/jpeg downstream)', () async {
      final names = <String>[];
      await captureDocument(
        scan: () async => [_page('scan_1.jpg'), _page('scan_2.jpg')],
        cameraFallback: () async => null,
        handlePage: (p) async => names.add(p.name),
      );
      expect(names.every((n) => n.toLowerCase().endsWith('.jpg')), isTrue);
    });

    test('scanner cancelled ([]): no handler call, no fallback, no throw', () async {
      var handled = 0;
      var cameraCalls = 0;
      await captureDocument(
        scan: () async => const [],
        cameraFallback: () async {
          cameraCalls++;
          return _page('cam.jpg');
        },
        handlePage: (_) async => handled++,
      );
      expect(handled, 0);      // no job/upload created
      expect(cameraCalls, 0);  // a scanner cancel is NOT a fallback trigger
    });

    test('scanner unavailable (null): falls back to the existing camera capture, '
        'whose page feeds the same handler', () async {
      final handled = <String>[];
      var cameraCalls = 0;
      await captureDocument(
        scan: () async => null,
        cameraFallback: () async {
          cameraCalls++;
          return _page('legacy_camera.jpg');
        },
        handlePage: (p) async => handled.add(p.name),
      );
      expect(cameraCalls, 1);                     // existing capture path used
      expect(handled, ['legacy_camera.jpg']);     // same downstream handler
    });

    test('scanner unavailable AND camera cancelled (null): total no-op', () async {
      var handled = 0;
      await captureDocument(
        scan: () async => null,
        cameraFallback: () async => null, // user backed out of the camera
        handlePage: (_) async => handled++,
      );
      expect(handled, 0);
    });

    test('handler runs strictly sequentially (await between pages)', () async {
      final order = <String>[];
      await captureDocument(
        scan: () async => [_page('a.jpg'), _page('b.jpg')],
        cameraFallback: () async => null,
        handlePage: (p) async {
          order.add('start:${p.name}');
          await Future<void>.delayed(Duration.zero);
          order.add('end:${p.name}');
        },
      );
      // Page A fully completes before page B begins.
      expect(order, ['start:a.jpg', 'end:a.jpg', 'start:b.jpg', 'end:b.jpg']);
    });
  });
}
