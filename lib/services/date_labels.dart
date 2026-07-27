// CHANGE #546 — the client's ONLY route to a date string.
//
// mediBO does no date work in Dart: no formatting, no timezone conversion, no
// "today" computation, no relative-time math, no Today/Yesterday decision. All
// of it lives in Postgres (ist_fmt / ist_labels, see the #546 migration). This
// service is the transport: hand it the raw timestamp a row already carries plus
// the style you need, and it returns the backend's ready-to-render string.
//
// Batching: label() is called from build(), so requests are coalesced into ONE
// ist_labels() round-trip per frame rather than one RPC per row. Until a label
// lands the getter returns null and callers render their own empty state —
// there is deliberately NO client-side fallback string anywhere.
//
// Staleness: 'relative' and 'day_sep' depend on "now", so their cache entries
// carry a TTL and are re-resolved; absolute styles are immutable per timestamp
// and cached for the session.
import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

/// Backend style tokens. These are the only values the client may pass; the
/// actual format each one produces is owned by ist_fmt() in Postgres.
class DateStyle {
  /// 26/07/2026
  static const dmy = 'dmy';

  /// 26 Jul 2026
  static const dayMonYear = 'day_mon_year';

  /// 3:45 PM
  static const time12 = 'time12';

  /// 26/07/26 3:45 PM
  static const dmy2Time12 = 'dmy2_time12';

  /// 26/07/2026  15:45  (two spaces)
  static const dmyHm2 = 'dmy_hm2';

  /// 26/07/2026 15:45
  static const dmyHm = 'dmy_hm';

  /// 26/07/26 15:45
  static const dmy2Hm = 'dmy2_hm';

  /// just now / 5m ago / 3h ago / 2d ago
  static const relative = 'relative';

  /// Today / Yesterday / 26 Jul 2026
  static const daySep = 'day_sep';

  /// Styles whose output depends on the current time.
  static const _timeSensitive = {relative, daySep};
}

class DateLabels {
  DateLabels._();
  static final DateLabels instance = DateLabels._();

  static const _ttl = Duration(seconds: 60);

  final Map<String, String> _cache = {};
  final Map<String, DateTime> _stamped = {};
  final Set<String> _pending = {};
  final Set<String> _inFlight = {};
  Timer? _flush;

  final Set<void Function()> _listeners = {};
  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _notify() {
    for (final l in {..._listeners}) {
      try {
        l();
      } catch (_) {}
    }
  }

  String _key(String ts, String style) => '$style|$ts';

  bool _expired(String key, String style) {
    if (!DateStyle._timeSensitive.contains(style)) return false;
    final at = _stamped[key];
    // Compared against the transport clock only — this decides WHEN to re-ask
    // the backend, never what the label says.
    return at == null ||
        DateTime.now().difference(at).compareTo(_ttl) > 0;
  }

  /// The backend's label for [ts] in [style], or null until it lands.
  /// Safe to call from build() — it batches and never blocks.
  String? label(String? ts, String style) {
    if (ts == null || ts.isEmpty) return null;
    final key = _key(ts, style);
    final hit = _cache[key];
    if (hit != null && !_expired(key, style)) return hit;
    if (!_inFlight.contains(key)) {
      _pending.add(key);
      _schedule();
    }
    return hit; // stale-but-present beats blank while re-resolving
  }

  void _schedule() {
    _flush?.cancel();
    _flush = Timer(const Duration(milliseconds: 16), _run);
  }

  Future<void> _run() async {
    if (_pending.isEmpty) return;
    final batch = _pending.toList();
    _pending.clear();
    _inFlight.addAll(batch);
    try {
      final items = batch.map((k) {
        final i = k.indexOf('|');
        return {'k': k, 'style': k.substring(0, i), 'ts': k.substring(i + 1)};
      }).toList();

      final res = await Supabase.instance.client
          .rpc('ist_labels', params: {'p_items': items});

      if (res is Map) {
        final now = DateTime.now();
        var n = 0;
        res.forEach((k, v) {
          if (v == null) return;
          _cache[k.toString()] = v.toString();
          _stamped[k.toString()] = now;
          n++;
        });
        if (n > 0) {
          RenderLog.write('c546_date_labels', 'resolved=$n');
          _notify();
        }
      }
    } catch (_) {
      // No fallback by design — callers keep rendering their empty state and a
      // later build() re-queues the request.
    } finally {
      _inFlight.removeAll(batch);
    }
  }
}
