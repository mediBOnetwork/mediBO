// lib/services/device_location.dart — CHANGE #629
//
// THE one place the browser Geolocation API is touched. Every delivery surface
// (heartbeat, the three completion methods, failed/partial, route origin) needs
// the device's current position, and the DEFENSIVE IMPORT RULE forbids adding
// dart:html to widget-tree files — so it lives here, in a service, and the new
// delivery widgets import this instead.
//
// Nothing here decides anything: it returns coordinates or null. A null is not
// an error message and never becomes one in Dart — callers pass whatever they
// got straight to the backend, which owns every user-facing string.

import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// One position fix. [heading] and [accuracy] are optional — the browser does
/// not always supply them (heading is usually null unless the device is moving).
class DeviceFix {
  final double lat;
  final double lng;
  final double? heading;
  final double? accuracy;
  const DeviceFix(this.lat, this.lng, this.heading, this.accuracy);
}

class DeviceLocation {
  DeviceLocation._();

  /// Current position, or null on ANY failure (permission denied, timeout, no
  /// GPS, insecure context). Never throws — a delivery action must still be
  /// possible to attempt when the fix fails; the backend decides what to do
  /// with a missing coordinate.
  static Future<DeviceFix?> current({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final completer = Completer<html.Geoposition>();
      html.window.navigator.geolocation
          .getCurrentPosition(enableHighAccuracy: true, timeout: timeout)
          .then((pos) {
        if (!completer.isCompleted) completer.complete(pos);
      }).catchError((Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      });
      final pos = await completer.future.timeout(timeout + const Duration(seconds: 5));
      return _fixOf(pos);
    } catch (_) {
      return null;
    }
  }

  /// Continuous updates for the run heartbeat (PART B7). Emits on every
  /// significant movement the browser reports; the caller also ticks on a timer
  /// so a stationary rider still reports in. Errors are swallowed, not emitted.
  static StreamSubscription<html.Geoposition>? watch(
    void Function(DeviceFix fix) onFix,
  ) {
    try {
      return html.window.navigator.geolocation
          .watchPosition(enableHighAccuracy: true)
          .listen(
        (pos) {
          final fix = _fixOf(pos);
          if (fix != null) onFix(fix);
        },
        onError: (Object _) {},
        cancelOnError: false,
      );
    } catch (_) {
      return null;
    }
  }

  static DeviceFix? _fixOf(html.Geoposition pos) {
    final lat = pos.coords?.latitude?.toDouble();
    final lng = pos.coords?.longitude?.toDouble();
    if (lat == null || lng == null) return null;
    return DeviceFix(
      lat,
      lng,
      pos.coords?.heading?.toDouble(),
      pos.coords?.accuracy?.toDouble(),
    );
  }
}
