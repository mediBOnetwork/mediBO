// Native (Android/desktop) recording-file glue: real temp file path + dart:io
// read. Fixes the Android voice-count crash — `record` needs a writable file
// path, and the bytes must be read from disk (not http.get).
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

int _seq = 0;

/// A fresh writable temp path for the next recording window.
Future<String> newRecordingPath(String ext) async {
  final dir = await getTemporaryDirectory();
  final name = 'voice_${DateTime.now().microsecondsSinceEpoch}_${_seq++}.$ext';
  return '${dir.path}/$name';
}

/// Read the recorded bytes straight off disk.
Future<Uint8List> readRecording(String pathOrUrl) async {
  return File(pathOrUrl).readAsBytes();
}

/// Delete the temp recording after its bytes are consumed (a continuous session
/// produces one file per window — don't let them pile up).
Future<void> disposeRecording(String pathOrUrl) async {
  try {
    final f = File(pathOrUrl);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}
