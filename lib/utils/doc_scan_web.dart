// Web / non-native stub for the ML Kit Document Scanner.
import 'dart:typed_data';

/// A scanned page: display name (its `.jpg` extension drives the mime
/// downstream) and JPEG bytes.
typedef ScannedPage = ({String name, Uint8List bytes});

/// The ML Kit Document Scanner runs only inside Android's Play Services, so it
/// is unavailable on web. Returns null so the caller falls back to its existing
/// camera-capture behaviour unchanged.
Future<List<ScannedPage>?> scanDocuments({int pageLimit = 1}) async => null;
