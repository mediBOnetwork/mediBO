// Web recording-file glue — verbatim behaviour from the original code
// (empty path + http.get of the blob URL).
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// Web ignores the path and returns a blob URL from stop(); pass ''.
Future<String> newRecordingPath(String ext) async => '';

/// Fetch the recorded bytes from the blob URL that stop() returned.
Future<Uint8List> readRecording(String pathOrUrl) async {
  final r = await http.get(Uri.parse(pathOrUrl));
  if (r.statusCode != 200) {
    throw Exception('Failed to read recorded audio (${r.statusCode})');
  }
  return r.bodyBytes;
}

/// Blob URLs are reclaimed by the browser — nothing to delete.
Future<void> disposeRecording(String pathOrUrl) async {}
