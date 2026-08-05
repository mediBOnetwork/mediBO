// Native (non-web) fallback for the web byte-download/share helpers.
// Public API matches download_bytes_web.dart exactly so callers type-check
// identically on Android.
import 'package:url_launcher/url_launcher.dart';

// TODO(android): needs path_provider/share_plus to actually save bytes to disk.
void downloadBytes(List<int> bytes, String filename, String mimeType) {}

/// Native fallback for the web one-tap remote-URL download: open the URL in an
/// external browser via url_launcher. Errors are swallowed.
void downloadUrl(String url, String filename) {
  try {
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

// TODO(android): needs path_provider/share_plus for a real native share sheet.
Future<bool?> shareBytes(List<int> bytes, String filename, String mimeType,
    {String? text}) async {
  return null;
}
