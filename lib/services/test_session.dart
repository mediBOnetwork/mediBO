import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
///
/// CMD #1848 — THE SESSION IS BOUND TO THIS INSTALL, CARRIED AS A HEADER.
/// Starting test mode (admin only) returns an opaque token. It is kept in
/// shared_preferences (Android and web alike — never dart:html) and sent on
/// EVERY request as `x-medibo-test-session`, attached in exactly one place:
/// the header map of the one Supabase client every RPC and table read goes
/// through. Postgres resolves the session from that header; a request with
/// no header takes byte-identical today-behaviour. Whoever signs in on this
/// install is inside the session until it ends: the backend's `token` /
/// `clear_token` in an action result is the only thing that sets or clears
/// it here — the app never decides on its own that a session is over.
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

  /// The header the backend reads (`current_setting('request.headers')`).
  static const String headerName = 'x-medibo-test-session';
  static const String _prefKey = 'medibo_test_session_token';

  String? _token;

  /// The token this install carries, or null when it is not in test mode.
  String? get token => _token;

  /// PURE. The header map an install carrying [token] sends: the token is
  /// added under [headerName], a null/empty token removes it, and every
  /// other header (apikey, Authorization, …) is left exactly as it was.
  static Map<String, String> headersWith(
      Map<String, String> current, String? token) {
    final h = Map<String, String>.from(current);
    if (token == null || token.isEmpty) {
      h.remove(headerName);
    } else {
      h[headerName] = token;
    }
    return h;
  }

  /// Boot: read the stored token and attach it BEFORE the first request, so
  /// an install that was in test mode yesterday is still in it today. A
  /// failure to read leaves the install out of test mode — never the reverse.
  Future<void> loadToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getString(_prefKey);
      _token = (t == null || t.isEmpty) ? null : t;
    } catch (_) {
      _token = null;
    }
    _applyHeader();
  }

  /// Stores (or clears) the token and re-attaches the header. Called only
  /// from [absorb], i.e. only with what the backend said.
  Future<void> setToken(String? token) async {
    _token = (token == null || token.isEmpty) ? null : token;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_token == null) {
        await prefs.remove(_prefKey);
      } else {
        await prefs.setString(_prefKey, _token!);
      }
    } catch (_) {
      // The header is still applied for this run; the next boot re-reads.
    }
    _applyHeader();
    unawaited(refresh());
  }

  /// The ONE place the header is attached. `rest.headers` is the mutable
  /// map every rpc()/from() copies at call time; `client.headers` feeds
  /// from()/schema(); functions.headers covers edge-function calls. The
  /// client's `headers` SETTER is deliberately not used — it rebuilds the
  /// REST headers from scratch and would drop apikey/Authorization.
  void _applyHeader() {
    try {
      final c = Supabase.instance.client;
      _patch(c.rest.headers);
      _patch(c.headers);
      try {
        _patch(c.functions.headers);
      } catch (_) {}
    } catch (_) {
      // No client yet (a pure-Dart test): nothing to attach to.
    }
  }

  void _patch(Map<String, String> live) {
    final next = headersWith(live, _token);
    live
      ..clear()
      ..addAll(next);
  }

  /// Applies what the backend said about the token in an action result:
  /// `token` (a session was started or re-issued for this install) stores
  /// it; `clear_token:true` (this install's session ended) removes it. Any
  /// other payload leaves the install as it was.
  Future<void> absorb(Map<String, dynamic> res) async {
    final t = res['token'];
    if (t is String && t.isNotEmpty) {
      await setToken(t);
    } else if (res['clear_token'] == true) {
      await setToken(null);
    }
  }

  /// Test seam: inject a payload without touching the network.
  @visibleForTesting
  void debugSet(Map<String, dynamic> payload) => banner.value = payload;

  /// CMD #1850 — THE SESSION CLOCK, verbatim from `test_clock_state()`.
  ///
  /// A live session may pin an effective time so that the order cut-off,
  /// order hours, an expiring token and every SLA countdown can be walked
  /// through in seconds instead of waited out. Everything here is the
  /// backend's: the rendered time, the sub-line, the step sizes, the preset
  /// moments and every word on every control. The app sends what was tapped
  /// and prints what came back.
  final ValueNotifier<Map<String, dynamic>> clock =
      ValueNotifier<Map<String, dynamic>>(const {});

  @visibleForTesting
  void debugSetClock(Map<String, dynamic> payload) => clock.value = payload;

  /// One read, made only while a session is actually on — an install that is
  /// not testing never asks what time it thinks it is.
  Future<void> refreshClock() async {
    try {
      final raw = await Supabase.instance.client.rpc('test_clock_state');
      if (raw is Map) clock.value = Map<String, dynamic>.from(raw);
    } catch (_) {
      // Keep the last known state: a dropped request must never make a
      // pinned clock look like the real one.
    }
  }

  /// The three verbs. Each returns the backend's own reply verbatim (its
  /// `message` is what the sheet shows) and adopts the state it came with,
  /// so the control redraws from the server's answer and never from a guess
  /// about what the tap did.
  Future<Map<String, dynamic>> pinClock(String at) =>
      _clockCall('test_clock_pin', {'p_at': at});

  Future<Map<String, dynamic>> stepClock(int minutes) =>
      _clockCall('test_clock_step', {'p_minutes': minutes});

  Future<Map<String, dynamic>> releaseClock() =>
      _clockCall('test_clock_release', const {});

  Future<Map<String, dynamic>> _clockCall(
      String fn, Map<String, dynamic> params) async {
    Map<String, dynamic> res;
    try {
      final raw = params.isEmpty
          ? await Supabase.instance.client.rpc(fn)
          : await Supabase.instance.client.rpc(fn, params: params);
      res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
    if (res['has'] == true) clock.value = res;
    return res;
  }

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
    await absorb(res);
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
      // CMD #1850 — the clock rides the banner's own cadence. Off means there
      // is nothing to read and nothing to draw.
      if (banner.value['on'] == true) {
        await refreshClock();
      } else if (clock.value.isNotEmpty) {
        clock.value = const {};
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
