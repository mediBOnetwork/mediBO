import 'dart:async';

import 'package:flutter/widgets.dart';
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
  _TestSessionLifecycle? _lifecycle;
  StreamSubscription<dynamic>? _auth;

  bool get isOn => banner.value['on'] == true;

  /// Test seam: inject a payload without touching the network.
  @visibleForTesting
  void debugSet(Map<String, dynamic> payload) => banner.value = payload;

  /// Starts the poll. Safe to call more than once — the interval is whatever
  /// the backend last said (`poll_ms`), so it is retuned without a deploy.
  /// CHANGE #1821 — RESUMING IS A READ, NEVER A REMEMBERED FLAG.
  ///
  /// The poll alone is not enough. A backgrounded tab or a phone with the app
  /// suspended freezes the timer, so the first frame the user sees after
  /// coming back is drawn from whatever the payload said minutes ago. Om
  /// reported exactly that shape — "it says off, I close the app, it is on
  /// again" — so the banner is re-read from the backend the instant the app
  /// resumes, and again whenever the signed-in user changes.
  void start() {
    _lifecycle ??= _TestSessionLifecycle(refresh);
    _auth ??= Supabase.instance.client.auth.onAuthStateChange
        .listen((_) => unawaited(refresh()), onError: (_) {});
    if (_timer != null) return;
    unawaited(refresh());
    _schedule(const Duration(seconds: 30));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    unawaited(_auth?.cancel());
    _auth = null;
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

  /// CMD #1848 — End & purge, one tap. The backend ends the caller's OWN
  /// session and purges its rows; `done:false` means the bounded purge wants
  /// another call, so this obeys that flag rather than deciding when a wipe
  /// is finished. Returns the last payload verbatim (its `message` is what the
  /// banner shows). Never throws: a failure comes back as an `error` map.
  Future<Map<String, dynamic>> endAndPurge({int maxRounds = 30}) async {
    Map<String, dynamic> res = const {};
    try {
      var rounds = 0;
      do {
        final raw = await Supabase.instance.client.rpc('test_session_end_purge');
        res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
        rounds++;
      } while (res['done'] == false && res['ok'] == true && rounds < maxRounds);
    } catch (e) {
      res = {'ok': false, 'error': '$e'};
    }
    await refresh();
    return res;
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

/// The resume hook, kept out of the service so the service stays a plain
/// singleton a test can drive with no binding attached.
class _TestSessionLifecycle with WidgetsBindingObserver {
  _TestSessionLifecycle(this._onResume) {
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {
      // No binding (a pure-Dart test): the poll alone is fine there.
    }
  }

  final Future<void> Function() _onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_onResume());
  }

  void dispose() {
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
  }
}
