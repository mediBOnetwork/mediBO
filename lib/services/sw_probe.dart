// CMD #2065 — "is a new service worker waiting?", answered on the web and
// answered honestly (never) everywhere else.
//
// Conditional export, exactly like page_reload.dart: `dart:html` lives in the
// web half ONLY, and nothing in the widget tree imports it directly. See the
// defensive-import rule in CLAUDE.md — a `dart:html` import reachable from a
// notifier is how dart2js -O4 white-screens the whole app.
export 'sw_probe_stub.dart' if (dart.library.html) 'sw_probe_web.dart';
