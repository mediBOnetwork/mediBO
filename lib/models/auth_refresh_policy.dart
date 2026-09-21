/// CMD #2137 — when may an auth event take the whole shell down?
///
/// A phone returning from the camera or the file picker resumes the app, and
/// the Supabase client refreshes a token that went stale while it was away
/// (`tokenRefreshed`, sometimes `signedIn`). That refresh used to raise the
/// shell's "profile loading" spinner, which REPLACES the entire page tree for a
/// frame — so the Bulk Upload screen waiting on the picker was disposed and the
/// file it had just been handed went nowhere. The second pick worked only
/// because the token was fresh by then.
///
/// The spinner exists for one reason (CHANGE #308): a session resolving for a
/// NEW account must not flash the wrong surface. A refresh of the account that
/// is already on screen has nothing to hide, so it re-reads silently and the
/// tree stays mounted.
class AuthRefreshPolicy {
  const AuthRefreshPolicy._();

  /// True only when the event resolves a DIFFERENT (or not yet resolved)
  /// account than the one currently rendered.
  static bool blanksShell({
    required String eventUserId,
    required String renderedUserId,
  }) {
    if (renderedUserId.isEmpty) return true;
    return eventUserId != renderedUserId;
  }

  /// The delivery-role gate may hold the shell back only until the shell has
  /// painted once for this login. A re-probe later (resume after a failed
  /// probe) must never unmount a live page.
  static bool holdForDeliveryProbe({
    required bool resolved,
    required bool loading,
    required bool paintedForThisUser,
  }) =>
      !resolved && loading && !paintedForThisUser;
}
