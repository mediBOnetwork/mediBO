// CMD #2059 — the registration surface, held on the device.
//
// The problem this solves is the two seconds between tapping Continue and
// seeing a field: the form's schema used to be fetched only when the screen
// opened, so the screen opened empty with a spinner in the middle of it.
//
// `storefront_home_v2().registration` now carries the whole surface — schema,
// prefill, saved draft, both steps and every string around them — so by the
// time Home has painted, the app is already holding the form. This class is
// that holding place: one payload, cached per ROLE in shared_preferences,
// rendered instantly on the next open and refreshed in the background.
//
// It decides nothing. Every field in the payload was authored by
// `customer_registration_payload()`; this file stores it and hands it back.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

class RegistrationSurface {
  RegistrationSurface._();

  static const _prefix = 'c2059_reg_surface_';

  /// Which cache this device is reading. The payload a customer needs is not
  /// the payload an admin needs, so they never share a slot.
  static String role = 'customer';

  static Map<String, dynamic> _p = const {};
  static bool _restored = false;

  /// Bumped on every adopt, so a screen already on stage repaints when the
  /// background refresh lands.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Test seam — same shape every screen in this app uses.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  static String get _key => '$_prefix$role';

  /// The whole payload, or an empty map when nothing has been seen yet.
  static Map<String, dynamic> get payload => _p;

  /// True once a payload with a form schema in it is held — the one question
  /// the form screen asks before deciding between fields and a skeleton.
  static bool get hasForm =>
      ((_p['schema'] as Map?)?['fields'] as List?)?.isNotEmpty == true;

  static Map<String, dynamic> get schema =>
      Map<String, dynamic>.from((_p['schema'] as Map?) ?? const {});

  static Map<String, dynamic> get prefill =>
      Map<String, dynamic>.from((_p['prefill'] as Map?) ?? const {});

  static Map<String, dynamic> get draft =>
      Map<String, dynamic>.from((_p['draft'] as Map?) ?? const {});

  static Map<String, dynamic> get autosave =>
      Map<String, dynamic>.from((_p['autosave'] as Map?) ?? const {});

  static Map<String, dynamic> get sheet =>
      Map<String, dynamic>.from((_p['sheet'] as Map?) ?? const {});

  static Map<String, dynamic> get step =>
      Map<String, dynamic>.from((_p['step'] as Map?) ?? const {});

  static List<Map<String, dynamic>> get steps =>
      ((_p['steps'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  /// Whether the backend still wants something from this account.
  static bool get needs => _p['needs'] == true;

  /// Install a payload directly (tests, and the home feed's own block).
  static void seed(Map<String, dynamic> block) {
    _p = Map<String, dynamic>.from(block);
    revision.value++;
  }

  /// Take the `registration` block off a home payload and keep it.
  ///
  /// A payload without the block (an anonymous feed, an older backend) leaves
  /// what is already held alone: the cache is a render fallback, never an
  /// authority on whether registration is owed.
  static void adopt(dynamic block) {
    if (block is! Map) return;
    seed(Map<String, dynamic>.from(block));
    RenderLog.write('c2059_reg_surface',
        'needs=${needs ? 1 : 0};fields=${((schema['fields'] as List?) ?? const []).length}');
    unawaited(_persist());
  }

  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_p));
    } catch (_) {
      // A device that refuses to store simply renders from the network.
    }
  }

  /// Read the last payload back on a cold start. Safe to call more than once.
  static Future<void> restore() async {
    if (_restored && _p.isNotEmpty) return;
    _restored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map && _p.isEmpty) seed(Map<String, dynamic>.from(decoded));
    } catch (_) {
      // Unreadable cache: the refresh below fills it.
    }
  }

  /// Ask the backend for a fresh copy. Never awaited by a screen's first
  /// paint — the cached copy is what paints, this is what replaces it.
  static Future<void> refresh() async {
    try {
      final r = await _rpc('customer_registration_payload');
      if (r is Map) adopt(r);
    } catch (_) {
      // Keep the cached payload; the form is still rendered from it.
    }
  }

  /// Cache-first: paint from what is held, then refresh behind the screen.
  static Future<void> warm() async {
    await restore();
    unawaited(refresh());
  }

  /// One field changed. The draft is the backend's, so this is a write, not a
  /// local copy; the held payload is updated too, so re-opening the form
  /// before the next home refresh still shows what was typed.
  static Future<void> saveDraft(Map<String, dynamic> patch) async {
    if (patch.isEmpty) return;
    final merged = Map<String, dynamic>.from(draft)..addAll(patch);
    _p = Map<String, dynamic>.from(_p)..['draft'] = merged;
    unawaited(_persist());
    try {
      await _rpc('customer_reg_draft_save', {'p_patch': patch, 'p_context': 'signup'});
      RenderLog.write('c2059_reg_draft_saved', merged.length);
    } catch (_) {
      // The next keystroke retries; nothing typed is lost on the device.
    }
  }

  /// The form was submitted: the draft has served its purpose, so it goes,
  /// and the surface is re-read because the step it is on has just changed.
  static Future<void> submitted() async {
    _p = Map<String, dynamic>.from(_p)..['draft'] = <String, dynamic>{};
    unawaited(_persist());
    try {
      await _rpc('customer_reg_draft_clear', {'p_context': 'signup'});
    } catch (_) {}
    await refresh();
  }

  /// Forget everything for this role — used on sign-out.
  static Future<void> clear() async {
    _p = const {};
    revision.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
    try {
      await _rpc('customer_reg_draft_clear', {'p_context': 'signup'});
    } catch (_) {}
  }

  @visibleForTesting
  static void resetForTest() {
    _p = const {};
    _restored = false;
    role = 'customer';
  }
}
