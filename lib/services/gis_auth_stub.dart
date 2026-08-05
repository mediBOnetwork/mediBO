// Native (non-web) fallback for the Google Identity Services JS bridge.
// Google login is simply inert on native: detection booleans are false, the
// diagnostic strings are empty, and every action is a no-op. The credential
// functions signal "suppressed" so the platform-free escalation in
// google_flow.dart treats Google as unavailable and never navigates.
//
// Public API matches gis_auth_web.dart exactly so callers type-check
// identically on Android.

import '../screens/auth/google_flow.dart';

/// Native default: not a mobile web browser.
bool isMobileWeb() => false;

/// Native default: pointer type is unknown here, report not coarse.
bool isCoarsePointer() => false;

/// Native default: no browser origin.
String currentOrigin() => '';

/// Native default: no GIS error recorded.
String lastGisError() => '';

/// Native default: not an installed PWA.
bool isStandalonePwa() => false;

/// Native no-op: nothing to pre-warm; never becomes ready.
Future<bool> gisPrewarm() async => false;

/// Native inert: no Google sheet exists, so this is always suppressed.
Future<({String idToken, String rawNonce})> gisPromptOneTap() async {
  throw const GisOneTapSuppressed();
}

/// Native inert: no Google popup exists, so this is always suppressed.
Future<({String idToken, String rawNonce})> gisPopupSignIn({
  required String title,
  required String subtitle,
  required String cancelLabel,
}) async {
  throw const GisOneTapSuppressed();
}

/// Native no-op: no GIS auto-select state to disable.
bool gisDisableAutoSelect() => false;
