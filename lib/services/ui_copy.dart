import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';

/// Every user-visible string that has no dedicated RPC field lives in the
/// `ui_copy` table and arrives through `ui_copy_all()`.
///
/// THE APP RENDERS. IT NEVER DECIDES. — a missing key renders as an EMPTY
/// string, never as a Dart fallback. A fallback literal would recreate the
/// exact problem this service removes: two copies of the same answer, one of
/// them stale.
///
/// Offline behaviour (Om's rule 8): the last payload is cached in
/// shared_preferences and rendered instantly on the next boot. The cache is a
/// render fallback, never an authority — it answers "what word do I print",
/// never "who am I" or "what may I do".
class UiCopy {
  UiCopy._();

  // v2: the cached payload is now the whole ui_boot() envelope ({copy, design}),
  // not the flat copy map. A new key so a v1 cache is ignored, not misread.
  static const _prefsKey = 'ui_boot_cache_v2';

  static Map<String, String> _map = const {};

  /// Bumped whenever the map changes, so the app can rebuild once the network
  /// copy lands after a cache-first paint.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// True once a NETWORK payload has been applied (cache-only is false).
  static bool fromNetwork = false;

  /// Number of keys currently held — used by render-log verification.
  static int get count => _map.length;

  /// Renders a backend string. Unknown key → empty, deliberately.
  static String t(String key) => _map[key] ?? '';

  /// Same, but for a value the backend stores as a number/bool in jsonb.
  static bool flag(String key) => _map[key] == 'true';

  /// Test seam: inject copy without touching the network.
  @visibleForTesting
  static void debugSet(Map<String, String> values) {
    _map = Map<String, String>.unmodifiable(values);
    revision.value++;
  }

  /// Cache-first, then network. Safe to call more than once.
  ///
  /// [networkWait] bounds how long boot will wait for the first fetch; the
  /// fetch continues in the background past the timeout and bumps [revision]
  /// when it lands, so a slow connection never blocks first paint.
  static Future<void> load({
    Duration networkWait = const Duration(seconds: 3),
  }) async {
    await _hydrateFromCache();
    final fetch = _fetch();
    try {
      await fetch.timeout(networkWait);
    } on TimeoutException {
      // Painted from cache; the in-flight fetch will re-render on arrival.
    } catch (_) {
      // Offline or RPC failure — cache stands in until the next refresh.
    }
  }

  /// Re-fetch in the background (e.g. on auth change or app resume).
  static Future<void> refresh() => _fetch().catchError((_) {});

  static Future<void> _hydrateFromCache() async {
    if (_map.isNotEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      _apply(jsonDecode(raw));
    } catch (_) {}
  }

  static Future<void> _fetch() async {
    // ONE call per boot: ui_boot() returns {copy, design}. The app renders copy
    // and paints the design tokens from the same payload, so the two can never
    // disagree. Flat-copy compatibility: if ui_boot is unavailable, fall back
    // to ui_copy_all() so a weak-connection / old-backend boot still gets words.
    dynamic raw;
    try {
      raw = await Supabase.instance.client.rpc('ui_boot');
    } catch (_) {
      raw = await Supabase.instance.client.rpc('ui_copy_all');
    }
    _apply(raw);
    fromNetwork = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(raw));
    } catch (_) {}
  }

  /// Accepts either the ui_boot envelope ({copy, design}) or a flat copy map
  /// (ui_copy_all / a v1-shaped payload). Design tokens, when present, are
  /// handed to [Ds] so the theme repaints from the same revision bump.
  static void _apply(dynamic raw) {
    if (raw is! Map) return;

    // Envelope shape: {copy:{...}, design:{...}}.
    final bool isEnvelope = raw['copy'] is Map || raw['design'] is Map;
    final Map copyMap = isEnvelope ? (raw['copy'] is Map ? raw['copy'] as Map : const {}) : raw;

    if (isEnvelope && raw['design'] != null) {
      Ds.apply(raw['design']); // repaint the theme from backend tokens
    }

    final next = <String, String>{};
    copyMap.forEach((k, v) {
      if (k is! String) return;
      next[k] = v is String ? v : (v == null ? '' : v.toString());
    });
    if (next.isEmpty && _map.isNotEmpty) return; // never blank out live copy
    _map = Map<String, String>.unmodifiable(next);
    revision.value++;
  }
}

/// Shorthand used across the widget tree: `c('cart.empty_title')`.
String c(String key) => UiCopy.t(key);

/// A backend template with runtime values substituted into it — the WORDING
/// still belongs to the backend, only the value is local.
/// Template: `"Delete {name}?"` → `cf('x.confirm', {'name': n})`.
/// An unknown key stays empty; substitution never invents a sentence.
String cf(String key, Map<String, String> vars) {
  var s = UiCopy.t(key);
  if (s.isEmpty) return '';
  vars.forEach((k, v) => s = s.replaceAll('{$k}', v));
  return s;
}
