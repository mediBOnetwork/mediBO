// lib/services/worker_live_ping.dart — CMD #1878
//
// The lead worker's dot. While the Routes tab is open and the rep has said
// yes, this posts a position fix to route_worker_ping() on the interval the
// BACKEND asked for (`ping_ms` in route_worker_dots()), and stops the moment
// the screen goes away.
//
// It decides nothing. It does not know what a stale dot looks like, how often
// is "often enough", or what to tell the rep when the browser refuses — the
// interval and every string come from the payload.
//
// DEFENSIVE IMPORT RULE: the browser Geolocation API is NOT touched here. It
// is reached through device_location.dart, the one conditionally-exported
// file allowed to hold dart:html.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'device_location.dart';

class WorkerLivePing {
  WorkerLivePing._();
  static final WorkerLivePing instance = WorkerLivePing._();

  Timer? _timer;
  bool _inFlight = false;

  /// True while this device is sharing. Exposed as a listenable so the toggle
  /// and the chip can never disagree with the timer.
  final ValueNotifier<bool> sharing = ValueNotifier<bool>(false);

  /// The last refusal the browser gave, as the BACKEND worded it. Null when
  /// there is nothing to say.
  final ValueNotifier<String?> denied = ValueNotifier<String?>(null);

  /// Start pinging. [everyMs] is the backend's `ping_ms`; [send] posts one fix
  /// and returns the RPC's reply (or null when it failed). [deniedLabel] is
  /// the payload's own copy for a browser that will not give a fix.
  void start({
    required int everyMs,
    required Future<Object?> Function(
            double lat, double lng, double? accuracy, double? heading)
        send,
    required String deniedLabel,
  }) {
    stop();
    sharing.value = true;
    denied.value = null;
    final period = Duration(milliseconds: everyMs < 5000 ? 5000 : everyMs);
    _tick(send, deniedLabel);
    _timer = Timer.periodic(period, (_) => _tick(send, deniedLabel));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    sharing.value = false;
  }

  Future<void> _tick(
      Future<Object?> Function(double, double, double?, double?) send,
      String deniedLabel) async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final fix = await DeviceLocation.current();
      if (fix == null) {
        // No fix is not an error the app invents copy for — it shows the
        // backend's own line and keeps trying on the next tick.
        denied.value = deniedLabel.isEmpty ? null : deniedLabel;
        return;
      }
      denied.value = null;
      await send(fix.lat, fix.lng, fix.accuracy, fix.heading);
    } catch (_) {
      // Offline, or the RPC blinked. The next tick tries again; the dot the
      // admin sees simply ages, and the backend words that age.
    } finally {
      _inFlight = false;
    }
  }
}
