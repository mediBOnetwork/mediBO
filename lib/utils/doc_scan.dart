// Google ML Kit Document Scanner (Play Services module — keyless, offline,
// Android-only). Native → the real on-device scanner; web / any dart:html
// platform → unavailable (returns null so callers fall back to their existing
// camera capture unchanged). This is a DIFFERENT ML Kit API from the barcode
// scanner (mobile_scanner) and never touches it.
export 'doc_scan_stub.dart' if (dart.library.html) 'doc_scan_web.dart';
