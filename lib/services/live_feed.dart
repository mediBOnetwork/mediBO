import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

/// CHANGE #643 — the app stops deciding what deserves a realtime channel.
///
/// Realtime decodes the WAL once per published table per subscriber, so every
/// `postgres_changes` binding the app opens is a standing cost on the database
/// and on the 5M-message allowance (7.44M used last cycle, 95.9% of it
/// postgres_changes, with zero customers online). Which tables earn that cost
/// is a business call, not a widget's call — so it lives in the backend, in
/// `realtime_table_registry`, and arrives here through `realtime_plan()`.
///
/// A caller says WHICH tables it cares about and WHAT to do when they change.
/// This class decides nothing except how to obey the plan:
///   * `mode: 'live'` → open a postgres_changes binding, as before.
///   * `mode: 'poll'` → a timer on the backend's own `poll_seconds`.
/// Moving a table between the two, or changing the interval, is one UPDATE in
/// the registry — no deploy, no code change here.
///
/// The plan is fetched once per app session. If it cannot be read the app
/// POLLS everything: an unreachable plan must never be read as permission to
/// open 29 channels.
class LiveFeedTablePlan {
  const LiveFeedTablePlan({
    required this.mode,
    required this.filterRequired,
    required this.pollSeconds,
  });

  final String mode; // 'live' | 'poll'
  final bool filterRequired;
  final int pollSeconds;

  bool get isLive => mode == 'live';

  static LiveFeedTablePlan fromJson(Map<String, dynamic> j, int fallbackPoll) =>
      LiveFeedTablePlan(
        mode: (j['mode'] ?? 'poll').toString(),
        filterRequired: j['filter_required'] == true,
        pollSeconds: (j['poll_seconds'] as num?)?.toInt() ?? fallbackPoll,
      );
}

class LiveFeedPlan {
  const LiveFeedPlan(this.tables, this.defaultPollSeconds);

  final Map<String, LiveFeedTablePlan> tables;
  final int defaultPollSeconds;

  /// A table the plan has never heard of polls at the default interval — the
  /// forward-compatible answer, and the cheap one.
  LiveFeedTablePlan forTable(String table) =>
      tables[table] ??
      LiveFeedTablePlan(
        mode: 'poll',
        filterRequired: false,
        pollSeconds: defaultPollSeconds,
      );

  static const fallback = LiveFeedPlan(<String, LiveFeedTablePlan>{}, 30);
}

/// One watch. Dispose it when the surface goes away.
class LiveFeedHandle {
  LiveFeedHandle._(this._dispose);
  final void Function() _dispose;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _dispose();
  }
}

class LiveFeed {
  LiveFeed._();
  static final LiveFeed instance = LiveFeed._();

  Future<LiveFeedPlan>? _planFuture;

  /// Cached for the life of the session. `refresh: true` re-reads it, which is
  /// what a "the registry changed" action would call.
  Future<LiveFeedPlan> plan({bool refresh = false}) {
    if (refresh) _planFuture = null;
    return _planFuture ??= _loadPlan();
  }

  Future<LiveFeedPlan> _loadPlan() async {
    try {
      final raw = await Supabase.instance.client.rpc('realtime_plan');
      final m = raw is List
          ? (raw.isEmpty ? const <String, dynamic>{} : Map<String, dynamic>.from(raw.first as Map))
          : Map<String, dynamic>.from(raw as Map);
      final fallbackPoll = (m['default_poll_seconds'] as num?)?.toInt() ?? 30;
      final tables = <String, LiveFeedTablePlan>{};
      final t = m['tables'];
      if (t is Map) {
        t.forEach((k, v) {
          if (v is Map) {
            tables[k.toString()] =
                LiveFeedTablePlan.fromJson(Map<String, dynamic>.from(v), fallbackPoll);
          }
        });
      }
      RenderLog.write('c643_plan',
          'live=${m['live_count']} tables=${tables.length}');
      return LiveFeedPlan(tables, fallbackPoll);
    } catch (_) {
      // Unreadable plan = poll everything. Never the other way round.
      RenderLog.write('c643_plan', 'fallback=poll_all');
      return LiveFeedPlan.fallback;
    }
  }

  /// Watch [tables]. [onChange] is called with the set of tables that moved —
  /// live bindings deliver the table that actually fired, a poll tick delivers
  /// the polled tables it covers.
  ///
  /// [filters] supplies the per-table `column=eq.value` narrowing. A table the
  /// plan marks `filter_required` and that is handed no filter is POLLED: an
  /// unfiltered binding on that table is exactly the fan-out this change
  /// exists to remove.
  Future<LiveFeedHandle> watch({
    required String channelPrefix,
    required List<String> tables,
    required void Function(Set<String> changed) onChange,
    Map<String, PostgresChangeFilter>? filters,
    Duration debounce = const Duration(milliseconds: 400),
  }) async {
    final p = await plan();
    final live = <String>[];
    final polled = <String>[];
    var pollSeconds = p.defaultPollSeconds;

    for (final t in tables) {
      final tp = p.forTable(t);
      final hasFilter = filters != null && filters[t] != null;
      if (tp.isLive && (!tp.filterRequired || hasFilter)) {
        live.add(t);
      } else {
        polled.add(t);
        if (tp.pollSeconds < pollSeconds) pollSeconds = tp.pollSeconds;
      }
    }

    Timer? debounceTimer;
    final pending = <String>{};
    void fire(Set<String> changed) {
      if (changed.isEmpty) return;
      pending.addAll(changed);
      debounceTimer?.cancel();
      debounceTimer = Timer(debounce, () {
        final out = {...pending};
        pending.clear();
        try {
          onChange(out);
        } catch (_) {}
      });
    }

    RealtimeChannel? channel;
    if (live.isNotEmpty) {
      final client = Supabase.instance.client;
      final ts = DateTime.now().millisecondsSinceEpoch;
      var ch = client.channel('${channelPrefix}_$ts');
      for (final t in live) {
        ch = ch.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: t,
          filter: filters?[t],
          callback: (_) => fire({t}),
        );
      }
      channel = ch..subscribe();
    }

    Timer? poll;
    if (polled.isNotEmpty) {
      poll = Timer.periodic(Duration(seconds: pollSeconds), (_) => fire({...polled}));
    }

    RenderLog.write('c643_watch',
        '$channelPrefix live=${live.length} poll=${polled.length}@${pollSeconds}s');

    return LiveFeedHandle._(() {
      debounceTimer?.cancel();
      poll?.cancel();
      final c = channel;
      if (c != null) {
        try {
          Supabase.instance.client.removeChannel(c);
        } catch (_) {}
      }
    });
  }
}
