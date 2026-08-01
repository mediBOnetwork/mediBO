// lib/services/maps_js_loader_stub.dart — CHANGE #634
// Non-web target: there is no Maps JS API to load. google_maps_flutter on
// Android/iOS reads its key from the platform manifest, not from here.
Future<bool> loadGoogleMapsJs(String browserKey) async => true;
