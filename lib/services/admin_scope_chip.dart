// CMD #1947 — the header chip's state: ONE RPC, rendered verbatim.
//
// admin_scope_chip() returns the whole control — the chip's text ("12 Sep ·
// Raipur"), its compact form (the zone code), the sheet's headings and both
// pickers' payloads. Nothing here formats a date, shortens a zone name or
// joins two strings: if a string is on screen, the backend sent it.
//
// Writes still go through the SAME two RPCs as before (AdminDateScope.select /
// AdminZoneScope.select), so every date- and zone-scoped tab refetches exactly
// as it does today. This class simply re-reads the chip after either scope
// moves.
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_date_scope.dart';
import 'admin_zone_scope.dart';

class AdminScopeChip {
  AdminScopeChip._();
  static final AdminScopeChip instance = AdminScopeChip._();

  Map<String, dynamic> _payload = const {};
  bool _loaded = false;
  bool _inFlight = false;
  bool _wired = false;

  /// The last admin_scope_chip() payload, verbatim. Empty before first load.
  Map<String, dynamic> get payload => _payload;

  bool get isLoaded => _loaded;

  /// False until the backend says this account gets a chip at all.
  bool get show => _payload['show'] == true;

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

  /// Idempotent — safe from every header's initState.
  Future<void> ensureLoaded() async {
    _wire();
    if (_loaded || _inFlight) return;
    await refresh();
  }

  /// Re-read the chip. Called on load, and again whenever the date or zone
  /// scope reports a change (the scopes are the writers; this is a reader).
  Future<void> refresh() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final res =
          await Supabase.instance.client.rpc('admin_scope_chip');
      if (res is Map) {
        _payload = Map<String, dynamic>.from(res);
        _loaded = true;
        _notify();
      }
    } catch (_) {
      // A failed read leaves the last good payload on screen; the header must
      // never break because one RPC blipped.
    } finally {
      _inFlight = false;
    }
  }

  void _wire() {
    if (_wired) return;
    _wired = true;
    AdminDateScope.instance.addListener(_onScopeMoved);
    AdminZoneScope.instance.addListener(_onScopeMoved);
  }

  void _onScopeMoved() {
    refresh();
  }
}
