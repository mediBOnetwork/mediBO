import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

// CHANGE #635: dart:html reached this file directly, which made every library
// that imports RenderLog — including the pure logic in fulfill/ — impossible to
// load on the Dart VM, so unit tests could not import them at all. The four DOM
// calls now sit behind a conditional import: identical code on web, no-ops off it.
import 'render_log_dom_stub.dart'
    if (dart.library.html) 'render_log_dom.dart' as dom;

/// Lightweight render-state logger for verifying what actually rendered in a
/// Flutter web (canvas) app. Writes to:
///   • window.__mediboRenderLog  (JS global, readable in DevTools)
///   • #medibo-render-log div    (hidden DOM node)
///   • localStorage              (persists across tabs for debug.html)
///   • Supabase render_log table (readable via MCP / curl after user visits)
///
/// Supabase writes are debounced 800 ms — zero overhead per individual call.
class RenderLog {
  RenderLog._();

  static final Map<String, dynamic> _log = {};
  static Timer? _debounce;

  // ── Public API ────────────────────────────────────────────────────────────

  static void setBuildHash(String hash) {
    _log['build'] = hash;
    _writeToDOM();
    _scheduleSupabaseFlush(hash);
  }

  static String get buildHash => (_log['build'] as String?) ?? 'unknown';

  // ── Auth storage diagnostics ──────────────────────────────────────────────

  // Returns "lskeys=<names>; durableKey=<present|absent>; cvKey=<present|absent>"
  // lskeys: all auth-token keys in localStorage.
  // durableKey: flutter.sb-swojhmarmaijkshsbeih-auth-token (SDK durable session store).
  // cvKey: flutter.supabase.auth.token-code-verifier (PKCE code-verifier; absent for password).
  static String authStorageInfo() {
    try {
      final lsKeys = dom
          .localStorageKeys()
          .where((k) => k.contains('auth-token') || k.contains('auth.token'))
          .toList();
      final lskeys = lsKeys.isEmpty ? 'none' : lsKeys.join(',');
      const durableKeyDirect = 'sb-swojhmarmaijkshsbeih-auth-token';
      const durableKeyShared = 'flutter.sb-swojhmarmaijkshsbeih-auth-token';
      const cvKeyName = 'flutter.supabase.auth.token-code-verifier';
      final allKeys = dom.localStorageKeys();
      final durablePresent = allKeys.any((k) => k == durableKeyDirect || k == durableKeyShared);
      final cvPresent = allKeys.any((k) => k == cvKeyName);
      return 'lskeys=$lskeys; durableKey=${durablePresent ? 'present' : 'absent'}; cvKey=${cvPresent ? 'present' : 'absent'}';
    } catch (_) {
      return 'lskeys=err; durableKey=err; cvKey=err';
    }
  }

  static void reset() {
    final build = _log['build'];
    _log.clear();
    if (build != null) _log['build'] = build;
    _writeToDOM();
    // Don't flush to Supabase on reset — wait for new writes
  }

  /// CHANGE #638 — the one hook a session recording needs. A screen that
  /// reports itself here is a screen a recorded walkthrough can replay, so the
  /// recorder listens instead of guessing at route names. Null in every build
  /// where nothing is recording, which is every build until Om taps Record.
  static void Function(String key, dynamic value)? onWrite;

  static void write(String key, dynamic value) {
    if (_log[key] == value) return; // skip if unchanged
    _log[key] = value;
    final hook = onWrite;
    if (hook != null) {
      try {
        hook(key, value);
      } catch (_) {
        // A recorder must never be able to break the screen it is watching.
      }
    }
    _writeToDOM();
    _scheduleSupabaseFlush(_log['build'] as String?);
  }

  /// CMD #1950 — MOBILE-FIRST: the app reports its own overflow.
  ///
  /// Flutter web paints to canvas, so no browser tool can measure a clipped
  /// row or a RenderFlex that ran off the right edge — but the framework
  /// already knows, and says so through FlutterError. main.dart routes those
  /// here, so the post-deploy responsive sweep can load every top screen at
  /// 320/360/412/480 px and read a NUMBER out of the render log instead of
  /// guessing from pixels.
  ///
  /// `overflow_errors` is the count the sweep asserts is 0. `overflow_first`
  /// keeps the first message (trimmed) so a red sweep names the widget, and
  /// `overflow_at_w` the viewport width it happened at.
  static void noteOverflow(String message, {int? viewportWidth}) {
    final n = ((_log['overflow_errors'] as int?) ?? 0) + 1;
    _log['overflow_errors'] = n;
    if (_log['overflow_first'] == null) {
      _log['overflow_first'] =
          message.length > 160 ? message.substring(0, 160) : message;
      if (viewportWidth != null) _log['overflow_at_w'] = viewportWidth;
    }
    _writeToDOM();
    _scheduleSupabaseFlush(_log['build'] as String?);
  }

  /// The viewport the sweep is currently looking at, so a red count can be
  /// attributed to a width. Written by the app on every metrics change.
  static void noteViewport(int width, int height) {
    if (_log['viewport_w'] == width && _log['viewport_h'] == height) return;
    _log['viewport_w'] = width;
    _log['viewport_h'] = height;
    _writeToDOM();
    _scheduleSupabaseFlush(_log['build'] as String?);
  }

  /// CHANGE #559: write and flush IMMEDIATELY, with no debounce.
  ///
  /// The normal 800 ms debounce is fine for render counts, but useless for
  /// anything logged on a code path that is about to navigate the browser away
  /// — the page is gone long before the timer fires. Use this for every key
  /// that has to survive leaving the app.
  static void writeNow(String key, dynamic value) {
    _log[key] = value;
    _writeToDOM();
    _debounce?.cancel();
    _flushToSupabase(_log['build'] as String?);
  }

  /// CHANGE #559: absorb the notes written by the pre-Flutter JS instrumentation
  /// in web/index.html (window.open / navigate / unload hooks), which stores
  /// them under `medibo_nav_log`. The JS pushes them to Supabase itself with a
  /// keepalive fetch; this is the belt-and-braces path for the case where that
  /// request was dropped — the keys then land on the next page load.
  static void adoptJsNotes() {
    try {
      final raw = dom.localStorageGet('medibo_nav_log');
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      var added = false;
      decoded.forEach((k, v) {
        final key = k.toString();
        if (_log[key] == v) return;
        _log[key] = v;
        added = true;
      });
      if (added) {
        _writeToDOM();
        _scheduleSupabaseFlush(_log['build'] as String?);
      }
    } catch (_) {}
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  static void _writeToDOM() {
    try {
      final text = _log.entries.map((e) => '${e.key}=${e.value}').join('\n');
      dom.setElementText('medibo-render-log', text);
      dom.localStorageSet('medibo_render_log', text);
    } catch (_) {}
  }

  /// CHANGE #639 — test seam. The 800 ms debounce below is a real Timer, and a
  /// widget test that renders anything calling [write] would end with a timer
  /// still pending (which the test binding treats as a failure) and would try
  /// to reach Supabase from the VM. The protected suite turns this off; nothing
  /// in production ever does, so the live flush is unchanged.
  @visibleForTesting
  static bool flushEnabled = true;

  static void _scheduleSupabaseFlush(String? buildHash) {
    if (!flushEnabled) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () => _flushToSupabase(buildHash));
  }

  // CHANGE #559: flush through the render_log_note RPC instead of a direct
  // table upsert.
  //
  // WHY: render_log's RLS grants writes to `authenticated` only. On the login
  // screen the user is by definition signed OUT, so every diagnostic written
  // there was silently rejected and the render-log showed nothing — which is
  // exactly why the Google sign-in path has been impossible to observe.
  // render_log_note is SECURITY DEFINER, granted to anon, and MERGES the keys
  // it is given rather than replacing the row, so a signed-out writer can never
  // wipe what a signed-in one recorded.
  static void _flushToSupabase(String? buildHash) {
    // CHANGE #536 — the seam has to hold here too, not only on the debounced
    // path. writeNow() calls this DIRECTLY, so a widget test rendering a
    // writeNow caller reached Supabase from the VM even with flushEnabled
    // false. It was survivable only because the throw lands in the catch
    // below; in a test where Supabase IS initialised it would be a real write.
    if (!flushEnabled) return;
    try {
      final data = Map<String, dynamic>.from(_log)..remove('build');
      Supabase.instance.client.rpc('render_log_note', params: {
        'p_build': buildHash ?? '',
        'p_data': data,
      }).then((_) {}).catchError((_) {});
    } catch (_) {}
  }
}
