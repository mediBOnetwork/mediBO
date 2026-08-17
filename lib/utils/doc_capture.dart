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
/// CHANGE #225 — why a capture produced nothing, when the reason is worth
/// telling the user about. These are KEYS into the backend `ui_copy` table, not
/// sentences: the screen prints `c(code)`, so the wording is an UPDATE, never a
/// deploy. A user cancel is not a problem and never reports one.
class DocCaptureProblem {
  DocCaptureProblem._();

  /// The OS refused the camera (permission denied / no camera app).
  static const cameraDenied = 'doc_capture.camera_denied';

  /// The camera opened but the shot could not be read.
  static const captureFailed = 'doc_capture.failed';
}

Future<void> captureDocument({
  required Future<List<CapturedPage>?> Function() scan,
  required Future<CapturedPage?> Function() cameraFallback,
  required Future<void> Function(CapturedPage page) handlePage,
  Future<void> Function(String problemCode)? onProblem,
}) async {
  // CHANGE #225: a scanner that throws is unavailable, not fatal — the camera
  // fallback below is always a working path, so it is never a dead end.
  List<CapturedPage>? pages;
  try {
    pages = await scan();
  } catch (_) {
    pages = null;
  }
  if (pages == null) {
    // Scanner unavailable (web / non-Play-Services / module missing) → the
    // existing camera capture. Its own failure IS worth saying out loud,
    // because there is nothing left to fall back to.
    final CapturedPage? shot;
    try {
      shot = await cameraFallback();
    } catch (e) {
      await onProblem?.call(_problemFor(e));
      return;
    }
    if (shot == null) return; // camera cancelled
    await handlePage(shot);
    return;
  }
  if (pages.isEmpty) return; // scanner cancelled — no job/upload, no error
  for (final page in pages) {
    await handlePage(page); // one job/upload per page, preserving order
  }
}

/// Maps a camera failure to its copy key. image_picker reports a refused
/// permission as `camera_access_denied`; everything else is a generic failure.
String _problemFor(Object e) {
  final s = e.toString().toLowerCase();
  if (s.contains('denied') || s.contains('permission')) {
    return DocCaptureProblem.cameraDenied;
  }
  return DocCaptureProblem.captureFailed;
}
