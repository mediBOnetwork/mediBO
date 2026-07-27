// CHANGE #444 — shared IST (Asia/Kolkata, UTC+5:30) date helpers for the
// date-scope chip feature. Hand-rolled UTC day-boundary math is error-prone
// (it silently flips the day near midnight); these helpers centralize the
// one calculation the client is allowed to do (today's IST calendar date)
// and leave actual day-range filtering to the ist_day_bounds RPC.
//
// CHANGE #374 — extended into the app-wide display formatter. Every
// timestamp read from the DB is UTC; these helpers are the ONLY place that
// converts it for display, always via a fixed +05:30 offset (never
// toLocal(), which depends on the device's timezone).

const _istOffset = Duration(hours: 5, minutes: 30);

DateTime nowIst() => DateTime.now().toUtc().add(_istOffset);

DateTime todayIst() {
  final n = nowIst();
  return DateTime(n.year, n.month, n.day);
}

// CHANGE #545 — isSameDay() and ymd() are DELETED, both now callerless.
//   • isSameDay's only callers were the per-tab date chips asking "is the
//     selected date today?" — a question the backend answers now
//     (admin_date_scope_state().is_today).
//   • ymd() built the 'YYYY-MM-DD' string for p_date. The date-scoped read RPCs
//     no longer take one, and the few RPCs that still do (ist_day_bounds,
//     fw_supplier_modes, the bag/voice WRITE RPCs) are handed
//     AdminDateScope.instance.dateYmd — already a backend string, never derived
//     from a client DateTime.

/// 'DD/MM/YYYY' — for formatting a timestamp READ from a row (e.g. a supplier
/// lead's created_at). Never used to build or label the admin date scope.
String dmy(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/'
    '${d.year}';

/// Parses a DB timestamp string as UTC. Postgres/Supabase timestamps
/// normally carry a 'Z' or offset; if one is somehow missing, append 'Z'
/// so Dart never silently treats it as device-local time.
DateTime parseDbUtc(String raw) {
  final hasZone = raw.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(raw);
  return DateTime.parse(hasZone ? raw : '${raw}Z').toUtc();
}

/// Converts any DateTime (UTC-tagged or not — always treated as UTC, per
/// [parseDbUtc]) into IST wall-clock time. Use on values already parsed
/// elsewhere via [parseDbUtc] or `DateTime.parse` on a DB column.
DateTime toIst(DateTime utc) => utc.toUtc().add(_istOffset);

/// Parses a raw DB timestamp string straight into IST wall-clock time.
/// This is the drop-in replacement for `DateTime.parse(raw).toLocal()`.
DateTime istFromDb(String raw) => parseDbUtc(raw).add(_istOffset);

/// Same as [istFromDb] but null-safe, for `DateTime.tryParse(x)?.toLocal()`
/// call sites.
DateTime? tryIstFromDb(String? raw) {
  if (raw == null) return null;
  try {
    return istFromDb(raw);
  } catch (_) {
    return null;
  }
}

