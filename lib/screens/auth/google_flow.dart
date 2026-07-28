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
// CHANGE #566: two in-app choosers, no browser path — the GIS One Tap sheet
// ("Sign in to medibo.in with google.com"). Everything else is gone:
//   * the FedCM chooser ("Sign in with google.com") ended in "Access blocked:
//     response_type missing" and never once succeeded
//   * the GIS button popup ("Choose an account to continue to mediBO") is the
//     FALLBACK: it is not subject to the One Tap cooldown
//   * signInWithOAuth opened a Custom Tab whose session the PWA could not read
//
// Before each prompt() the caller clears GIS's first-party g_state cookie, so a
// dismissal never accumulates into the cooldown that used to suppress the sheet.

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

/// Runs the One Tap flow. [clearGState] and [oneTap] are injected so the
/// ordering — cookie cleared BEFORE prompt() — is testable without a browser;
/// [finish] is signInWithIdToken.
///
/// Never returns a navigation of any kind — the only outcomes are the three in
/// [GoogleOutcome].
Future<GoogleOutcome> runGoogleSignIn({
  required String Function() clearGState,
  required Future<GoogleCredential> Function() oneTap,
  required Future<GoogleCredential> Function() popup,
  required Future<void> Function(String idToken, String rawNonce) finish,
  void Function(String key, String value)? log,
}) async {
  void note(String k, String v) {
    if (log != null) log(k, v);
  }

  // Cancel-proofing: kill the cooldown cookie FIRST, every single time.
  note('c566_gstate', clearGState());

  // ── 1. The One Tap sheet ─────────────────────────────────────────────────
  try {
    final cred = await oneTap();
    note('c566_path', 'onetap');
    await finish(cred.idToken, cred.rawNonce);
    note('c566_signed_in', 'onetap');
    return GoogleOutcome.signedIn;
  } on GisOneTapCancelled {
    // A deliberate close is an answer. No popup, no message, no navigation.
    note('c566_path', 'none');
    return GoogleOutcome.closed;
  } on GisOneTapSuppressed {
    // The cooldown. The popup is not subject to it — fall straight through.
  } on GisOneTapUnavailable {
    // Same treatment.
  }

  // ── 2. The GIS button popup ──────────────────────────────────────────────
  try {
    final cred = await popup();
    note('c566_path', 'popup');
    await finish(cred.idToken, cred.rawNonce);
    note('c566_signed_in', 'popup');
    return GoogleOutcome.signedIn;
  } on GisOneTapCancelled {
    note('c566_path', 'none');
    return GoogleOutcome.closed;
  } on GisOneTapSuppressed {
    note('c566_path', 'none');
    return GoogleOutcome.suppressed;
  } on GisOneTapUnavailable {
    note('c566_path', 'none');
    return GoogleOutcome.suppressed;
  }
}
