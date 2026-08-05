// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;

/// Returns the device's current position as (lat, lng), or null if the
/// browser could not supply coordinates. Web geolocation call moved here
/// verbatim from the sheets that used to inline it. `enableHighAccuracy`
/// preserves the exact flag each caller passed (import sheet: true,
/// cash sheet: false).
Future<({double lat, double lng})?> getCurrentPosition(
    {bool enableHighAccuracy = true}) async {
  final completer = Completer<html.Geoposition>();
  html.window.navigator.geolocation
      .getCurrentPosition(
          enableHighAccuracy: enableHighAccuracy,
          timeout: const Duration(seconds: 20))
      .then((p) {
    if (!completer.isCompleted) completer.complete(p);
  }).catchError((e) {
    if (!completer.isCompleted) completer.completeError(e);
  });
  final pos = await completer.future.timeout(const Duration(seconds: 25));
  final lat = pos.coords?.latitude?.toDouble();
  final lng = pos.coords?.longitude?.toDouble();
  if (lat == null || lng == null) return null;
  return (lat: lat, lng: lng);
}
