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

  /// True once THIS session's fetch has landed. False while the notifier is
  /// showing the device cache, which is what `offline_note` is worded for.
  static bool get isLive => _live;
  static bool _live = false;

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

  /// The uid the cached payload was fetched FOR.
  ///
  /// Hostile QA round 2, NEW-1: the cache was keyed on a constant and validated
  /// only on `ok:true`, so account A's customer code, payment term, loyalty
  /// balance, referral code and wishlist count survived a sign-out in
  /// localStorage and were painted to account B on the next boot — indefinitely
  /// if B was offline. A shared pharmacy counter is exactly the machine this
  /// app ships "Staff logins" for, so that is a realistic switch, not a
  /// theoretical one. The stored payload carries its owner and is dropped the
  /// moment it does not match the signed-in uid.
  static const String _ownerKey = '_c745_owner_uid';

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
      if (p is! Map || p['ok'] != true) return;
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if ((p[_ownerKey] ?? '') != (uid ?? '')) {
        // Somebody else's menu, or nobody's. Drop it rather than draw it.
        await clear();
        RenderLog.write('c745_surfaces_cache', 'dropped_other_account');
        return;
      }
      value.value = Map<String, dynamic>.from(p);
      _live = false;
      RenderLog.write('c745_surfaces_cache', 'restored');
    } catch (_) {
      // A cache that cannot be read is simply not there.
    }
  }

  static Future<void> _persist(Map<String, dynamic> p) async {
    try {
      final stamped = Map<String, dynamic>.from(p)
        ..[_ownerKey] = Supabase.instance.client.auth.currentUser?.id ?? '';
      await (await SharedPreferences.getInstance())
          .setString(_cacheKey, jsonEncode(stamped));
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
      _live = true;
      value.value = p;
      unawaited(_persist(p));
      RenderLog.write(
          'c745_customer_surfaces',
          'account:${p['has_account']} '
              'profile:${itemsFor(p, 'profile_account').length} '
              'appbar:${itemsFor(p, 'catalogue_appbar').length} '
              'home:${itemsFor(p, 'home_strip').length} '
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

  /// The credential that owned this menu has gone. Drop it NOW — in memory and
  /// on the device — rather than waiting for a refetch that may never land.
  ///
  /// UserState._clearAccountState() calls this with the rest of the account
  /// state, for the reason its own comment gives: a half-cleared session is
  /// exactly the state that leaks one account's data into another's screen.
  /// Sign-out is synchronous and the refetch is not, so without this the
  /// storefront kept drawing the previous login's rewards badge, and a tab
  /// closed right after Logout left that payload on disk for the next login.
  static Future<void> clear() async {
    value.value = const {};
    _boundUid = null;
    _bound = false;
    _live = false;
    try {
      await (await SharedPreferences.getInstance()).remove(_cacheKey);
    } catch (_) {
      // A device that cannot forget still has an empty notifier above.
    }
  }
}
