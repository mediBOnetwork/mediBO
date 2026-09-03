import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

/// CHANGE #745 — WHERE a customer feature lives is backend data.
///
/// Om, on My Profile: the dropdown had become a dumping ground — My Wishlist,
/// Rewards and "Deliver with mediBO" sat next to Edit my details and Logout.
/// Each of those was a hardcoded `if (...) _EntryCard()` in profile_screen.dart,
/// so the placement of a customer feature was a Dart decision.
///
/// It is a registry now, the same arrangement #653 gave the admin shell:
/// `feature_registry` (surface `customer_menu`) says which features a pharmacy
/// has, `customer_feature_placement` says which surface offers each one, and
/// `customer_surfaces()` returns the whole answer already worded and ordered.
/// Moving Rewards out of Orders tomorrow is one UPDATE.
///
/// Same shape as [CustomerNav] (#630): the shell listens, so a fetch, a cache
/// and an auth listener never become home_shell.dart's business.
class CustomerSurfaces {
  CustomerSurfaces._();

  /// The last good payload. Empty until the first answer lands — every reader
  /// treats "no key" as "nothing to draw", never as an error.
  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  static String? _boundUid;
  static bool _bound = false;
  static bool _started = false;

  /// The offline rule, and hostile QA round 1's second blocker.
  ///
  /// The whole Account group — Logout and the delete zone included — is now
  /// payload-driven, so ONE failed RPC used to leave a signed-in pharmacy on a
  /// profile with no way out and no retry. The last good answer is kept on the
  /// device and rendered instantly on the next boot; the refetch happens behind
  /// it and only ever REPLACES a good answer with another good one. The cache
  /// is a render fallback, never an authority — every write still goes to the
  /// backend, which re-checks the caller.
  static const String _cacheKey = 'c745_customer_surfaces';

  /// Fetch once per session, then keep the answer in step with the login.
  ///
  /// Every surface that draws a customer entry calls this from its own
  /// initState, so the shell never grows a fetch, a cache and an auth listener
  /// for a registry it merely renders (#630's arrangement). The auth
  /// subscription is what makes the answer change on sign-in: a chrome
  /// resolved for a signed-out visitor would otherwise show a visitor's
  /// (empty) menu for the rest of the session.
  static void ensureLoaded() {
    if (_started) {
      syncIdentity();
      return;
    }
    _started = true;
    try {
      Supabase.instance.client.auth.onAuthStateChange.listen((_) => load());
    } catch (_) {
      // Boot resilience rule: a listener that cannot attach must never sit in
      // front of the surface that asked for it.
    }
    _restore();
    load();
  }

  /// Paint the last good answer before the network has said anything.
  static Future<void> _restore() async {
    if (value.value.isNotEmpty) return;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      if (value.value.isNotEmpty) return; // a live answer already won
      final p = jsonDecode(raw);
      if (p is Map && p['ok'] == true) {
        value.value = Map<String, dynamic>.from(p);
        RenderLog.write('c745_surfaces_cache', 'restored');
      }
    } catch (_) {
      // A cache that cannot be read is simply not there.
    }
  }

  static Future<void> _persist(Map<String, dynamic> p) async {
    try {
      await (await SharedPreferences.getInstance())
          .setString(_cacheKey, jsonEncode(p));
    } catch (_) {
      // Persisting is a convenience; failing to must never fail the fetch.
    }
  }

  /// The entries the backend placed on [placement], in the backend's order.
  static List<Map<String, dynamic>> itemsFor(
      Map<String, dynamic> payload, String placement) {
    final places = payload['placements'];
    if (places is! Map) return const [];
    final raw = places[placement];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  /// A nested object, or an empty map when the payload never sent it.
  static Map<String, dynamic> block(
      Map<String, dynamic> payload, String key) {
    final v = payload[key];
    return v is Map ? Map<String, dynamic>.from(v) : const {};
  }

  static Future<void> load() async {
    try {
      final raw = await Supabase.instance.client.rpc('customer_surfaces');
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (map is! Map) return;
      final p = Map<String, dynamic>.from(map);
      if (p['ok'] != true) return;
      _boundUid = Supabase.instance.client.auth.currentUser?.id;
      _bound = true;
      value.value = p;
      unawaited(_persist(p));
      RenderLog.write(
          'c745_customer_surfaces',
          'account:${p['has_account']} '
              'profile:${itemsFor(p, 'profile_account').length} '
              'appbar:${itemsFor(p, 'catalogue_appbar').length} '
              'home:${itemsFor(p, 'home_chip').length} '
              'orders:${itemsFor(p, 'orders_section').length}');
    } catch (_) {
      // A chrome that cannot ask keeps whatever it has. Boot resilience rule.
    }
  }

  /// The auth identity moved — re-ask. Never blanks what is already drawn.
  static void syncIdentity() {
    if (!_bound) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == _boundUid) return;
    _boundUid = uid;
    load();
  }
}
