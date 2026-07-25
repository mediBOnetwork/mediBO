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

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 'YYYY-MM-DD' — for RPC `p_date` params.
String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 'DD/MM/YYYY' — for chip labels.
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

