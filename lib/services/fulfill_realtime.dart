import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

/// CHANGE #353: ONE shared realtime channel for the whole Fulfill area.
///
/// Subscribes postgres_changes on order_items, supplier_disputes,
/// bag_item_counts and supplier_count_mode (all events). Events are debounced
/// 400ms and delivered to listeners as the set of tables that changed; the
/// listener (the Fulfill screen) refetches ONLY the visible tab's data.
///
/// Reconnect-safe: on channel error/close it retries with backoff
/// (1s,2s,5s,10s,30s max) and, after a successful re-subscribe, notifies
/// listeners with ALL tables so they run one full refetch.
class FulfillRealtime {
  FulfillRealtime._();
  static final FulfillRealtime instance = FulfillRealtime._();

  static const tables = [
    'order_items',
    'supplier_disputes',
    'bag_item_counts',
    'supplier_count_mode',
    // Kept from #187's fulfill_suppord channel: new supplier orders must still
    // appear on the Collect list without a manual refresh.
    'supplier_orders',
  ];

  final Set<void Function(Set<String> changedTables)> _listeners = {};
  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _retry;
  final Set<String> _pending = {};
  int _backoffIdx = 0;
  static const _backoffSecs = [1, 2, 5, 10, 30];
  bool _up = false;
  bool _hadFirstUp = false;
  bool _readyLogged = false;

  bool get isUp => _up;

  /// Created when a Fulfill tab mounts…
  void addListener(void Function(Set<String>) l) {
    _listeners.add(l);
    if (_channel == null) _subscribe();
  }

  /// …torn down when none is mounted.
  void removeListener(void Function(Set<String>) l) {
    _listeners.remove(l);
    if (_listeners.isEmpty) _teardown();
  }

  void _subscribe() {
    if (_listeners.isEmpty) return;
    try {
      var ch = Supabase.instance.client.channel('fulfill_rt_c353');
      for (final t in tables) {
        ch = ch.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: t,
          callback: (_) => _onEvent(t),
        );
      }
      ch.subscribe((status, [error]) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          _backoffIdx = 0;
          final reconnect = _hadFirstUp && !_up;
          _up = true;
          if (!_readyLogged) {
            _readyLogged = true;
            RenderLog.write('c353_ready', 'rt=v1');
          }
          RenderLog.write('c353_rt_state', 's=up');
          if (reconnect) {
            // One full refetch after re-subscribe — events may have been missed.
            _notify({...tables});
          }
          _hadFirstUp = true;
        } else if (status == RealtimeSubscribeStatus.closed ||
            status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          if (_up) RenderLog.write('c353_rt_state', 's=down');
          _up = false;
          _scheduleRetry();
        }
      });
      _channel = ch;
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _onEvent(String table) {
    _pending.add(table);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final changed = {..._pending};
      _pending.clear();
      // Throttled: max 1 log per debounce window.
      RenderLog.write('c353_rt_event', 'tbl=${changed.join("+")}');
      _notify(changed);
    });
  }

  void _notify(Set<String> changed) {
    for (final l in {..._listeners}) {
      try { l(changed); } catch (_) {}
    }
  }

  void _scheduleRetry() {
    if (_listeners.isEmpty) return;
    _retry?.cancel();
    final secs = _backoffSecs[
        _backoffIdx < _backoffSecs.length ? _backoffIdx : _backoffSecs.length - 1];
    _backoffIdx++;
    _retry = Timer(Duration(seconds: secs), () {
      if (_listeners.isEmpty) return;
      _removeChannel();
      _subscribe();
    });
  }

  void _removeChannel() {
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try { ch.unsubscribe(); } catch (_) {}
      try { Supabase.instance.client.removeChannel(ch); } catch (_) {}
    }
  }

  void _teardown() {
    _debounce?.cancel();
    _debounce = null;
    _retry?.cancel();
    _retry = null;
    _pending.clear();
    _up = false;
    _removeChannel();
  }
}
