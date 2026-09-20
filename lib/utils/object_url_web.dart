// Web-only object-URL helpers. dart:html lives here and nowhere in the widget
// tree (CLAUDE.md's defensive import rule): a screen imports object_url.dart,
// which resolves to this file only on web.
// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// A blob URL for bytes already in memory, so the app can show the file in its
/// OWN viewer (an <img>, or an <iframe> for a PDF) instead of downloading it
/// or handing it to another app.
String? createObjectUrl(List<int> bytes, String mimeType) {
  try {
    final blob = html.Blob([bytes], mimeType);
    return html.Url.createObjectUrlFromBlob(blob);
  } catch (_) {
    return null;
  }
}

void revokeObjectUrl(String url) {
  try {
    html.Url.revokeObjectUrl(url);
  } catch (_) {}
}
