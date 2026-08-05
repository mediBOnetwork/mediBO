// Platform-conditional Google Identity Services glue: web uses dart:js_interop,
// native is inert (stub). Original filename kept so callers' imports are unchanged.
export 'gis_auth_stub.dart' if (dart.library.html) 'gis_auth_web.dart';
