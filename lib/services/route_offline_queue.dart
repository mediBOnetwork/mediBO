// lib/services/route_offline_queue.dart — CMD #1878
//
// A rep walks a route through a basement, a lift and a village with one bar.
// The screen must keep working, and a check-in made with no network must land
// EXACTLY ONCE when the phone comes back.
//
// Two things live here and nothing else:
//   * the CACHE — route_offline_bundle()'s payload, written on every good
//     load and re-rendered verbatim when the next load fails;
//   * the QUEUE — check-ins made offline, replayed in the order they were
//     made through route_stop_checkin(p_client_ts), which is idempotent on
//     (stop_id, client_ts). The device clock reading IS the idempotency key,
//     so a replay that crosses a successful first attempt is a no-op server
//     side and returns that first attempt's own payload.
//
// NOTHING here words anything. The pending chip, the offline banner and the
// "saved on this device" toast are all strings out of the bundle's `sync`
// block, which the backend pre-worded for every count it can realistically
// show — see _c1878_sync_block(). The one substitution below fills the
// backend's own {n} slot for a count past that ladder.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One check-in the device is holding. `clientTs` is stamped when the rep
/// tapped Save — not when it is finally sent — so the server dedupes on the
/// tap, and replaying a queue twice can never double-count a stop.
class PendingCheckIn {
  final String stopId;
  final String routeId;
  final String status;
  final String note;
  final String clientTs; // ISO-8601 with offset

  const PendingCheckIn({
    required this.stopId,
    required this.routeId,
    required this.status,
    this.note = '',
    required this.clientTs,
  });

  Map<String, dynamic> toJson() => {
        'stop_id': stopId,
        'route_id': routeId,
        'status': status,
        'note': note,
        'client_ts': clientTs,
      };

  static PendingCheckIn? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final stop = raw['stop_id']?.toString() ?? '';
    final status = raw['status']?.toString() ?? '';
    final ts = raw['client_ts']?.toString() ?? '';
    if (stop.isEmpty || status.isEmpty || ts.isEmpty) return null;
    return PendingCheckIn(
      stopId: stop,
      routeId: raw['route_id']?.toString() ?? '',
      status: status,
      note: raw['note']?.toString() ?? '',
      clientTs: ts,
    );
  }

  /// route_stop_checkin() params. The device timestamp always travels: it is
  /// what makes the call idempotent.
  Map<String, dynamic> rpcParams() => {
        'p_stop_id': stopId,
        'p_status': status,
        if (note.trim().isNotEmpty) 'p_note': note.trim(),
        'p_client_ts': clientTs,
      };

  /// Two entries are the same check-in when the server would dedupe them.
  bool sameAs(PendingCheckIn o) => o.stopId == stopId && o.clientTs == clientTs;
}

/// The queue's pure decisions — every one of them testable on the Dart VM
/// with no plugin, no network and no widget.
class RouteSyncPlan {
  const RouteSyncPlan._();

  /// The chip's caption. The backend pre-worded 1..30 so no count a rep can
  /// reach is pluralised in Dart; past that its own {n} template is filled.
  /// A count of zero has no chip at all — absence, not a "0 pending" string.
  static String? pendingLabel(Map<String, dynamic>? sync, int n) {
    if (n <= 0) return null;
    final labels = sync?['labels'];
    if (labels is Map) {
      final hit = labels['$n'];
      if (hit != null && hit.toString().isNotEmpty) return hit.toString();
    }
    final tpl = sync?['labels_fallback']?.toString() ?? '';
    if (tpl.isEmpty) return null;
    return tpl.replaceAll('{n}', '$n');
  }

  /// Replay order is the order the rep made them, oldest first. The server
  /// writes the lead's visit history in that order, so a "Visited" followed
  /// by a "Converted" on the same shop ends converted, never the reverse.
  static List<PendingCheckIn> ordered(List<PendingCheckIn> items) {
    final out = List<PendingCheckIn>.from(items);
    out.sort((a, b) => a.clientTs.compareTo(b.clientTs));
    return out;
  }

  /// The server accepted it — a fresh write or the idempotent replay of one
  /// that already landed. Both mean: drop it from the queue.
  static bool landed(Object? res) {
    if (res is! Map) return false;
    return res['ok'] == true;
  }

  /// The replay hit a check-in that was already recorded. Not an error — the
  /// backend returned the FIRST call's own payload.
  static bool duplicate(Object? res) => res is Map && res['duplicate'] == true;

  /// A refusal the queue must not retry forever: the stop is gone, the route
  /// left the active date, or the outcome is not a real one. Anything else
  /// (a socket error, a 5xx) stays queued for the next attempt.
  static bool permanentFailure(Object? res) {
    if (res is! Map) return false;
    if (res['ok'] != false) return false;
    const fatal = {'stop_not_found', 'bad_status', 'not_authorized'};
    return fatal.contains(res['error']?.toString());
  }

  /// Adding one check-in to a queue: same (stop, client_ts) never doubles,
  /// and a NEW answer for a stop still queued replaces the old one — the rep
  /// corrected himself before anything reached the server.
  static List<PendingCheckIn> merge(
      List<PendingCheckIn> queue, PendingCheckIn entry) {
    final out = queue.where((e) => e.stopId != entry.stopId).toList();
    out.add(entry);
    return ordered(out);
  }
}

/// Where the queue and the cached bundle actually live. Injectable so the
/// protected test runs on the Dart VM without the shared_preferences plugin.
abstract class RouteOfflineStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class PrefsRouteOfflineStore implements RouteOfflineStore {
  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);

  @override
  Future<void> remove(String key) async =>
      (await SharedPreferences.getInstance()).remove(key);
}

/// An in-memory store — the test's, and the fallback when the platform has no
/// preferences at all (a locked-down browser). Losing the queue is better
/// than losing the screen.
class MemoryRouteOfflineStore implements RouteOfflineStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// The device's check-in queue and its cached route.
///
/// The caller hands it an `rpc` — nothing here knows Supabase exists, which is
/// why the whole replay is testable.
class RouteOfflineQueue extends ChangeNotifier {
  static const String queueKey = 'c1878_checkin_queue';
  static const String bundleKey = 'c1878_route_bundle';

  RouteOfflineQueue({RouteOfflineStore? store})
      : _store = store ?? PrefsRouteOfflineStore();

  static final RouteOfflineQueue instance = RouteOfflineQueue();

  final RouteOfflineStore _store;

  List<PendingCheckIn> _pending = const [];
  bool _syncing = false;
  bool _loaded = false;

  List<PendingCheckIn> get pending => List.unmodifiable(_pending);
  int get pendingCount => _pending.length;
  bool get syncing => _syncing;

  /// Read the queue back off the device. Safe to call repeatedly.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await _store.read(queueKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _pending = RouteSyncPlan.ordered(decoded
          .map(PendingCheckIn.fromJson)
          .whereType<PendingCheckIn>()
          .toList());
      notifyListeners();
    } catch (_) {
      // A corrupt queue is dropped, never crashed on.
    }
  }

  Future<void> _persist() async {
    try {
      await _store.write(
          queueKey, jsonEncode(_pending.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  /// Hold a check-in made with no network.
  Future<void> enqueue(PendingCheckIn entry) async {
    _pending = RouteSyncPlan.merge(_pending, entry);
    await _persist();
    notifyListeners();
  }

  /// Replay everything held, oldest first, stopping at the first entry the
  /// network refuses so the ORDER is never broken by a gap. Returns how many
  /// landed (a duplicate counts: it is already on the server).
  Future<int> flush(
      Future<Object?> Function(Map<String, dynamic> params) rpc) async {
    await load();
    if (_syncing || _pending.isEmpty) return 0;
    _syncing = true;
    notifyListeners();

    var landed = 0;
    try {
      for (final entry in RouteSyncPlan.ordered(_pending)) {
        Object? res;
        try {
          res = await rpc(entry.rpcParams());
        } catch (_) {
          // Still offline (or the server blinked). Everything after this one
          // stays queued, in order, for the next attempt.
          break;
        }
        if (RouteSyncPlan.landed(res) || RouteSyncPlan.permanentFailure(res)) {
          _pending = _pending.where((e) => !e.sameAs(entry)).toList();
          if (RouteSyncPlan.landed(res)) landed++;
          await _persist();
          notifyListeners();
        } else {
          break;
        }
      }
    } finally {
      _syncing = false;
      notifyListeners();
    }
    return landed;
  }

  // ── the cached route ─────────────────────────────────────────────────────

  /// Store route_offline_bundle()'s payload exactly as it arrived.
  Future<void> cacheBundle(Map<String, dynamic> bundle) async {
    try {
      await _store.write(bundleKey, jsonEncode(bundle));
    } catch (_) {}
  }

  /// The last good bundle, or null when the device has never had one.
  Future<Map<String, dynamic>?> cachedBundle() async {
    try {
      final raw = await _store.read(bundleKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// Test seam only.
  @visibleForTesting
  void resetForTest() {
    _pending = const [];
    _loaded = false;
    _syncing = false;
  }
}
