// Native (Android) implementation of the on-device ML Kit Document Scanner.
// Reached ONLY through the conditional export in doc_scan.dart, so the web build
// never compiles this file (nor the plugin).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';

/// A scanned page: display name (its `.jpg` extension drives the mime
/// downstream) and JPEG bytes.
typedef ScannedPage = ({String name, Uint8List bytes});

// ── CHANGE #225: the readiness gate ─────────────────────────────────────────
//
// The ML Kit Document Scanner has no bundled model — it is an on-demand Play
// Services module. On a device where that module is missing and cannot be
// downloaded (Play Services outdated/absent, download blocked, no network),
// GOOGLE's own activity paints "Something went wrong — Try again later" and
// then returns RESULT_CANCELED. The plugin reports that as a plain user cancel,
// so the app did nothing and the user was dead-ended on a Google error screen.
//
// So we never launch that activity unless the module is verifiably present:
// ask native (DocScanReadiness.kt) first, request the install once, and if it
// is still not there return null so the caller opens its ordinary camera. That
// makes "module unavailable" indistinguishable, to the user, from a device that
// simply never had the scanner — the camera just opens.
//
// Because the module is verified BEFORE the launch, a cancel coming back from
// the scanner is now unambiguously a real user cancel, not a hidden failure.

const MethodChannel _readiness = MethodChannel('in.medibo.app/doc_scan');

/// Per-process memo. Once a device is known to lack the module, every later tap
/// goes straight to the camera — no repeated install attempts, no waiting.
bool? _moduleReady;

/// Test seam: resets the memo so a test can drive both branches.
void debugResetDocScanReadiness() => _moduleReady = null;

/// True when the scanner module is present and it is safe to launch it.
Future<bool> _ensureModule() async {
  final memo = _moduleReady;
  if (memo != null) return memo;

  bool ready = false;
  try {
    final status = await _readiness
        .invokeMapMethod<String, dynamic>('status')
        .timeout(const Duration(seconds: 5));
    final playServices = status?['playServices'] == true;
    ready = playServices && status?['moduleReady'] == true;

    // Play Services missing or too old: the module can never arrive. Don't ask.
    if (!ready && playServices) {
      ready = await _readiness
              .invokeMethod<bool>('install')
              .timeout(const Duration(seconds: 25)) ??
          false;
    }
  } catch (_) {
    // Channel missing, timed out, or Play threw: not ready. The caller's camera
    // fallback is always a working path, so this is safe in every case.
    ready = false;
  }

  _moduleReady = ready;
  return ready;
}

/// Launches Google's on-device ML Kit Document Scanner (auto edge-detection,
/// deskew, crop, glare/shadow cleanup). Keyless and offline — it runs entirely
/// inside Google Play Services.
///
/// Returns:
///   • null  → the scanner is unavailable (non-Android, Play Services missing or
///             outdated, or the scanner module is not installed and could not be
///             installed). The caller MUST fall back to its camera capture.
///   • []    → the user cancelled. No job/upload, and NOT an error.
///   • [..]  → one cropped/deskewed JPEG per page, in scan order.
Future<List<ScannedPage>?> scanDocuments({int pageLimit = 1}) async {
  // The scanner module ships only in Android Play Services.
  if (defaultTargetPlatform != TargetPlatform.android) return null;

  // Verify the module BEFORE launching, so Google's error screen never shows.
  if (!await _ensureModule()) return null;

  final scanner = DocumentScanner(
    options: DocumentScannerOptions(
      documentFormats: const {DocumentFormat.jpeg}, // full-quality JPEG pages
      mode: ScannerMode.full,   // auto-capture + ML glare/shadow cleanup
      pageLimit: pageLimit < 1 ? 1 : pageLimit,
      isGalleryImport: false,   // camera path only; gallery buttons stay separate
    ),
  );
  try {
    final result = await scanner.scanDocument();
    final images = result.images ?? const <String>[];
    final pages = <ScannedPage>[];
    for (var i = 0; i < images.length; i++) {
      final bytes = await File(images[i]).readAsBytes();
      if (bytes.isNotEmpty) pages.add((name: 'scan_${i + 1}.jpg', bytes: bytes));
    }
    return pages; // empty only if the scanner genuinely returned no pages
  } on PlatformException catch (e) {
    // RESULT_CANCELED surfaces as this exact message (plugin DocumentScanner.kt).
    // The module was verified above, so this really is the user backing out:
    // a no-op, never a fallback and never an error toast.
    if (e.message == 'Operation cancelled') return const [];
    // Anything else means the scanner broke after all — forget the memo so the
    // next tap re-checks, and fall back to the raw camera right now.
    _moduleReady = null;
    return null;
  } catch (_) {
    _moduleReady = null;
    return null;
  } finally {
    try {
      await scanner.close();
    } catch (_) {}
  }
}
