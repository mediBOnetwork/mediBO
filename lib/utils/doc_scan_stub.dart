// Native (Android) implementation of the on-device ML Kit Document Scanner.
// Reached ONLY through the conditional export in doc_scan.dart, so the web build
// never compiles this file (nor the plugin).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';

/// A scanned page: display name (its `.jpg` extension drives the mime
/// downstream) and JPEG bytes.
typedef ScannedPage = ({String name, Uint8List bytes});

/// Launches Google's on-device ML Kit Document Scanner (auto edge-detection,
/// deskew, crop, glare/shadow cleanup). Keyless and offline — it runs entirely
/// inside Google Play Services.
///
/// Returns:
///   • null  → the scanner is unavailable (non-Android, or a device without the
///             Play Services scanner module). The caller MUST fall back to its
///             existing camera capture.
///   • []    → the user cancelled. No job/upload, and NOT an error.
///   • [..]  → one cropped/deskewed JPEG per page, in scan order.
Future<List<ScannedPage>?> scanDocuments({int pageLimit = 1}) async {
  // The scanner module ships only in Android Play Services.
  if (defaultTargetPlatform != TargetPlatform.android) return null;

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
    // A cancel is a no-op, never a fallback and never an error toast.
    if (e.message == 'Operation cancelled') return const [];
    // Module missing / failed to start → fall back to the raw camera.
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      await scanner.close();
    } catch (_) {}
  }
}
