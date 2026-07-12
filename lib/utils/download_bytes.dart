// Web-only byte-download helper. dart:html is confined to this utility file
// (see CLAUDE.md's defensive import rule) so widget-tree files never import it
// directly — route any "save these bytes as a file" need through here.
// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

void downloadBytes(List<int> bytes, String filename, String mimeType) {
  final blob = html.Blob([bytes], mimeType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}
