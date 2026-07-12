// CHANGE #444 — ONE shared date + includeOlder state for the whole Fulfill
// screen (Supplier Shop / Warehouse / Bag / Pack / Disputes), so switching
// tabs keeps the chosen date and pill state. Mirrors the existing
// FulfillRealtime singleton-listener pattern (lib/services/fulfill_realtime.dart)
// so every tab can listen independently instead of the parent threading date
// props through 5 widget constructors.
import '../utils/ist_date.dart';

class FulfillDateScope {
  FulfillDateScope._() {
    _today = todayIst();
    date = _today;
  }
  static final FulfillDateScope instance = FulfillDateScope._();

  late DateTime _today;
  late DateTime date;
  bool includeOlder = false;

  final Set<void Function()> _listeners = {};
  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _notify() {
    for (final l in {..._listeners}) {
      try { l(); } catch (_) {}
    }
  }

  bool get isToday => isSameDay(date, _today);

  void setDate(DateTime d) {
    final nd = DateTime(d.year, d.month, d.day);
    if (isSameDay(nd, date) && !includeOlder) return;
    date = nd;
    includeOlder = false;
    _notify();
  }

  void toggleIncludeOlder() {
    includeOlder = !includeOlder;
    _notify();
  }

  /// B5 — call on app resume and on the refresh button. If the user was
  /// viewing "today" and the real day has rolled over since, advance the
  /// selection to the new today and refetch; otherwise a no-op.
  void recomputeToday() {
    final wasToday = isToday;
    final t = todayIst();
    final rolled = !isSameDay(t, _today);
    _today = t;
    if (wasToday && rolled) {
      date = t;
      includeOlder = false;
      _notify();
    }
  }
}
