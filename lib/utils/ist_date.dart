// CHANGE #444 — shared IST (Asia/Kolkata, UTC+5:30) date helpers for the
// date-scope chip feature. Hand-rolled UTC day-boundary math is error-prone
// (it silently flips the day near midnight); these helpers centralize the
// one calculation the client is allowed to do (today's IST calendar date)
// and leave actual day-range filtering to the ist_day_bounds RPC.

DateTime nowIst() =>
    DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));

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
