import 'dart:async';
import 'dart:convert';
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

  static void write(String key, dynamic value) {
    if (_log[key] == value) return; // skip if unchanged
    _log[key] = value;
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

  static void _scheduleSupabaseFlush(String? buildHash) {
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
    try {
      final data = Map<String, dynamic>.from(_log)..remove('build');
      Supabase.instance.client.rpc('render_log_note', params: {
        'p_build': buildHash ?? '',
        'p_data': data,
      }).then((_) {}).catchError((_) {});
    } catch (_) {}
  }
}
