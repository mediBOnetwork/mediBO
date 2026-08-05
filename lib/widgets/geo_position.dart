// Platform-conditional geolocation: web uses dart:html geolocation, native
// returns null (the callers already handle "no location").
export 'geo_position_stub.dart'
    if (dart.library.html) 'geo_position_web.dart';
