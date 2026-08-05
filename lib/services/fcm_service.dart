// Platform-conditional FCM glue: web uses the dart:js_interop index.html bridge,
// native is a no-op stub. Original filename kept so callers' imports are unchanged.
export 'fcm_service_stub.dart' if (dart.library.html) 'fcm_service_web.dart';
