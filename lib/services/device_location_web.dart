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

  // CMD #2171 — the same three doors the native file has, so one widget can
  // call them on both platforms. A browser has no separate grant to check and
  // no settings page to open: it asks on the first read and answers there.
  static Future<bool> hasPermission() async => true;

  static Future<bool> requestPermission() async => true;
  /// CMD #2191 — the browser has no "never ask again" the page can read, and
  /// no app Settings page to send anyone to, so the ask is always available.
  static Future<bool> canAskAgain() async => true;


  static Future<bool> openSettings() async => false;

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
          .getCurrentPosition(
            enableHighAccuracy: true,
            timeout: timeout,
            // CMD #2112 — never a REMEMBERED fix. The browser will happily
            // hand back a cached position from a different part of town, and
            // a shop pin dropped on it looks like a working map right up
            // until a rider is sent to the wrong street.
            maximumAge: Duration.zero,
          )
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

  /// CMD #2112 — the BEST fix within [window], not the first one.
  ///
  /// A browser answers `getCurrentPosition` as soon as it has anything at all,
  /// which on a phone that has just woken its GPS is usually the wifi/cell
  /// estimate: hundreds of metres out. Setting a shop's door on that is the
  /// whole problem the pin exists to solve, so this watches for a few seconds
  /// and keeps the most accurate reading, stopping early once the fix is
  /// inside [goodEnoughMetres].
  ///
  /// Returns null exactly as [current] does — permission denied, no GPS, an
  /// insecure context — and never throws. It decides nothing beyond "which of
  /// these readings is the most accurate", which is arithmetic on a number the
  /// browser supplied.
  static Future<DeviceFix?> best({
    Duration window = const Duration(seconds: 8),
    double goodEnoughMetres = 25,
  }) async {
    final done = Completer<DeviceFix?>();
    DeviceFix? bestFix;
    StreamSubscription<html.Geoposition>? sub;
    Timer? stop;

    void finish() {
      if (done.isCompleted) return;
      stop?.cancel();
      sub?.cancel();
      done.complete(bestFix);
    }

    try {
      sub = html.window.navigator.geolocation
          .watchPosition(enableHighAccuracy: true)
          .listen((pos) {
        final fix = _fixOf(pos);
        if (fix == null) return;
        final have = bestFix?.accuracy;
        final got = fix.accuracy;
        // No accuracy reported at all: take the newest reading, since there
        // is nothing to compare. Otherwise keep the tighter circle.
        if (have == null || got == null || got <= have) bestFix = fix;
        final acc = bestFix?.accuracy;
        if (acc != null && acc <= goodEnoughMetres) finish();
      }, onError: (Object _) {
        finish();
      }, cancelOnError: false);
    } catch (_) {
      return current();
    }

    stop = Timer(window, finish);

    // A first reading in parallel, so a device whose watch never fires still
    // answers with something rather than with silence.
    unawaited(current(timeout: window).then((f) {
      if (f == null) return;
      final have = bestFix?.accuracy;
      final got = f.accuracy;
      if (bestFix == null || have == null || got == null || got < have) {
        bestFix = f;
      }
    }));

    final out = await done.future;
    return out ?? await current();
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
