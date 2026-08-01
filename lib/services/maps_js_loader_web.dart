// lib/services/maps_js_loader_web.dart — CHANGE #634
//
// Injects the Google Maps JavaScript API using the key map_config_get() sent,
// and ONLY when map_config_get().uses_google_js is true.
//
// Before #634 this was a hardcoded <script> tag with a literal key in
// web/index.html: every page load billed a Maps JS request whether or not a map
// was ever opened, and a key problem showed up as the grey
// "for development purposes only" watermark on five different screens with no
// way to fix it without a rebuild. Now the key is a database value.
//
// Not a widget-tree file (DEFENSIVE IMPORT RULE): this is a service reached via
// conditional import, the same shape as url_sync_web.dart. Uses package:web +
// dart:js_interop rather than dart:html.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

const String _scriptId = 'medibo-google-maps-js';

Completer<bool>? _completer;

/// Loads the Maps JS API once per page. Returns true when `google.maps` is
/// ready, false on any failure (bad key, blocked network, no key supplied) so
/// the caller can show its empty state instead of a half-built map. Never
/// throws.
Future<bool> loadGoogleMapsJs(String browserKey) {
  final existing = _completer;
  if (existing != null) return existing.future;

  final c = Completer<bool>();
  _completer = c;

  // Already present (e.g. a future index.html, or a hot restart).
  if (_mapsReady()) {
    c.complete(true);
    return c.future;
  }
  if (browserKey.isEmpty) {
    // No key means the backend did not intend the JS path to be usable.
    c.complete(false);
    return c.future;
  }

  try {
    final script = web.document.createElement('script') as web.HTMLScriptElement;
    script.id = _scriptId;
    script.src = 'https://maps.googleapis.com/maps/api/js?key=$browserKey';
    script.async = true;
    script.onload = ((JSAny _) {
      if (!c.isCompleted) c.complete(_mapsReady());
    }).toJS;
    script.onerror = ((JSAny _) {
      if (!c.isCompleted) c.complete(false);
    }).toJS;
    web.document.head!.appendChild(script);
  } catch (_) {
    if (!c.isCompleted) c.complete(false);
    return c.future;
  }

  // Hard timeout — a map that never resolves would spin forever.
  Timer(const Duration(seconds: 12), () {
    if (!c.isCompleted) c.complete(_mapsReady());
  });
  return c.future;
}

bool _mapsReady() {
  try {
    if (!globalContext.has('google')) return false;
    final g = globalContext.getProperty('google'.toJS);
    if (g == null || !g.isA<JSObject>()) return false;
    return (g as JSObject).has('maps');
  } catch (_) {
    return false;
  }
}
