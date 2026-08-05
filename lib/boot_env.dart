// Platform-conditional boot surface: real dart:html on web, no-ops on Android.
export 'boot_env_stub.dart' if (dart.library.html) 'boot_env_web.dart';
