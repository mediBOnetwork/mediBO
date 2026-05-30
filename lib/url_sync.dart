// Platform-conditional URL sync: web uses dart:html, native is a no-op stub.
export 'url_sync_web.dart' if (dart.library.io) 'url_sync_stub.dart';
