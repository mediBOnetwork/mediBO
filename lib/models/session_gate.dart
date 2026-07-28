// CHANGE #558 — the gate between an unresolved session and any screen that
// shows account data.
//
// This is where RULES 2, 4 and 6 live:
//   RULE 2  nothing renders until a session has been adopted
//   RULE 4  a session whose auth_user_id differs from the current auth user is
//           discarded and re-fetched, never rendered
//   RULE 6  exactly one place decides admin surfaces vs customer surfaces
//
// Deliberately platform-free — no dart:html, no Supabase — so it holds no
// knowledge of *how* the session is fetched and can be driven directly in a
// widget test. AuthNotifier owns one of these and feeds it my_session().

import 'package:flutter/foundation.dart';

import 'app_session.dart';

class SessionGate extends ChangeNotifier {
  SessionGate({
    required this.currentAuthUserId,
    required this.refetch,
  });

  /// The auth user id the SDK currently holds, or null when signed out.
  final String? Function() currentAuthUserId;

  /// Re-runs my_session(). Called by the mismatch guard.
  final Future<void> Function() refetch;

  AppSession? _session;
  bool _refetching = false;

  /// Counts mismatch-driven re-fetches. Asserted by the widget tests.
  @visibleForTesting
  int refetchCount = 0;

  AppSession? get session => _session;

  /// True until a session has been adopted for the current auth user.
  bool get loading => _session == null;

  /// RULE 4 — does the adopted session describe the auth user we actually have?
  bool get matchesAuthUser {
    final s = _session;
    if (s == null) return false;
    final current = currentAuthUserId();
    if (!s.signedIn) return current == null;
    return current != null && current == s.authUserId;
  }

  /// Adopts a freshly fetched session. Refuses one that already describes a
  /// different auth user than the SDK holds — that is a stale in-flight result.
  void adopt(AppSession? s) {
    if (s != null && s.signedIn) {
      final current = currentAuthUserId();
      if (current != null && current != s.authUserId) {
        _session = null;
        notifyListeners();
        return;
      }
    }
    _session = s;
    notifyListeners();
  }

  /// Drops the adopted session without touching anything else.
  void clear() {
    _session = null;
    notifyListeners();
  }

  /// RULE 4 — call before rendering any screen that shows account data. On a
  /// mismatch this discards the cached session, logs, and re-fetches; the
  /// caller keeps rendering a neutral state until [matchesAuthUser] is true.
  void ensureMatchesAuthUser() {
    if (matchesAuthUser) return;
    if (_session == null || _refetching) return;
    final cached = _session?.authUserId;
    // Console-visible if this ever happens again.
    debugPrint('[c558] session mismatch: cached=$cached '
        'current=${currentAuthUserId()} — discarding and re-fetching');
    // Dropping the session synchronously is what stops the caller rendering
    // the wrong account on THIS frame. No notifyListeners() here: this is
    // called from build(), and the re-fetch notifies when it adopts.
    _session = null;
    _refetching = true;
    refetchCount++;
    refetch().whenComplete(() {
      _refetching = false;
    });
  }

  /// RULE 6 — the single surface decision for the whole app.
  AccountSurface surfaceFor({bool actingAsCustomer = false}) {
    final s = _session;
    if (s == null) return AccountSurface.unresolved;
    return s.surface(
      matchesAuthUser: matchesAuthUser,
      actingAsCustomer: actingAsCustomer,
    );
  }
}
