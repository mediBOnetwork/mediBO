import 'dart:typed_data';

/// A captured page — a document-scanner page OR a raw camera shot. Its `name`
/// extension drives the mime the downstream handler derives.
typedef CapturedPage = ({String name, Uint8List bytes});

/// Shared orchestration for a "camera" document-capture button. Extracted pure
/// so it is testable without the host screen (which needs Supabase/providers)
/// or the ML Kit plugin.
///
/// [scan] is the ML Kit document scanner (see doc_scan.dart), with the contract:
///   • null → unavailable on this platform → fall back to [cameraFallback]
///   • []   → the user cancelled → do nothing, no error
///   • [..] → one page each
/// [cameraFallback] is the spot's EXISTING raw camera capture, unchanged; it is
///   invoked ONLY when the scanner is unavailable, and returns null on cancel.
/// [handlePage] is the spot's EXISTING post-capture handler (OCR enqueue /
///   storage upload + record write), run once per page IN ORDER. Multi-page is
///   simply the single-image handler repeated — nothing downstream changes.
///
/// A cancel (scanner `[]`, or camera fallback `null`) creates no job/upload and
/// reports no error.
Future<void> captureDocument({
  required Future<List<CapturedPage>?> Function() scan,
  required Future<CapturedPage?> Function() cameraFallback,
  required Future<void> Function(CapturedPage page) handlePage,
}) async {
  final pages = await scan();
  if (pages == null) {
    // Scanner unavailable (web / non-Play-Services) → existing camera capture.
    final shot = await cameraFallback();
    if (shot == null) return; // camera cancelled
    await handlePage(shot);
    return;
  }
  if (pages.isEmpty) return; // scanner cancelled — no job/upload, no error
  for (final page in pages) {
    await handlePage(page); // one job/upload per page, preserving order
  }
}
