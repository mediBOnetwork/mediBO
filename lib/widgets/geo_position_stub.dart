/// Native stub: no web geolocation available here. The callers already treat
/// a null result as "no location" and surface the backend's own copy.
Future<({double lat, double lng})?> getCurrentPosition(
        {bool enableHighAccuracy = true}) =>
    Future.value(null);
