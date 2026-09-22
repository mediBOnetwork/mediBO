// Native (non-web) implementation of the browser Geolocation service.
// Public API matches device_location_web.dart: DeviceFix (verbatim) and the
// DeviceLocation.current / best / watch / openSettings surface. Callers already
// handle null.
//
// CMD #2171 (Om, live bug on Android 1.3.33) — this file used to return null
// from every method "because there is no browser Geolocation". The Android app
// is a NATIVE build, so every native caller got that null: on the registration
// Location step "Use my location" did nothing at all — no system permission
// popup, because nothing ever asked for one — and the amber bar's "Turn on"
// link, which calls the same path, did nothing either. A web browser was the
// only place the button had ever worked.
//
// So the native side now asks the platform. The channel is the one the rider
// run screen already uses (in.medibo.app/run_location, MainActivity.kt): it
// raises the real permission dialog, waits for the person's answer and hands
// back ONE fix. Nothing here decides anything — it returns coordinates or null,
// exactly as the web file does, and the backend owns every word shown about it.

import 'dart:async';

import 'package:flutter/services.dart';

/// One position fix. [heading] and [accuracy] are optional — the platform does
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

  static const MethodChannel _ch = MethodChannel('in.medibo.app/run_location');

  /// Test seam — the same shape every service in this app uses.
  static Future<dynamic> Function(String method, [dynamic args])? transport;

  static Future<T?> _call<T>(String method, [dynamic args]) async {
    final t = transport;
    try {
      if (t != null) return (await t(method, args)) as T?;
      return await _ch.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // iOS / desktop / a debug host with no channel: no fix, same as before.
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static DeviceFix? _fixOf(dynamic raw) {
    if (raw is! Map) return null;
    final lat = (raw['lat'] as num?)?.toDouble();
    final lng = (raw['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    // 0,0 is the Gulf of Guinea, not a fix.
    if (lat == 0 && lng == 0) return null;
    return DeviceFix(
      lat,
      lng,
      (raw['heading'] as num?)?.toDouble(),
      (raw['accuracy'] as num?)?.toDouble(),
    );
  }

  /// True once this device has granted fine location.
  static Future<bool> hasPermission() async =>
      (await _call<bool>('hasPermission')) ?? false;

  /// Raises the system permission dialog and waits for the answer. Returns
  /// what the person chose. A permanently-denied grant comes back false at
  /// once, with no dialog — that is the platform's decision, not ours.
  static Future<bool> requestPermission() async =>
      (await _call<bool>('requestPermission')) ?? false;

  /// The app's own page in system Settings, for a grant Android will no longer
  /// ask about. False when the platform could not open it.
  static Future<bool> openSettings() async =>
      (await _call<bool>('openSettings')) ?? false;

  /// Current position, or null on ANY failure (permission refused, no GPS, no
  /// channel). Never throws.
  static Future<DeviceFix?> current({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!await hasPermission()) {
      if (!await requestPermission()) return null;
    }
    return _fixOf(await _call<dynamic>(
        'fix', {'timeout_ms': timeout.inMilliseconds}));
  }

  /// The BEST fix within [window], not the first one — the same contract the
  /// web file documents. The platform side already keeps the tightest reading
  /// it sees inside the window, so this is one call, not a loop.
  static Future<DeviceFix?> best({
    Duration window = const Duration(seconds: 8),
    double goodEnoughMetres = 25,
  }) async {
    if (!await hasPermission()) {
      if (!await requestPermission()) return null;
    }
    return _fixOf(await _call<dynamic>('fix', {
      'timeout_ms': window.inMilliseconds,
      'good_enough_m': goodEnoughMetres,
    }));
  }

  /// Continuous updates. The native bridge answers one fix at a time, so a
  /// caller that wants a stream keeps its own timer (the rider run screen
  /// already does); nothing is subscribed here.
  static StreamSubscription? watch(
    void Function(DeviceFix fix) onFix,
  ) {
    return null;
  }
}
