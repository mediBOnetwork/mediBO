// Native (Android) implementations of the web byte-download/share helpers.
// Public API matches download_bytes_web.dart exactly so callers type-check
// identically off-web. "Download" on Android = write to a temp file and open
// the system share sheet (Save to Files / WhatsApp / etc.).
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

// Absolute host for same-origin static assets that only exist on the web host.
const String _siteHost = 'https://medibo.in';

Future<File> _writeTemp(List<int> bytes, String filename) async {
  final dir = await getTemporaryDirectory();
  final safe = filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final f = File('${dir.path}/$safe');
  await f.writeAsBytes(bytes, flush: true);
  return f;
}

void downloadBytes(List<int> bytes, String filename, String mimeType) {
  // Fire-and-forget: write then open the share sheet.
  () async {
    try {
      final f = await _writeTemp(bytes, filename);
      await Share.shareXFiles([XFile(f.path, mimeType: mimeType, name: filename)]);
    } catch (_) {}
  }();
}

/// Open a remote URL in the external browser (it will handle the download).
void downloadUrl(String url, String filename) {
  try {
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// Same-origin static assets don't exist on-device — open the absolute host URL
/// in the external browser so the platform downloads it.
void downloadSameOriginAsset(String path, String filename) {
  try {
    final abs = path.startsWith('http') ? path : '$_siteHost$path';
    launchUrl(Uri.parse(abs), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// Native share sheet via share_plus. Returns true on success, false on
/// cancel/failure (never null — a native share is always available on Android).
Future<bool?> shareBytes(List<int> bytes, String filename, String mimeType,
    {String? text}) async {
  try {
    final f = await _writeTemp(bytes, filename);
    final result = await Share.shareXFiles(
      [XFile(f.path, mimeType: mimeType, name: filename)],
      text: text,
    );
    return result.status == ShareResultStatus.success;
  } catch (_) {
    return false;
  }
}
