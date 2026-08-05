// Native (non-web) fallback for the browser Geolocation service.
// Public API matches device_location_web.dart: DeviceFix (verbatim) and the
// DeviceLocation.current / watch surface. Callers already handle null.

import 'dart:async';

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

  /// Native fallback: no browser Geolocation, so there is no fix. Returns null.
  static Future<DeviceFix?> current({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    return null;
  }

  /// Native fallback: nothing to watch, so no subscription is created. Returns
  /// null (the caller stores it in a nullable StreamSubscription and guards it).
  static StreamSubscription? watch(
    void Function(DeviceFix fix) onFix,
  ) {
    return null;
  }
}
