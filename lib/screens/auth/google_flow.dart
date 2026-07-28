// CHANGE #564 — the Google sign-in escalation, with NO browser path.
//
// This file is deliberately platform-free: it imports nothing web-only, so the
// escalation can be unit-tested on the VM with the two attempts injected. The
// real attempts live in services/gis_auth.dart (dart:js_interop).
//
// The rule this file exists to enforce: NOTHING here can navigate. There is no
// signInWithOAuth, no launchUrl, no window.open, no anchor. The account sheet is
// drawn by the browser (FedCM) or by Google (One Tap), never by us, and the
// full-page accounts.google.com chooser must never appear.
//
// Order (CHANGE #564):
//   1. GIS One Tap prompt(). Proven: four grant_type=id_token logins.
//   2. The GIS button popup, when One Tap is suppressed by Google's cooldown.
//      Proven in #556 (c556_path=sheet_button -> c556_session=established) and
//      NOT subject to that cooldown, so this branch always has a chooser.
//   3. Nothing. The caller shows an inline message, and stays put.
//
// FedCM is gone: it failed on every single attempt across #557, #558, #560,
// #561 and #564 — the last one rejected:NetworkError on https://www.medibo.in
// with both origins authorized.

/// One Tap or FedCM could not be shown at all (library missing, unclassifiable
/// moment).
class GisOneTapUnavailable implements Exception {
  const GisOneTapUnavailable();
}

/// Google refused to display the sheet — cooldown after an earlier dismissal, no
/// Google session on the device, or a FedCM refusal. Never a reason to navigate.
class GisOneTapSuppressed implements Exception {
  const GisOneTapSuppressed();
}

/// The user deliberately closed the sheet. That is an answer, not a failure:
/// stay on the login screen and re-enable the button.
class GisOneTapCancelled implements Exception {
  const GisOneTapCancelled();
}

/// What a Google tap actually did.
enum GoogleOutcome {
  /// Signed in — the caller resolves home.
  signedIn,

  /// The user closed the sheet. Stay put, re-enable the button, show nothing.
  closed,

  /// Neither sheet could be shown. Show the backend's inline note, if it has
  /// one. Still no navigation.
  suppressed,
}

/// A credential from either sheet: the id_token plus the RAW nonce.
///
/// Google receives the HASHED nonce (embedded in the JWT's nonce claim) and
/// Supabase receives the RAW one, which it re-hashes to verify. This mapping is
/// verified and must not change.
typedef GoogleCredential = ({String idToken, String rawNonce});

/// Runs the escalation. [oneTap] and [popup] are injected so this is testable
/// without a browser; [finish] is signInWithIdToken.
///
/// Never returns a navigation of any kind — the only outcomes are the three in
/// [GoogleOutcome].
Future<GoogleOutcome> runGoogleSignIn({
  required Future<GoogleCredential> Function() oneTap,
  required Future<GoogleCredential> Function() popup,
  required Future<void> Function(String idToken, String rawNonce) finish,
  void Function(String key, String value)? log,
}) async {
  void note(String k, String v) {
    if (log != null) log(k, v);
  }

  // ── 1. One Tap: the primary path ─────────────────────────────────────────
  try {
    final cred = await oneTap();
    note('c564_path', 'onetap');
    await finish(cred.idToken, cred.rawNonce);
    note('c564_signed_in', 'onetap');
    return GoogleOutcome.signedIn;
  } on GisOneTapCancelled {
    // A deliberate close is an answer. No message, no popup, no navigation.
    note('c564_path', 'none');
    return GoogleOutcome.closed;
  } on GisOneTapSuppressed {
    // The cooldown. Fall straight through to the popup, which the cooldown
    // does not apply to.
  } on GisOneTapUnavailable {
    // Same treatment: the popup is the branch that always has a chooser.
  }

  // ── 2. The GIS button popup ──────────────────────────────────────────────
  try {
    final cred = await popup();
    note('c564_path', 'popup');
    await finish(cred.idToken, cred.rawNonce);
    note('c564_signed_in', 'popup');
    return GoogleOutcome.signedIn;
  } on GisOneTapCancelled {
    note('c564_path', 'none');
    return GoogleOutcome.closed;
  } on GisOneTapSuppressed {
    note('c564_path', 'none');
    return GoogleOutcome.suppressed;
  } on GisOneTapUnavailable {
    note('c564_path', 'none');
    return GoogleOutcome.suppressed;
  }
}
