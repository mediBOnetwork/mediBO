// Web-only byte-download/share helpers. dart:html (download) and
// package:web + dart:js_interop (the Web Share API, which dart:html's
// Navigator binding doesn't expose — dart:js_util was removed from the SDK)
// are confined to this utility file (see CLAUDE.md's defensive import rule)
// so widget-tree files never import them directly — route any
// "save/share these bytes" need through here.
// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

void downloadBytes(List<int> bytes, String filename, String mimeType) {
  final blob = html.Blob([bytes], mimeType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}

/// One-tap download of a remote URL (e.g. a signed backend-rendered image),
/// as opposed to [downloadBytes] for bytes already in memory. Relies on the
/// URL's own Content-Disposition: attachment header to force a save rather
/// than a navigation — the `download` attribute is a same-origin-only hint
/// browsers ignore for cross-origin URLs.
void downloadUrl(String url, String filename) {
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
}

/// Download a same-origin static asset by its site-relative [path]
/// (e.g. '/demo/demo-order.jpg'). Web = instant anchor download.
void downloadSameOriginAsset(String path, String filename) {
  html.AnchorElement(href: path)
    ..setAttribute('download', filename)
    ..setAttribute('target', '_self')
    ..click();
}

/// CHANGE #462: native OS share sheet via the Web Share API (Level 2 — file
/// sharing), the web equivalent of a mobile share sheet since this app has no
/// native share_plus-style package. Returns:
///   true  — share completed
///   false — share API present but the attempt failed/was cancelled by the
///           user (AbortError on cancel is expected, not a real failure —
///           callers should stay silent, no error toast, no fallback download)
///   null  — Web Share API (or file sharing) unsupported in this browser;
///           callers should fall back to downloadBytes()
Future<bool?> shareBytes(List<int> bytes, String filename, String mimeType, {String? text}) async {
  try {
    final navigator = web.window.navigator;
    if (!navigator.hasProperty('share'.toJS).toDart) return null;
    final blobParts = [Uint8List.fromList(bytes).toJS].toJS;
    final file = web.File(blobParts, filename, web.FilePropertyBag(type: mimeType));
    final data = web.ShareData(files: [file].toJS);
    if (text != null) data.text = text;
    if (navigator.hasProperty('canShare'.toJS).toDart && !navigator.canShare(data)) {
      return null; // this browser's share doesn't support files
    }
    await navigator.share(data).toDart;
    return true;
  } catch (_) {
    // Most commonly the user dismissed the native share sheet (AbortError) —
    // not an error worth surfacing, and never a reason to fall back to download.
    return false;
  }
}
