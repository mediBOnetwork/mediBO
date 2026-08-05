/// Sign the device out the INSTANT the backend records a WhatsApp "Log Out"
/// for this user — without waiting for app-start, foreground-resume or
/// navigation (the three moments [ForceLogoutGuard] already covers).
///
/// THE APP RENDERS, IT NEVER DECIDES. This object owns exactly one decision:
/// "an INSERT arrived on the backend-named table for this user's own filter, so
/// run the logout the backend already asked for." Everything it needs — the
/// table to watch, the filter identifying this user's row, the reason to show —
/// comes from the backend. It never builds a filter, never branches on role and
/// never invents a message.
///
/// It signs the user out on a real INSERT and on NOTHING else — not on a
/// channel error, a timeout, a close or an empty payload. When the socket
/// reconnects it re-asks must_log_out once, to catch a logout that landed while
/// the channel was down.
///
/// The channel itself is injected via [open], and the status the transport
/// reports is normalised to [ForceLogoutChannelStatus] before it reaches here,
/// so the whole policy is testable with no Supabase, no network and no widget
/// tree — the same purity as [ForceLogoutGuard].
class ForceLogoutRealtime {
  ForceLogoutRealtime({
    required ForceLogoutSubscription Function(
      String table,
      String filter,
      void Function(Map<String, dynamic> row) onInsert,
      void Function(ForceLogoutChannelStatus status) onStatus,
    ) open,
    required Future<void> Function(String reason) onForceLogout,
    required void Function() onReconnect,
  })  : _open = open,
        _onForceLogout = onForceLogout,
        _onReconnect = onReconnect;

  /// Opens the transport-level subscription. Given the backend's [table] and
  /// [filter] (verbatim), an INSERT sink and a status sink, it returns a handle
  /// this object can close. The real implementation wires a Supabase channel;
  /// tests hand in a fake they drive by hand.
  final ForceLogoutSubscription Function(
    String table,
    String filter,
    void Function(Map<String, dynamic> row) onInsert,
    void Function(ForceLogoutChannelStatus status) onStatus,
  ) _open;

  /// The reuse point: the exact handler #665 wrote — sign out on the local
  /// path, clear cart/role/profile via the signedOut cascade, drop to login and
  /// surface [reason] verbatim. Never duplicated here.
  final Future<void> Function(String reason) _onForceLogout;

  /// Re-ask must_log_out once. Called only on a reconnect, never on an error.
  final void Function() _onReconnect;

  ForceLogoutSubscription? _sub;
  String _table = '';
  String _filter = '';
  String _fallbackMessage = '';
  // A channel emits SUBSCRIBED on its first join AND again on every reconnect.
  // The first is not a reconnect; every later one is.
  bool _subscribedOnce = false;

  /// True while a channel is open. For the wiring layer and tests.
  bool get isWatching => _sub != null;

  /// Open — or re-target — the subscription for the signed-in user. [table] and
  /// [filter] come straight from must_log_out; this never constructs them.
  ///
  /// Idempotent for the same (table, filter): a repeated must_log_out answer
  /// does not churn the channel. A different filter — a new sign-in as a
  /// different user — drops the old channel first, so the channel always
  /// belongs to the current user. An empty table or filter opens nothing.
  void watch({
    required String table,
    required String filter,
    required String fallbackMessage,
  }) {
    if (table.isEmpty || filter.isEmpty) return;
    _fallbackMessage = fallbackMessage;
    if (_sub != null && table == _table && filter == _filter) return;
    stop();
    _table = table;
    _filter = filter;
    _subscribedOnce = false;
    _sub = _open(table, filter, _onInsert, _onStatus);
  }

  void _onInsert(Map<String, dynamic> row) {
    // Only a real INSERT for this user reaches here. Prefer the row's own
    // reason; fall back to the must_log_out message. Never a Dart-authored one.
    final rowReason = row['reason'];
    final reason = (rowReason is String && rowReason.isNotEmpty)
        ? rowReason
        : _fallbackMessage;
    _onForceLogout(reason);
  }

  void _onStatus(ForceLogoutChannelStatus status) {
    // RULE 6: an error, a timeout or a close NEVER signs anyone out — those are
    // indistinguishable from a healthy quiet channel, and dropping the session
    // on a network hiccup would be the app deciding on its own.
    if (status != ForceLogoutChannelStatus.subscribed) return;
    if (!_subscribedOnce) {
      _subscribedOnce = true; // the initial join, not a reconnect
      return;
    }
    // A later SUBSCRIBED means the socket dropped and came back. Anything that
    // INSERTed while we were offline was missed by the channel — re-ask once.
    _onReconnect();
  }

  /// Tear the channel down. Called on sign-out so the channel never outlives the
  /// user it belongs to.
  void stop() {
    _sub?.unsubscribe();
    _sub = null;
    _table = '';
    _filter = '';
    _subscribedOnce = false;
  }
}

/// The transport-neutral status a force-logout channel can report. The real
/// wiring maps Supabase's RealtimeSubscribeStatus onto this so the pure
/// coordinator above never sees an SDK type.
enum ForceLogoutChannelStatus { subscribed, error, closed, timedOut }

/// The one thing [ForceLogoutRealtime.open] must return: a handle that can close
/// the channel. Keeps the pure coordinator free of any Supabase type.
class ForceLogoutSubscription {
  ForceLogoutSubscription(this.unsubscribe);

  /// Closes the underlying channel. Must be safe to call once.
  final void Function() unsubscribe;
}
