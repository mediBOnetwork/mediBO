import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_copy.dart';

/// CMD #1813 — a screen must never go blank because the database was slow.
///
/// Every RPC in the app stalled together at ~13.9 s on 2026-09-06 while the
/// 1 GB instance was IO-bound. The app's own timeout fired at ~15 s and painted
/// an empty body with a Retry button, in front of customers. The database side
/// of that is fixed in `20260906060000_c1813_pool_and_stall.sql`; this is the
/// side that must hold even when the backend is having a bad minute:
///
///   * the LAST SUCCESSFUL payload for a screen is kept on the device,
///   * it is painted immediately and stays painted while a refresh is in
///     flight or failing,
///   * a quiet one-line status — a BACKEND string, never a Dart literal — says
///     what is happening,
///   * the refresh retries on a backoff schedule the BACKEND owns,
///   * there is no Retry button. Ever. [PayloadState.showRetryButton] is a
///     compile-time `false` so a future screen cannot reintroduce one.
///
/// The cache is a render fallback, never an authority (Om's offline rule): it
/// answers "what did this screen last look like", never "who am I" or "what may
/// I do".

/// Where a screen's body currently comes from.
enum PayloadSource {
  /// Nothing has ever loaded — first paint of a brand-new install.
  none,

  /// Read off the device; the network has not answered yet or has failed.
  cache,

  /// This session's own successful fetch.
  network,
}

/// One screen's payload and everything the screen needs to draw around it.
///
/// Pure and immutable on purpose: the never-blank contract is tested on this
/// class rather than through a widget, so it runs on the Dart VM in
/// milliseconds with no network and no Supabase.
@immutable
class PayloadState {
  const PayloadState({
    this.data,
    this.source = PayloadSource.none,
    this.loading = false,
    this.failures = 0,
    this.savedAtMs,
  });

  /// The last payload that a fetch returned successfully, or null if this
  /// device has never seen one for this screen.
  final Map<String, dynamic>? data;

  final PayloadSource source;

  /// A fetch is in flight right now.
  final bool loading;

  /// Consecutive failed fetches. Reset to 0 by any success.
  final int failures;

  /// When [data] was fetched, epoch ms. Never formatted in Dart.
  final int? savedAtMs;

  /// There is something to draw.
  bool get hasBody => data != null;

  /// The body has never loaded, so the screen draws its skeleton. This is the
  /// ONLY state without a body, and it still carries a status line and a live
  /// retry — it is never a dead end.
  bool get showSkeleton => data == null;

  /// A stale body: what is on screen came off the device and the network has
  /// not confirmed it this session.
  bool get isStale => data != null && source != PayloadSource.network;

  /// The never-blank contract, stated once, in one place.
  ///
  /// A bare Retry button is what put an empty screen in front of a customer.
  /// The refresh retries by itself on the backend's own schedule, so there is
  /// nothing for a customer to tap and no state in which tapping is the only
  /// way forward.
  bool get showRetryButton => false;

  /// The `ui_copy` key for the quiet status line, or '' for silence.
  ///
  /// Silence is the normal case: a fresh payload that is not refreshing says
  /// nothing at all. A refresh that lands quickly never gets to speak either,
  /// because the controller only marks [loading] once the fetch has been slow
  /// for the backend's own `net.slow_after_ms`.
  String get statusKey {
    if (data == null) {
      return failures > 0 ? 'net.first_retry' : 'net.first_try';
    }
    if (failures > 0) return 'net.saved_copy';
    if (loading) return 'net.updating';
    return '';
  }

  /// The rendered status line — a backend string, empty when there is nothing
  /// to say. A screen prints this; it never composes it.
  String get statusLine {
    final k = statusKey;
    return k.isEmpty ? '' : UiCopy.t(k);
  }

  /// Whether the status strip is drawn at all.
  bool get showStatusLine => statusLine.isNotEmpty;

  PayloadState copyWith({
    Map<String, dynamic>? data,
    PayloadSource? source,
    bool? loading,
    int? failures,
    int? savedAtMs,
  }) =>
      PayloadState(
        data: data ?? this.data,
        source: source ?? this.source,
        loading: loading ?? this.loading,
        failures: failures ?? this.failures,
        savedAtMs: savedAtMs ?? this.savedAtMs,
      );
}

/// The on-device store. One JSON blob per screen key.
class PayloadStore {
  PayloadStore._();

  static const _prefix = 'payload_cache_v1.';

  /// In-memory mirror so a rebuild, and a test, never touch disk.
  static final Map<String, Map<String, dynamic>> _mem = {};

  /// Turned off in tests so no widget reaches SharedPreferences.
  static bool diskEnabled = true;

  @visibleForTesting
  static void debugSeed(String key, Map<String, dynamic> data, {int? savedAtMs}) {
    _mem[key] = {
      'saved_at_ms': savedAtMs ?? DateTime.now().millisecondsSinceEpoch,
      'data': data,
    };
  }

  @visibleForTesting
  static void debugClear() => _mem.clear();

  static Future<Map<String, dynamic>?> read(String key) async {
    final hit = _mem[key];
    if (hit != null) return hit;
    if (!diskEnabled) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefix$key');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final env = Map<String, dynamic>.from(decoded);
      if (env['data'] is! Map) return null;
      _mem[key] = env;
      return env;
    } catch (_) {
      // A corrupt or unreadable cache is simply a cache miss.
      return null;
    }
  }

  static Future<void> write(String key, Map<String, dynamic> data) async {
    final env = <String, dynamic>{
      'saved_at_ms': DateTime.now().millisecondsSinceEpoch,
      'data': data,
    };
    _mem[key] = env;
    if (!diskEnabled) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefix$key', jsonEncode(env));
    } catch (_) {
      // Storage full or unavailable — the in-memory mirror still stands in for
      // this session, which is the whole point.
    }
  }
}

/// The backoff schedule and the "slow" threshold are BACKEND values, read from
/// `ui_copy`. Changing how hard the app retries is an UPDATE, not a deploy.
class PayloadTiming {
  PayloadTiming._();

  /// `net.retry_backoff_ms` — comma-separated milliseconds, e.g.
  /// "1000,2000,4000,8000,15000,30000". The last entry is the ceiling.
  static List<int> get backoffMs {
    final raw = UiCopy.t('net.retry_backoff_ms');
    final parsed = raw
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((v) => v > 0)
        .toList(growable: false);
    return parsed.isEmpty ? const <int>[1000, 2000, 4000, 8000, 15000, 30000] : parsed;
  }

  /// Delay before attempt number [failures] (1-based).
  static Duration delayFor(int failures) {
    final steps = backoffMs;
    final i = failures <= 0 ? 0 : (failures - 1);
    return Duration(milliseconds: steps[i >= steps.length ? steps.length - 1 : i]);
  }

  /// `net.slow_after_ms` — how long a refresh may run before the quiet
  /// "updating…" line appears. Stops a fast refresh from flickering a banner.
  static Duration get slowAfter {
    final v = int.tryParse(UiCopy.t('net.slow_after_ms').trim());
    return Duration(milliseconds: (v == null || v <= 0) ? 2500 : v);
  }

  /// `net.rpc_timeout_ms` — how long one attempt may run before it is treated
  /// as a failure and the backoff takes over. Deliberately shorter than the
  /// ~15 s at which the app used to give up and blank the screen.
  static Duration get attemptTimeout {
    final v = int.tryParse(UiCopy.t('net.rpc_timeout_ms').trim());
    return Duration(milliseconds: (v == null || v <= 0) ? 9000 : v);
  }
}

/// Drives one screen's payload: cache first, then network, then retry forever
/// on the backend's schedule, without ever emptying the screen.
class PayloadController extends ChangeNotifier {
  PayloadController({
    required this.cacheKey,
    required this.fetch,
  });

  /// Stable per screen (and per scope — include the zone/date the header picker
  /// is on, so one zone's payload never stands in for another's).
  final String cacheKey;

  /// The RPC. Returning null is treated as a failure, not as an empty screen.
  final Future<Map<String, dynamic>?> Function() fetch;

  PayloadState _state = const PayloadState();
  PayloadState get state => _state;

  Timer? _retry;
  Timer? _slow;
  bool _disposed = false;
  int _generation = 0;

  /// Last error text, for the build log — never rendered.
  Object? lastError;

  /// Cache first (instant paint), then network.
  Future<void> start() async {
    final cached = await PayloadStore.read(cacheKey);
    if (_disposed) return;
    if (cached != null && cached['data'] is Map) {
      _set(_state.copyWith(
        data: Map<String, dynamic>.from(cached['data'] as Map),
        source: PayloadSource.cache,
        savedAtMs: cached['saved_at_ms'] is int ? cached['saved_at_ms'] as int : null,
      ));
    }
    await refresh();
  }

  /// One attempt. On success the payload is stored and the failure count
  /// clears; on failure the previous payload STAYS on screen and the next
  /// attempt is scheduled.
  Future<void> refresh() async {
    if (_disposed) return;
    final gen = ++_generation;
    _retry?.cancel();
    _slow?.cancel();

    // The line only appears once the fetch has actually been slow.
    _slow = Timer(PayloadTiming.slowAfter, () {
      if (_disposed || gen != _generation) return;
      _set(_state.copyWith(loading: true));
    });

    try {
      final res = await fetch().timeout(PayloadTiming.attemptTimeout);
      if (_disposed || gen != _generation) return;
      _slow?.cancel();
      if (res == null) throw StateError('empty payload');
      await PayloadStore.write(cacheKey, res);
      if (_disposed || gen != _generation) return;
      lastError = null;
      _set(PayloadState(
        data: res,
        source: PayloadSource.network,
        loading: false,
        failures: 0,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (e) {
      if (_disposed || gen != _generation) return;
      _slow?.cancel();
      lastError = e;
      final failures = _state.failures + 1;
      _set(_state.copyWith(loading: false, failures: failures));
      _schedule(failures);
    }
  }

  void _schedule(int failures) {
    _retry?.cancel();
    _retry = Timer(PayloadTiming.delayFor(failures), () {
      if (_disposed) return;
      refresh();
    });
  }

  void _set(PayloadState next) {
    _state = next;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _slow?.cancel();
    super.dispose();
  }
}
