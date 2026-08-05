import 'dart:async';

/// Force the device to sign out when a WhatsApp "Log Out" was requested.
///
/// THE PROBLEM this exists for: tapping "Log Out" on the WhatsApp login alert
/// revokes every session server-side, but the access token the device already
/// holds stays valid until it expires — up to an hour. The database cannot
/// cancel a token that was already issued; the app has to be told. The backend
/// answers that question with `must_log_out()`:
///
///   supabase.rpc('must_log_out') -> { must_log_out: bool, message: string|null }
///
/// This guard is the single place that asks and acts on the answer. It is a
/// pure, self-contained decision object — the RPC, the clock and the sign-out
/// action are all injected — so the whole policy is testable with no Supabase,
/// no network and no widget tree.
///
/// The app RENDERS, it never DECIDES: this class does not invent the reason
/// string, does not branch on role, and never signs anyone out on an error, a
/// null answer or a false answer. The one decision it owns — "the backend said
/// must_log_out, so run the logout" — is exactly what the backend asked for.
class ForceLogoutGuard {
  ForceLogoutGuard({
    required Future<Map<String, dynamic>?> Function() rpc,
    required Future<void> Function(String message) onForceLogout,
    int Function()? nowMs,
    int debounceMs = 20000,
  })  : _rpc = rpc,
        _onForceLogout = onForceLogout,
        _nowMs = nowMs ?? _wallClock,
        _debounceMs = debounceMs;

  /// Asks the backend. Returns the parsed payload, or null when there is no
  /// usable answer.
  final Future<Map<String, dynamic>?> Function() _rpc;

  /// Runs the actual sign-out: revoke the local credential, clear cached
  /// account state and route to login, showing [message] verbatim. Called at
  /// most once per positive answer.
  final Future<void> Function(String message) _onForceLogout;

  /// Injectable clock (milliseconds since epoch). Real code uses the wall
  /// clock; tests drive it by hand.
  final int Function() _nowMs;

  /// Debounce window: at most one RPC per this many milliseconds.
  final int _debounceMs;

  int _lastCheckMs = 0;
  bool _inFlight = false;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Ask the backend whether this device must sign out, and act on a positive
  /// answer. Debounced to at most once per [_debounceMs]; a call inside the
  /// window is a no-op that never touches the RPC.
  ///
  /// Never throws and never signs anyone out on an error, a null response or a
  /// false answer — those are indistinguishable from "everything is fine", and
  /// signing out on a network hiccup would be the app deciding on its own.
  Future<void> check() async {
    // A single call already runs — do not stack a second RPC or a second
    // logout on top of it.
    if (_inFlight) return;

    final now = _nowMs();
    // _lastCheckMs == 0 means "never checked", which must always run.
    if (_lastCheckMs != 0 && now - _lastCheckMs < _debounceMs) return;

    // Stamp BEFORE the await so two calls in the same tick collapse to one RPC,
    // and a failing backend is not hammered every trigger.
    _lastCheckMs = now;
    _inFlight = true;
    try {
      final res = await _rpc();
      if (res == null) return;                 // no answer -> do nothing
      if (res['must_log_out'] != true) return; // not true  -> do nothing
      // message is string|null in the payload; never invent one in Dart.
      final message = (res['message'] as String?) ?? '';
      await _onForceLogout(message);
    } catch (_) {
      // Error / timeout -> do nothing at all. Leave the credential alone.
    } finally {
      _inFlight = false;
    }
  }
}
