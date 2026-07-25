// CHANGE #531 — FULFILL360 pass 3: ONE cache for the backend-owned lookup
// payloads that the fulfillment tab needs in SYNCHRONOUS render paths.
//
// The problem this solves: fw_issue_options(), fw_error_messages() and
// fw_date_label() all return final, ready-to-render strings and colours, but
// they are async while build() is sync. Previously that mismatch was "solved"
// by hardcoding the strings in Dart — ~20 error-code->English maps, an issue
// options table, and dmy() date formatting. This cache removes the excuse.
//
// Fetch policy (deliberate — do NOT fetch per render):
//   • fw_issue_options() + fw_error_messages() : ONCE per session. Static.
//   • fw_date_label(p_date)                    : once per selected date, driven
//     by FulfillDateScope's existing listener.
//
// While a payload has not landed, the getters return null / empty. Callers MUST
// render their existing empty/loading state — there is no hardcoded fallback
// copy anywhere in this file by design.

import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/fulfill_date_scope.dart';
import '../utils/ist_date.dart';
import '../utils/render_log.dart';

class FulfillLookups {
  FulfillLookups._() {
    // Refetch the date label whenever the shared Fulfill date changes.
    FulfillDateScope.instance.addListener(_onDateChanged);
  }
  static final FulfillLookups instance = FulfillLookups._();

  // ── backend payloads (verbatim, never synthesised) ────────────────────────
  Map<String, String> _messages = const {};
  List<Map<String, dynamic>> _issueOptions = const [];

  /// fw_date_label payloads keyed by 'YYYY-MM-DD'. Keyed (rather than a single
  /// slot) because DateScopeChip is also used by admin_customer_screen and
  /// admin_supplier_screen, whose own date is NOT synced to FulfillDateScope —
  /// a single-slot cache made those chips render a placeholder forever.
  final Map<String, Map<String, dynamic>> _dateLabels = {};
  final Set<String> _dateInFlight = {};

  bool _staticLoaded = false;
  bool _staticLoading = false;

  final Set<void Function()> _listeners = {};
  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _notify() {
    for (final l in {..._listeners}) {
      try { l(); } catch (_) {}
    }
  }

  // ── readiness (callers gate their loading state on these) ─────────────────

  /// True once fw_error_messages() + fw_issue_options() have landed.
  bool get ready => _staticLoaded;

  /// True once fw_date_label() for the CURRENTLY selected Fulfill date landed.
  bool get dateReady => _dateLabels.containsKey(ymd(FulfillDateScope.instance.date));

  /// Payload for ANY date. Returns null and kicks off a fetch if not cached, so
  /// a caller with its own date (customer/supplier screens) still resolves.
  Map<String, dynamic>? labelsFor(DateTime d) {
    final key = ymd(d);
    final hit = _dateLabels[key];
    if (hit == null) _loadDateFor(key);
    return hit;
  }

  String? dateChipLabelFor(DateTime d) => labelsFor(d)?['chip_label']?.toString();
  String? dateRelativeFor(DateTime d)  => labelsFor(d)?['relative']?.toString();
  String? dateLabelFor(DateTime d)     => labelsFor(d)?['label']?.toString();

  // ── error messages ────────────────────────────────────────────────────────

  /// Backend-owned message for a write-RPC error `code`. Falls back to the
  /// backend's own `default` entry — never to a client string. Returns null
  /// while the map has not loaded, so callers can show a neutral state.
  String? message(String? code) {
    if (!_staticLoaded) return null;
    if (code != null && _messages.containsKey(code)) return _messages[code];
    return _messages['default'];
  }

  // ── issue options (report-issue form) ─────────────────────────────────────

  /// options[] as returned: {key,label,help,needs_qty,needs_name,needs_proof,colors}
  List<Map<String, dynamic>> get issueOptions => _issueOptions;

  Map<String, dynamic>? issueOption(String? key) {
    if (key == null) return null;
    for (final o in _issueOptions) {
      if (o['key']?.toString() == key) return o;
    }
    return null;
  }

  bool needsQty(String? key)   => issueOption(key)?['needs_qty']   == true;
  bool needsName(String? key)  => issueOption(key)?['needs_name']  == true;
  bool needsProof(String? key) => issueOption(key)?['needs_proof'] == true;

  /// The option's own label, verbatim. Null while unloaded / unknown key.
  String? issueLabel(String? key) => issueOption(key)?['label']?.toString();

  // ── date label ────────────────────────────────────────────────────────────
  // {date,label,short,long,weekday,is_today,relative}

  Map<String, dynamic>? get _scopeLabels =>
      _dateLabels[ymd(FulfillDateScope.instance.date)];

  String? get dateLabel    => _scopeLabels?['label']?.toString();
  String? get dateShort    => _scopeLabels?['short']?.toString();
  String? get dateLong     => _scopeLabels?['long']?.toString();
  String? get dateWeekday  => _scopeLabels?['weekday']?.toString();
  String? get dateRelative => _scopeLabels?['relative']?.toString();
  bool?   get dateIsToday  => _scopeLabels?['is_today'] as bool?;

  /// Ready-to-render date chip text ("Today · 26/07/2026" or "20/07/2026").
  String? get dateChipLabel => _scopeLabels?['chip_label']?.toString();

  /// Ready-to-render empty state ("No orders placed on 26/07/2026.").
  String? get emptyOrdersLabel => _scopeLabels?['empty_orders_label']?.toString();

  // ── loading ───────────────────────────────────────────────────────────────

  /// Call from the fulfillment tab's initState. Idempotent and safe to call
  /// from every tab — the static half runs at most once per session.
  Future<void> ensureLoaded() async {
    await Future.wait<void>([_loadStatic(), _loadDate()]);
  }

  Future<void> _loadStatic() async {
    if (_staticLoaded || _staticLoading) return;
    _staticLoading = true;
    try {
      final c = Supabase.instance.client;
      // Explicitly typed so dart2js cannot infer a mixed Future<List>/Future<dynamic>.
      final res = await Future.wait<dynamic>([
        c.rpc('fw_error_messages'),
        c.rpc('fw_issue_options'),
      ]);

      final errRes = res[0];
      if (errRes is Map) {
        final raw = errRes['messages'];
        if (raw is Map) {
          _messages = raw.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
        }
      }

      final optRes = res[1];
      if (optRes is Map) {
        final raw = optRes['options'];
        if (raw is List) {
          _issueOptions = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }

      _staticLoaded = _messages.isNotEmpty || _issueOptions.isNotEmpty;
      RenderLog.write('c531_lookups',
          'messages=${_messages.length};issue_options=${_issueOptions.length}');
      _notify();
    } catch (_) {
      // Leave unloaded — callers render their loading/empty state rather than
      // any hardcoded copy. A later ensureLoaded() will retry.
    } finally {
      _staticLoading = false;
    }
  }

  Future<void> _loadDate() => _loadDateFor(ymd(FulfillDateScope.instance.date));

  Future<void> _loadDateFor(String key) async {
    if (_dateLabels.containsKey(key) || _dateInFlight.contains(key)) return;
    _dateInFlight.add(key);
    try {
      final res = await Supabase.instance.client
          .rpc('fw_date_label', params: {'p_date': key});
      if (res is Map) {
        _dateLabels[key] = Map<String, dynamic>.from(res);
        RenderLog.write('c531_date_label',
            'date=$key;label=${_dateLabels[key]?['label'] ?? ''}');
        _notify();
      }
    } catch (_) {
      // Same policy: no client-side date formatting fallback.
    } finally {
      _dateInFlight.remove(key);
    }
  }

  // Labels are immutable per date, so a date change only needs to ensure the
  // new date is cached — nothing to invalidate.
  void _onDateChanged() {
    _notify();
    _loadDate();
  }
}
