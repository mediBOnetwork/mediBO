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

  // ── Auth storage diagnostics ──────────────────────────────────────────────

  // Returns "lskeys=<names>; durableKey=<present|absent>; cvKey=<present|absent>"
  // lskeys: all auth-token keys in localStorage.
  // durableKey: flutter.sb-swojhmarmaijkshsbeih-auth-token (SDK durable session store).
  // cvKey: flutter.supabase.auth.token-code-verifier (PKCE code-verifier; absent for password).
  static String authStorageInfo() {
    try {
      final ls = html.window.localStorage;
      final lsKeys = ls.keys
          .where((k) => k.contains('auth-token') || k.contains('auth.token'))
          .toList();
      final lskeys = lsKeys.isEmpty ? 'none' : lsKeys.join(',');
      const durableKeyDirect = 'sb-swojhmarmaijkshsbeih-auth-token';
      const durableKeyShared = 'flutter.sb-swojhmarmaijkshsbeih-auth-token';
      const cvKeyName = 'flutter.supabase.auth.token-code-verifier';
      final durablePresent = ls.keys.any((k) => k == durableKeyDirect || k == durableKeyShared);
      final cvPresent = ls.keys.any((k) => k == cvKeyName);
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
