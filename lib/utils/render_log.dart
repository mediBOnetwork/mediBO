import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:supabase_flutter/supabase_flutter.dart';

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

  // ── Auth storage helpers (belt-and-suspenders for Google session persistence) ──

  // The key supabase_flutter uses: sb-<project_ref>-auth-token
  static const _authKey = 'sb-svojhmarmaijkshsbeih-auth-token';

  // Returns "ls_key=found|none; ss_key=found|none" by suffix-matching localStorage/sessionStorage.
  static String authStorageInfo() {
    try {
      final ls = html.window.localStorage;
      final ss = html.window.sessionStorage;
      final lsFound = ls.keys.any((k) => k.contains('auth-token') || k.contains('auth.token'));
      final ssFound = ss.keys.any((k) => k.contains('auth-token') || k.contains('auth.token'));
      return 'ls_key=${lsFound ? 'found' : 'none'}; ss_key=${ssFound ? 'found' : 'none'}';
    } catch (_) {
      return 'ls_key=err; ss_key=err';
    }
  }

  // Explicitly write the session JSON to the SDK's localStorage key.
  // Belt-and-suspenders in case the SDK's async persist stream fires late.
  static void persistAuthSession(String sessionJson) {
    try {
      html.window.localStorage[_authKey] = sessionJson;
    } catch (_) {}
  }

  // Returns the raw session JSON from localStorage (null if not present).
  static String? getRawAuthSession() {
    try {
      return html.window.localStorage[_authKey];
    } catch (_) {
      return null;
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

  // ── Internal ──────────────────────────────────────────────────────────────

  static void _writeToDOM() {
    try {
      final text = _log.entries.map((e) => '${e.key}=${e.value}').join('\n');
      html.document.getElementById('medibo-render-log')?.text = text;
      html.window.localStorage['medibo_render_log'] = text;
    } catch (_) {}
  }

  static void _scheduleSupabaseFlush(String? buildHash) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () => _flushToSupabase(buildHash));
  }

  static void _flushToSupabase(String? buildHash) {
    try {
      final data = Map<String, dynamic>.from(_log)..remove('build');
      Supabase.instance.client.from('render_log').upsert({
        'id': 'singleton',
        'build_hash': buildHash ?? 'unknown',
        'data': data,
        'updated_at': DateTime.now().toIso8601String(),
      }).then((_) {}).catchError((_) {});
    } catch (_) {}
  }
}
