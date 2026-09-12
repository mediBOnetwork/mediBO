// CHANGE #1016 — the staff tab bar, as the backend hands it over.
//
// Super admin, admin and partner share ONE shell (#653) and, from this change,
// ONE tab bar: Dashboard · Customers · Suppliers · Fulfill · Money · More.
// Which tabs a login sees, their order, their labels, their icons, the old
// route keys that must land somewhere new and whether the pre-#1016 layout is
// still switched on all arrive from `staff_nav()`. This file holds the answer
// and re-asks it when the identity changes; it decides nothing.
//
// Same shape as CustomerNav (#630): a ValueNotifier the shell listens to, so
// home_shell.dart does not grow a fetch, a cache and an auth listener for one
// more registry it draws.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/widgets.dart';
import '../design_tokens.dart';
import 'ui_copy.dart';

import '../screens/admin/admin_nav_entries.dart';
import '../screens/admin/nav_registry_view.dart';
import '../utils/render_log.dart';

/// One tab of the staff bar, exactly as `staff_nav().tabs[]` sent it.
@immutable
class StaffTab {
  const StaffTab({
    required this.key,
    required this.label,
    required this.iconKey,
    required this.routeKey,
    this.badgeKey = '',
    this.visible = true,
  });

  final String key;
  final String label;
  final String iconKey;
  final String routeKey;

  /// Which live count rides this tab ('order_alerts' on Fulfill), or ''.
  final String badgeKey;

  /// The backend's own answer to "may this login open the tab". A tab it
  /// turned off is not drawn; positions move with it, so nothing is ever
  /// addressed by index.
  final bool visible;

  factory StaffTab.fromJson(Map<String, dynamic> m) => StaffTab(
    key: (m['key'] ?? '').toString(),
    label: (m['label'] ?? '').toString(),
    iconKey: (m['icon_key'] ?? '').toString(),
    routeKey: (m['route_key'] ?? '').toString(),
    badgeKey: (m['badge_key'] ?? '').toString(),
    visible: m['visible'] != false,
  );
}

/// One redirect: an old route key and where it lands now.
@immutable
class StaffRedirect {
  const StaffRedirect({required this.to, this.whenNoSeed = false});

  final String to;

  /// Only redirect when the link carries no subject — a `customer_360/<id>`
  /// link still opens the 360 view; the bare tile opens the customers list.
  final bool whenNoSeed;
}

/// The whole `staff_nav()` answer.
@immutable
class StaffNavPayload {
  const StaffNavPayload({
    required this.ok,
    this.layout = 'v2',
    this.layoutNote = '',
    this.tabs = const [],
    this.redirects = const {},
    this.scope = const {},
    this.copy = const {},
    this.viewAs = const {},
  });

  static const StaffNavPayload empty = StaffNavPayload(ok: false);

  final bool ok;

  /// 'v2' (this change) or 'v1' (the pre-#1016 layout, while the
  /// `staff_layout_v1` app_settings flag is on and not expired).
  final String layout;
  final String layoutNote;
  final List<StaffTab> tabs;
  final Map<String, StaffRedirect> redirects;

  /// CHANGE #1017 — three blocks the shell renders VERBATIM.
  /// `scope`  : the header's zone/date — zone_label, date_label, zone_locked,
  ///            can_pick_zone, can_pick_all, can_pick_date. Chosen once, here.
  /// `copy`   : every sentence the staff chrome prints (offline banner, undo,
  ///            empty state, dark-mode labels).
  /// `viewAs` : the super admin's preview — active, role, options[], banner,
  ///            exit_label. The TABS above are already the previewed role's.
  final Map<String, dynamic> scope;
  final Map<String, dynamic> copy;
  final Map<String, dynamic> viewAs;

  bool get isLegacy => layout == 'v1';

  String copyOf(String key) => (copy[key] ?? '').toString();
  bool get isPreview => viewAs['active'] == true;
  String get previewBanner => (viewAs['banner'] ?? '').toString();
  String get previewExitLabel => (viewAs['exit_label'] ?? '').toString();
  bool get canPreview => viewAs['can_preview'] == true;
  List<Map<String, dynamic>> get previewOptions =>
      ((viewAs['options'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false);

  List<StaffTab> get visibleTabs =>
      tabs.where((t) => t.visible).toList(growable: false);

  factory StaffNavPayload.fromJson(Map<String, dynamic>? json) {
    if (json == null || json['ok'] != true) return empty;
    final tabs = ((json['tabs'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => StaffTab.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
    final redirects = <String, StaffRedirect>{};
    ((json['redirects'] as Map?) ?? const {}).forEach((k, v) {
      final m = (v as Map?)?.cast<String, dynamic>() ?? const {};
      final to = (m['to'] ?? '').toString();
      if (to.isEmpty) return;
      redirects[k.toString()] = StaffRedirect(
        to: to,
        whenNoSeed: m['when_no_seed'] == true,
      );
    });
    Map<String, dynamic> block(String k) =>
        (json[k] as Map?)?.cast<String, dynamic>() ?? const {};
    return StaffNavPayload(
      ok: true,
      layout: (json['layout'] ?? 'v2').toString(),
      layoutNote: (json['layout_note'] ?? '').toString(),
      tabs: tabs,
      redirects: redirects,
      scope: block('scope'),
      copy: block('copy'),
      viewAs: block('view_as'),
    );
  }

  /// The route a tap should really open. Returns [route] itself when the
  /// backend named no redirect for it — the table is data, and a route it does
  /// not mention is one that still opens where it always did.
  String resolve(String route, {bool hasSeed = false}) {
    final r = redirects[route];
    if (r == null) return route;
    if (r.whenNoSeed && hasSeed) return route;
    return r.to;
  }

  /// The tab whose own route_key is [route], or null.
  StaffTab? tabForRoute(String route) {
    for (final t in tabs) {
      if (t.routeKey == route) return t;
    }
    return null;
  }
}

/// The bar entries the shell draws, built from the payload: label and route
/// key verbatim, the glyph resolved through the same `kNavIcons` map every
/// registry tile uses. Pure, so a widget test hands a payload straight in.
List<AdminNavEntry> staffNavEntries(StaffNavPayload payload) => [
  for (final t in payload.visibleTabs)
    AdminNavEntry(t.label, navIcon(t.iconKey), route: t.routeKey),
];

/// The app-wide holder. One `staff_nav()` per signed-in staff session.
class StaffNav {
  StaffNav._();

  static final ValueNotifier<StaffNavPayload> value =
      ValueNotifier<StaffNavPayload>(StaffNavPayload.empty);

  static String? _boundUid;
  static bool _bound = false;
  static bool _loading = false;

  /// Test seam: hand the payload in, no Supabase.
  @visibleForTesting
  static void debugSet(StaffNavPayload p) => value.value = p;

  // CHANGE #1016 (N) — the last good answer, on disk. Until staff_nav()
  // answers the shell draws the pre-#1016 bar, and on a slow morning that was
  // a whole second of the wrong five tabs before the six arrived. Offline
  // rule: render the cached payload instantly, refetch, re-render. The cache
  // is stamped with the login it belongs to and is a render fallback only —
  // a live answer always replaces it and a refusal never comes from it.
  static const String _cacheKey = 'staff_nav.cache.v1';
  static const String _ownerKey = '_owner_uid';

  /// Whose device this is. A seam so the cache can be tested on the Dart VM
  /// with no Supabase; production reads the live session.
  @visibleForTesting
  static String? Function() currentUid = () =>
      Supabase.instance.client.auth.currentUser?.id;

  /// Test seam: the disk→notifier half of [load], alone.
  @visibleForTesting
  static Future<void> debugRestore() => _restore();

  static Future<void> _restore() async {
    if (value.value.ok) return;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      if (value.value.ok) return; // a live answer already won
      final p = jsonDecode(raw);
      if (p is! Map || p['ok'] != true) return;
      final uid = currentUid();
      if ((p[_ownerKey] ?? '') != (uid ?? '')) {
        await _forget();
        RenderLog.write('c1016_nav_cache', 'dropped_other_account');
        return;
      }
      final cached = StaffNavPayload.fromJson(p.cast<String, dynamic>());
      if (!cached.ok) return;
      value.value = cached;
      RenderLog.write('c1016_nav_cache', 'restored');
    } catch (_) {
      // A device that cannot read its cache boots exactly as before.
    }
  }

  static Future<void> _persist(Map<String, dynamic> p) async {
    try {
      final stamped = Map<String, dynamic>.from(p)
        ..[_ownerKey] = currentUid() ?? '';
      await (await SharedPreferences.getInstance()).setString(
        _cacheKey,
        jsonEncode(stamped),
      );
    } catch (_) {
      // Persisting is a convenience; failing to must never fail the fetch.
    }
  }

  static Future<void> _forget() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_cacheKey);
    } catch (_) {
      // nothing to forget
    }
  }

  /// CHANGE #1017 (7) — the role the super admin is previewing, or null.
  /// The BACKEND computes the previewed bar; this only remembers the ask.
  static String? previewRole;

  /// Enter or leave a preview. The next load carries it; a preview payload is
  /// never written to the cache, so a restart always comes back as yourself.
  static Future<void> preview(String? role) async {
    previewRole = (role ?? '').trim().isEmpty ? null : role!.trim();
    RenderLog.write('c1017_view_as', previewRole ?? 'exit');
    await load();
  }

  // CHANGE #1017 (4) — the dark-mode choice is the device's until the person
  // picks one; a pick is remembered on this device (shared_preferences, the
  // sanctioned store — never dart:html) and re-applied before the first load.
  static const String _darkKey = 'staff.dark_mode';
  static bool _brightnessRestored = false;

  static Future<void> setDark(bool? dark) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (dark == null) {
        await prefs.remove(_darkKey);
      } else {
        await prefs.setBool(_darkKey, dark);
      }
    } catch (_) {}
    _applyBrightness(dark);
    RenderLog.write('c1017_dark_mode', dark == null ? 'system' : (dark ? 'on' : 'off'));
    UiCopy.revision.value++; // MaterialApp rebuilds and buildTheme() reads Ds.brightness
  }

  static void _applyBrightness(bool? dark) {
    final b = dark == null
        ? WidgetsBinding.instance.platformDispatcher.platformBrightness
        : (dark ? Brightness.dark : Brightness.light);
    Ds.setBrightness(b);
  }

  static Future<void> restoreBrightness() async {
    if (_brightnessRestored) return;
    _brightnessRestored = true;
    bool? dark;
    try {
      dark = (await SharedPreferences.getInstance()).getBool(_darkKey);
    } catch (_) {}
    _applyBrightness(dark);
    if (Ds.isDark) UiCopy.revision.value++;
  }

  static Future<void> load() async {
    if (_loading) return;
    _loading = true;
    try {
      await restoreBrightness();
      await _restore();
      final raw = await Supabase.instance.client.rpc('staff_nav',
          params: {'p_view_as_role': previewRole});
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (map is! Map) return;
      final json = map.cast<String, dynamic>();
      final next = StaffNavPayload.fromJson(json);
      // A refusal (signed out, a customer) blanks nothing: the shell only
      // draws this bar for admin-surface logins, and a failed refresh keeps
      // the last good answer — boot resilience rule.
      if (!next.ok) return;
      _boundUid = Supabase.instance.client.auth.currentUser?.id;
      _bound = true;
      value.value = next;
      if (!next.isPreview) await _persist(json);
      RenderLog.write(
        'c1016_staff_tabs',
        next.visibleTabs.map((t) => t.key).join('>'),
      );
      RenderLog.write('c1016_staff_layout', next.layout);
    } catch (_) {
      // keep whatever is drawn
    } finally {
      _loading = false;
    }
  }

  /// The auth identity moved — re-ask. Login, account switch and logout all
  /// change which tabs come back.
  static void syncIdentity() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (!_bound) {
      if (uid != null) load();
      return;
    }
    if (uid == _boundUid) return;
    _boundUid = uid;
    if (uid == null) {
      value.value = StaffNavPayload.empty;
      _bound = false;
      _forget(); // signed out: nobody's bar stays on this device
      return;
    }
    load();
  }
}
