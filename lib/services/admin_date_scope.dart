// CHANGE #545 — ONE admin date filter for the whole admin interface.
//
// Replaces FulfillDateScope (deleted). The selected date is no longer client
// state: it lives server-side in `admin_date_scope` (one row per admin) and is
// read/written through two RPCs:
//
//   admin_date_scope_state()          -> the current state jsonb
//   admin_set_date_scope(p_date date) -> sets it, returns the new state jsonb
//                                        (pass null to snap back to Today)
//
// Because the date is server-side, the twelve date-scoped read RPCs
// (admin_customer_orders, admin_supplier_orders, inquiry_day, fw_list_arrivals,
// fw_get_state, fw_list_bags, pack_list_orders, fw_pack_orders, fw_get_disputes,
// map_supplier_groups, fw_shop_suppliers, fw_date_label) all DEFAULT p_date to
// admin_active_date(). Callers must therefore OMIT p_date entirely — sending an
// explicit null means "all dates" to six of them.
//
// Every display string here is the backend's own (label / long_label /
// empty_label / options[].label). Nothing in this file formats a date.
//
// Realtime: `admin_date_scope` is in the supabase_realtime publication with
// REPLICA IDENTITY FULL, so a change made on one device reaches the others.
// Any event re-reads the state and, if the date actually moved, notifies every
// listener — each screen refetches only its own visible data.
import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

class AdminDateScope {
  AdminDateScope._();
  static final AdminDateScope instance = AdminDateScope._();

  // ── backend-owned state (verbatim, never synthesised) ─────────────────────
  String? _date;
  String? _today;
  String? _label;
  String? _longLabel;
  String? _emptyLabel;
  bool _isToday = true;
  bool _isFuture = false;
  List<Map<String, dynamic>> _options = const [];

  bool _loaded = false;
  bool _inFlight = false;

  /// 'YYYY-MM-DD' as the backend reported it, or null before the first load.
  /// This is the ONLY value client code may forward to an RPC that does not
  /// default its own p_date (ist_day_bounds, fw_supplier_modes and the voice /
  /// bag WRITE RPCs, which must persist against the date on screen).
  String? get dateYmd => _date;

  /// The backend's own today, for de-duplicating a "Today" option.
  String? get todayYmd => _today;

  bool get isToday => _isToday;
  bool get isFuture => _isFuture;

  /// Short form ("Today" / "Yesterday" / "26/07/2026").
  String get label => _label ?? '';

  /// Picker button text ("Today · 27/07/2026").
  String get longLabel => _longLabel ?? '';

  /// Ready-to-render empty state ("No orders placed on 27/07/2026.").
  String get emptyLabel => _emptyLabel ?? '';

  /// [{date, label, is_selected}] — distinct real order dates, newest first.
  List<Map<String, dynamic>> get options => _options;

  /// False until admin_date_scope_state() has landed once.
  bool get isLoaded => _loaded;

  // ── listeners ─────────────────────────────────────────────────────────────
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

  // ── loading ───────────────────────────────────────────────────────────────

  /// Idempotent — safe to call from every screen's initState. Only the first
  /// call hits the network.
  Future<void> ensureLoaded() async {
    if (_loaded || _inFlight) return;
    await refresh();
  }

  /// Re-read the server's state. Called on screen focus/resume (so a
  /// backgrounded tab is never stale) and on every realtime event. Notifies
  /// listeners only when the effective date actually moved — a repaint-only
  /// change (label refresh after midnight rollover) still notifies, because the
  /// date string changes with it.
  Future<void> refresh() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final res = await Supabase.instance.client.rpc('admin_date_scope_state');
      _apply(res, notifyAlways: false);
    } catch (_) {
      // Leave the previous state in place; screens keep rendering what they had.
    } finally {
      _inFlight = false;
    }
  }

  /// Select [date] ('YYYY-MM-DD'), or null to snap back to Today. The RPC
  /// returns the new state, so no follow-up read is needed.
  Future<void> select(String? date) async {
    try {
      final res = await Supabase.instance.client
          .rpc('admin_set_date_scope', params: {'p_date': date});
      _apply(res, notifyAlways: true);
      RenderLog.write('c545_date_set', 'date=${_date ?? ''};label=$label');
    } catch (_) {
      // A failed set leaves the previous date selected — nothing to roll back.
    }
  }

  void _apply(dynamic res, {required bool notifyAlways}) {
    if (res is! Map) return;
    final m = Map<String, dynamic>.from(res);
    final prevDate = _date;

    _date = m['date']?.toString();
    _today = m['today']?.toString();
    _label = m['label']?.toString();
    _longLabel = m['long_label']?.toString();
    _emptyLabel = m['empty_label']?.toString();
    _isToday = m['is_today'] == true;
    _isFuture = m['is_future'] == true;

    final raw = m['options'];
    _options = raw is List
        ? raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : const <Map<String, dynamic>>[];

    final first = !_loaded;
    _loaded = true;
    if (first) {
      RenderLog.write('c545_date_scope_loaded',
          'date=${_date ?? ''};options=${_options.length}');
    }
    if (notifyAlways || first || prevDate != _date) _notify();
  }

  // ── realtime ──────────────────────────────────────────────────────────────
  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _retry;
  int _backoffIdx = 0;
  static const _backoffSecs = [1, 2, 5, 10, 30];
  bool _started = false;

  /// Subscribe ONCE, app-wide (called from AdminShell.initState). Also does the
  /// initial state load, so every admin screen can just listen.
  void start() {
    if (_started) return;
    _started = true;
    ensureLoaded();
    _subscribe();
  }

  void _subscribe() {
    try {
      final ch = Supabase.instance.client
          .channel('admin_date_scope_c545')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'admin_date_scope',
            callback: (_) => _onEvent(),
          );
      ch.subscribe((status, [error]) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          _backoffIdx = 0;
          RenderLog.write('c545_date_rt', 's=up');
          // Events may have been missed while the socket was down.
          refresh();
        } else if (status == RealtimeSubscribeStatus.closed ||
            status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          RenderLog.write('c545_date_rt', 's=down');
          _scheduleRetry();
        }
      });
      _channel = ch;
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _onEvent() {
    RenderLog.write('c545_date_rt_remote', 'tbl=admin_date_scope');
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), refresh);
  }

  void _scheduleRetry() {
    _retry?.cancel();
    final secs = _backoffSecs[_backoffIdx.clamp(0, _backoffSecs.length - 1)];
    if (_backoffIdx < _backoffSecs.length - 1) _backoffIdx++;
    _retry = Timer(Duration(seconds: secs), () {
      _removeChannel();
      _subscribe();
    });
  }

  void _removeChannel() {
    final ch = _channel;
    _channel = null;
    if (ch == null) return;
    try {
      Supabase.instance.client.removeChannel(ch);
    } catch (_) {}
  }
}
