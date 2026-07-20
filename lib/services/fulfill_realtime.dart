import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

/// #416: sentinel proving the Bags/Disputes tabs are driven by Supabase
/// Realtime postgres_changes, not a polling timer.
const kC416 = 'c416_realtime_bags_disputes';

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

  // C356: ONLY tables that are actually in the `supabase_realtime` publication
  // (verified via pg_publication_tables). Subscribing to an UNPUBLISHED table
  // risks a server-side binding rejection that can error the WHOLE channel — after
  // which no table delivers events and a second device never updates until reload.
  // #355 had dropped supplier_count_mode because it was NOT published; the backend
  // has since published it, so it is restored here — this makes Confirm-counting
  // stage flips (shop↔warehouse) and arrivals_confirmed changes sync cross-device.
  // All published; `orders` carries order-level status changes.
  static const tables = [
    'order_items',
    'supplier_disputes',
    'bag_item_counts',
    // Kept from #187's fulfill_suppord channel: new supplier orders must still
    // appear on the Collect list without a manual refresh.
    'supplier_orders',
    'orders',
    // C356: re-added now that it is in the supabase_realtime publication.
    'supplier_count_mode',
    // #416: the Bag tab's list/status fields (bag full/empty, arrivals_confirmed,
    // supplier_fully_locked — see fw_list_bags) live on `bags`, and per-bag/
    // per-supplier session state lives on `bag_sessions`/`bag_supplier_usage`.
    // Without these, a change to any of the three never reached the tab at all
    // (postgres_changes only fires for subscribed tables) — verified published
    // via pg_publication_tables before adding.
    'bags',
    'bag_sessions',
    'bag_supplier_usage',
    // #8/#9: continuous voice counting — live mention list (_CountedMentionsPopup)
    // refetches via get_voice_clip_mentions whenever a window's mentions land, instead
    // of only on explicit refresh calls. Verified published via pg_publication_tables
    // before adding (same care as the others in this list).
    'voice_clip_mentions',
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
  // C355: app-level session flag — once an authed admin session is active the
  // channel stays subscribed across tab switches and even when no Fulfill tab is
  // mounted, so a change on ANY device is received the moment a tab needs it.
  bool _sessionActive = false;
  int _reconnects = 0;

  bool get isUp => _up;

  /// C355: called from the auth hub (user_state) on sign-in / token-refresh /
  /// session-restore. Applies the admin JWT to the realtime socket (belt-and-
  /// suspenders on top of the SDK's own propagation, and re-applies on refresh)
  /// and brings up the app-level channel so RLS lets change events through.
  void onAuthActive(String? token) {
    _sessionActive = true;
    _applyAuth(token);
    if (_channel == null) _subscribe();
  }

  /// C355: called on sign-out — drop the socket and stop keeping it warm.
  void onAuthInactive() {
    _sessionActive = false;
    _teardown();
  }

  void _applyAuth(String? token) {
    try {
      Supabase.instance.client.realtime.setAuth(token);
      RenderLog.write('c355_rt_auth',
          'jwt=${token != null && token.isNotEmpty ? 'set' : 'null'}');
    } catch (_) {}
  }

  /// C355: force a fresh re-subscribe (drop any zombie socket left by a phone
  /// sleep / network flip) and do a FULL refetch of the visible tab.
  void forceReconnect() {
    if (!_sessionActive && _listeners.isEmpty) return;
    _reconnects++;
    RenderLog.write('c355_reconnect', 'n=$_reconnects');
    _removeChannel();
    _up = false;
    _subscribe();
    _notify({...tables});
  }

  /// Created when a Fulfill tab mounts…
  void addListener(void Function(Set<String>) l) {
    _listeners.add(l);
    if (_channel == null) _subscribe();
  }

  /// …torn down when none is mounted AND no app-level session is keeping it warm.
  void removeListener(void Function(Set<String>) l) {
    _listeners.remove(l);
    if (_listeners.isEmpty && !_sessionActive) _teardown();
  }

  void _subscribe() {
    if (_listeners.isEmpty && !_sessionActive) return;
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
          RenderLog.write('c355_rt_sub', 'tables=${tables.length}');
          RenderLog.write(kC416, 'subscribed:tables=${tables.length}');
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
    // C355: a change event ARRIVED (local OR from another device). This firing on
    // device B is the proof that cross-device delivery works — it is the exact key
    // to grep after the manual two-device test.
    RenderLog.write('c355_rt_remote', 'tbl=$table');
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
    if (_listeners.isEmpty && !_sessionActive) return;
    _retry?.cancel();
    final secs = _backoffSecs[
        _backoffIdx < _backoffSecs.length ? _backoffIdx : _backoffSecs.length - 1];
    _backoffIdx++;
    _retry = Timer(Duration(seconds: secs), () {
      if (_listeners.isEmpty && !_sessionActive) return;
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
