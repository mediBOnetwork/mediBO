// Platform-conditional blob/object-URL helper. Web makes a real object URL for
// bytes already in memory; native has no such concept and returns null, so the
// caller renders its own in-app fallback instead of handing the file to
// another app (CMD #2119 item 3).
export 'object_url_stub.dart' if (dart.library.html) 'object_url_web.dart';
