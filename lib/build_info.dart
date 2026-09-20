import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show appFlavor;

// CHANGE #657 — the identity of the JAVASCRIPT THAT IS RUNNING.
//
// Everything else that answers "which build is this?" reads the DOM: the
// `<meta name="build-commit">` tag and index.html's `_builtCommit` are both
// stamped by deploy.sh into index.html. That is fine for the common case (the
// _headers rule serves index.html `no-store`, so it is always fresh) but it can
// never detect the one failure the bug report is about: a browser running an
// OLD bundle while fetching a NEW /version.json. If index.html is stale, so is
// every hash in it, and the page compares stale against stale and stays quiet.
//
// This constant is baked into main.dart.js by dart2js at BUILD time — it cannot
// drift from the code around it, and it cannot be re-read from a cached
// document. The change number is used rather than the commit because deploy.sh
// amends the git commit AFTER building, so the commit is not knowable while the
// bundle is being compiled; the change number is (it is the same value that
// goes into version.json's `change` and into the Sentry release).
//
// Empty in `flutter run`, in tests and in any build that did not pass the
// define. Every consumer must treat empty as "no build identity" and fall back,
// never as a mismatch.
const String kBuiltChange = String.fromEnvironment('MEDIBO_CHANGE');

// CMD #2100 — WHICH APP IS THIS. Two Android flavors share this codebase:
// 'customer' (in.medibo.app, today's app) and 'partner' (in.medibo.partner,
// mediBO Partner). `--flavor <name>` at build time sets Flutter's own
// [appFlavor]; the web build has none and is 'web'. It is sent on EVERY
// request as the `x-medibo-flavor` header (attached once, in main.dart) and
// nothing in Dart branches on it — the backend reads it (app_flavor()) and
// answers per app: the role home, the update bar's release, the FCM app id.
const String kFlavorHeader = 'x-medibo-flavor';

/// The partner app's own versionCode. MUST stay in lockstep with the partner
/// flavor in android/app/build.gradle.kts — scripts/publish_play.sh
/// --flavor partner bumps both, exactly as kAndroidVersionCode is bumped for
/// the customer app.
const int kPartnerAndroidVersionCode = 3;

/// 'customer' | 'partner' | 'web'. Never null, never empty.
String get appFlavorName {
  final f = appFlavor;
  if (f != null && f.isNotEmpty) return f;
  return kIsWeb ? 'web' : 'customer';
}

bool get isPartnerFlavor => appFlavorName == 'partner';

/// True when this bundle carries a real build identity (a release build made by
/// deploy.sh), so a version comparison against it means something.
bool get hasBuiltChange => kBuiltChange.isNotEmpty;
