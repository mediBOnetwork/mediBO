// Platform-conditional Geolocation glue: web uses dart:html geolocation,
// native returns null fixes (stub). Original filename kept so callers' imports are unchanged.
export 'device_location_stub.dart' if (dart.library.html) 'device_location_web.dart';
