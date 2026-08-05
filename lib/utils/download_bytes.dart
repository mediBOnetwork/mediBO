// Platform-conditional byte-download/share glue: web uses dart:html + package:web,
// native falls back to url_launcher / no-op stubs. Original filename kept so callers' imports are unchanged.
export 'download_bytes_stub.dart' if (dart.library.html) 'download_bytes_web.dart';
