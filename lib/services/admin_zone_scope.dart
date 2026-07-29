// CHANGE #609 — the admin zone filter, server-side like the date filter.
//
// The selected zone is NOT client state. It lives in `admin_zone_scope` (one
// row per super admin) and is read/written through two RPCs:
//
//   zone_picker()                        -> the whole control, render-ready
//   admin_set_zone_scope(p_zone_id)      -> sets it; null means "All zones"
//
// Because the zone lives server-side, admin_customer_orders and
// admin_supplier_orders apply it themselves. Callers send NO zone argument —
// their signatures are unchanged, and adding one would give the screen a second
// opinion about which zone it is looking at.
//
// Everything this class exposes is the backend's own string or flag. It decides
// nothing: not who may change the zone (can_change), not what the options are
// called (options[].label — including the "All zones" entry, whose label is
// config, not a Dart literal), not which one is current (options[].selected).
//
// Mirrors AdminDateScope deliberately, so the two filters behave identically.
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

class AdminZoneScope {
  AdminZoneScope._();
  static final AdminZoneScope instance = AdminZoneScope._();

  // ── backend-owned state (verbatim, never synthesised) ─────────────────────
  bool _show = false;
  bool _canChange = false;
  String _title = '';
  int? _selectedZoneId;
  String _selectedLabel = '';
  List<Map<String, dynamic>> _options = const [];
  String _empty = '';

  bool _loaded = false;
  bool _inFlight = false;

  /// Whether this account gets a zone control at all. false -> render NOTHING.
  bool get show => _show;

  /// Whether this account may change the zone. false -> static text, no tap
  /// target. Never inferred from a role on this side.
  bool get canChange => _canChange;

  /// Caption above/beside the control ("Zone" / "Your zone").
  String get title => _title;

  /// The active zone's id — null is a real value meaning "All zones", not a
  /// missing one.
  int? get selectedZoneId => _selectedZoneId;

  /// Display text for the current selection ("Raipur Zone" / "All zones").
  String get selectedLabel => _selectedLabel;

  /// [{zone_id, code, label, selected}] in the backend's order. Empty for an
  /// admin/employee, who cannot change zone.
  List<Map<String, dynamic>> get options => _options;

  /// Ready-to-render "no zones configured" copy, '' when there is nothing to
  /// say.
  String get empty => _empty;

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

  /// Idempotent — safe from every screen's initState; only the first call hits
  /// the network.
  Future<void> ensureLoaded() async {
    if (_loaded || _inFlight) return;
    await refresh();
  }

  Future<void> refresh() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final res = await Supabase.instance.client.rpc('zone_picker');
      _apply(res);
    } catch (_) {
      // Leave the previous state; screens keep rendering what they had.
    } finally {
      _inFlight = false;
    }
  }

  /// Select [zoneId] — passed to the RPC VERBATIM, including null for
  /// "All zones". Never coerced to 0, -1 or ''. null is null.
  ///
  /// Returns true when the backend confirmed status:'ok', so the caller knows
  /// to refetch its own tab. On any error the previous zone stays selected and
  /// nothing is mutated locally.
  Future<bool> select(int? zoneId) async {
    try {
      final res = await Supabase.instance.client
          .rpc('admin_set_zone_scope', params: {'p_zone_id': zoneId});
      final m = res is Map ? Map<String, dynamic>.from(res) : null;
      if (m == null || m['status'] != 'ok') {
        RenderLog.write('c609_zone_set_err', (m?['error'] ?? 'bad_response').toString());
        return false;
      }
      RenderLog.write('c609_zone_set',
          'zone=${zoneId?.toString() ?? 'null'};label=${m['zone_label'] ?? ''}');
      // Re-read the picker so selected flags and selected_label come from the
      // backend rather than being patched in here. _apply() fires the listeners
      // when the zone actually moved — no second _notify() here, or every tab
      // would refetch twice for one change.
      await refresh();
      return true;
    } catch (e) {
      RenderLog.write('c609_zone_set_err', e.toString());
      return false;
    }
  }

  void _apply(dynamic res) {
    if (res is! Map) return;
    final m = Map<String, dynamic>.from(res);
    final prevZone = _selectedZoneId;
    final prevShow = _show;

    _show = m['show'] == true;
    _canChange = m['can_change'] == true;
    _title = m['title']?.toString() ?? '';
    _selectedZoneId = (m['selected_zone_id'] as num?)?.toInt();
    _selectedLabel = m['selected_label']?.toString() ?? '';
    _empty = m['empty']?.toString() ?? '';
    _options = m['options'] is List
        ? (m['options'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : const <Map<String, dynamic>>[];

    final first = !_loaded;
    _loaded = true;
    if (first) {
      RenderLog.write('c609_zone_scope_loaded',
          'show=$_show;can_change=$_canChange;opts=${_options.length};zone=${_selectedZoneId?.toString() ?? 'null'}');
    }
    if (first || prevZone != _selectedZoneId || prevShow != _show) _notify();
  }
}
