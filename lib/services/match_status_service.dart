import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class MatchStatus {
  final int total;
  final int matched;
  final int pending;
  final int needsReview;
  final int noMatch;
  final bool isMatching;
  final DateTime? claimedUntil;
  final int attempts;
  final String? lastError;

  const MatchStatus({
    required this.total,
    required this.matched,
    required this.pending,
    required this.needsReview,
    required this.noMatch,
    required this.isMatching,
    this.claimedUntil,
    required this.attempts,
    this.lastError,
  });

  factory MatchStatus.fromMap(Map<String, dynamic> m) => MatchStatus(
        total: (m['total'] as int?) ?? 0,
        matched: (m['matched'] as int?) ?? 0,
        pending: (m['pending'] as int?) ?? 0,
        needsReview: (m['needs_review'] as int?) ?? 0,
        noMatch: (m['no_match'] as int?) ?? 0,
        isMatching: (m['is_matching'] as bool?) ?? false,
        claimedUntil: m['claimed_until'] != null
            ? DateTime.tryParse(m['claimed_until'] as String)
            : null,
        attempts: (m['attempts'] as int?) ?? 0,
        lastError: m['last_error'] as String?,
      );

  // Optimistic copy that marks this supplier as currently matching.
  MatchStatus withMatching() => MatchStatus(
        total: total,
        matched: matched,
        pending: total > 0 ? total : pending,
        needsReview: needsReview,
        noMatch: noMatch,
        isMatching: true,
        claimedUntil: claimedUntil,
        attempts: attempts,
        lastError: lastError,
      );
}

// ── Service ───────────────────────────────────────────────────────────────────

class MatchStatusService {
  final ValueNotifier<Map<String, MatchStatus>> statuses =
      ValueNotifier<Map<String, MatchStatus>>({});

  List<String> _visibleIds = const [];
  Timer? _timer;
  bool _disposed = false;

  // Per-supplier last-kick timestamp — throttles stale-resume re-kicks.
  final Map<String, DateTime> _lastKick = {};

  static const _pollInterval = Duration(seconds: 4);
  static const _staleThreshold = Duration(seconds: 150);
  static const _kickThrottle = Duration(seconds: 60);

  SupabaseClient get _client => Supabase.instance.client;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Updates the set of supplier IDs that the list currently shows.
  /// Starts/stops the poller automatically based on whether any are matching.
  void setVisibleIds(List<String> ids) {
    _visibleIds = List.unmodifiable(ids);
    if (_visibleIds.isEmpty) {
      _stopPoller();
      return;
    }
    _pollOnce(); // immediate first fetch
    _ensurePollerRunning();
  }

  /// One-shot status fetch for a given set of IDs — updates [statuses].
  Future<void> fetchStatuses(List<String> ids) async {
    if (ids.isEmpty || _disposed) return;
    try {
      final raw = await _client
          .rpc('supplier_match_statuses', params: {'p_ids': ids});
      final rows = (((raw is List ? raw.first : raw) as Map)['rows']
          as List<dynamic>? ?? const []);
      if (_disposed) return;
      final updated = Map<String, MatchStatus>.from(statuses.value);
      for (final row in (rows as List)) {
        final r = row as Map<String, dynamic>;
        final sid = r['supplier_id'] as String? ?? '';
        if (sid.isNotEmpty) updated[sid] = MatchStatus.fromMap(r);
      }
      statuses.value = updated;
    } catch (_) {}
  }

  /// Enqueue a re-match for [supplierId], fire-and-forget the worker,
  /// and optimistically mark the supplier as matching.
  /// Throws on RPC failure so the caller can surface a snackbar.
  Future<void> reMatch(String supplierId) async {
    await _client.rpc(
        'enqueue_supplier_match', params: {'p_supplier_id': supplierId});

    // Fire-and-forget worker — errors silently swallowed.
    _kickWorker(supplierId);

    // Optimistic UI update.
    final current = Map<String, MatchStatus>.from(statuses.value);
    if (current.containsKey(supplierId)) {
      current[supplierId] = current[supplierId]!.withMatching();
    } else {
      current[supplierId] = const MatchStatus(
        total: 0, matched: 0, pending: 0,
        needsReview: 0, noMatch: 0, isMatching: true, attempts: 0,
      );
    }
    statuses.value = current;

    _ensurePollerRunning();
    RenderLog.write('change76_rematch_clicked', {'supplierId': supplierId});
  }

  void dispose() {
    _disposed = true;
    _stopPoller();
    statuses.dispose();
  }

  // ── Internals ───────────────────────────────────────────────────────────────

  void _kickWorker(String supplierId) {
    _lastKick[supplierId] = DateTime.now();
    try {
      _client.functions
          .invoke('match-worker', body: {'supplier_id': supplierId})
          .catchError((_) {});
    } catch (_) {}
  }

  Future<void> _pollOnce() async {
    if (_visibleIds.isEmpty || _disposed) return;
    await fetchStatuses(_visibleIds);
    if (_disposed) return;

    final now = DateTime.now();
    final current = statuses.value;
    int matchingCount = 0;

    for (final id in _visibleIds) {
      final s = current[id];
      if (s == null || !s.isMatching) continue;
      matchingCount++;

      // Stale-resume: worker claimed a run but claimedUntil is past+150s.
      final claimed = s.claimedUntil;
      final isStale =
          claimed == null || claimed.isBefore(now.subtract(_staleThreshold));
      if (isStale) {
        final lastK = _lastKick[id];
        final throttleOk =
            lastK == null || now.difference(lastK) > _kickThrottle;
        if (throttleOk) _kickWorker(id);
      }
    }

    RenderLog.write('change76_poll_cycle',
        {'visible': _visibleIds.length, 'matching': matchingCount});

    if (matchingCount == 0) _stopPoller();
  }

  void _ensurePollerRunning() {
    if (_timer != null || _disposed) return;
    _timer = Timer.periodic(_pollInterval, (_) => _pollOnce());
    RenderLog.write(
        'change76_poller_started', {'suppliers': _visibleIds.length});
  }

  void _stopPoller() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    RenderLog.write(
        'change76_poller_stopped', {'suppliers': _visibleIds.length});
  }
}
