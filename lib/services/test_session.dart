import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// CHANGE #573 — the platform-wide TEST MODE signal.
///
/// Om switches test mode on in admin and then walks the real order flow by
/// hand from his own customer / supplier / partner / delivery logins. Every
/// one of those screens has to say, unmissably, that nothing here is real —
/// so the signal cannot live inside the admin screen that set it.
///
/// THE APP RENDERS. IT NEVER DECIDES. This service holds exactly what
/// `test_session_banner()` returned and nothing else: the words, the label,
/// the expiry line and even the poll interval are the backend's. When the
/// payload says `on: false` the banner is absent — there is no local rule
/// about when to show it.
class TestSessionState {
  TestSessionState._();

  static final TestSessionState instance = TestSessionState._();

  /// The last banner payload, verbatim. Empty until the first reply lands.
  final ValueNotifier<Map<String, dynamic>> banner =
      ValueNotifier<Map<String, dynamic>>(const {});

  Timer? _timer;
  bool _inFlight = false;

  bool get isOn => banner.value['on'] == true;

  /// Test seam: inject a payload without touching the network.
  @visibleForTesting
  void debugSet(Map<String, dynamic> payload) => banner.value = payload;

  /// Starts the poll. Safe to call more than once — the interval is whatever
  /// the backend last said (`poll_ms`), so it is retuned without a deploy.
  void start() {
    if (_timer != null) return;
    unawaited(refresh());
    _schedule(const Duration(seconds: 30));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(Duration fallback) {
    _timer?.cancel();
    final ms = banner.value['poll_ms'];
    final d = ms is int && ms > 0 ? Duration(milliseconds: ms) : fallback;
    _timer = Timer(d, () async {
      await refresh();
      _schedule(fallback);
    });
  }

  /// One read. A failure leaves the last payload standing: losing the network
  /// must never make a live test session look like production.
  Future<void> refresh() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final raw = await Supabase.instance.client.rpc('test_session_banner');
      if (raw is Map) {
        banner.value = Map<String, dynamic>.from(raw);
      }
    } catch (_) {
      // Keep the last known state.
    } finally {
      _inFlight = false;
    }
  }
}
