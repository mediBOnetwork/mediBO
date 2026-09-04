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
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  });

  static const StaffNavPayload empty = StaffNavPayload(ok: false);

  final bool ok;

  /// 'v2' (this change) or 'v1' (the pre-#1016 layout, while the
  /// `staff_layout_v1` app_settings flag is on and not expired).
  final String layout;
  final String layoutNote;
  final List<StaffTab> tabs;
  final Map<String, StaffRedirect> redirects;

  bool get isLegacy => layout == 'v1';

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
      redirects[k.toString()] =
          StaffRedirect(to: to, whenNoSeed: m['when_no_seed'] == true);
    });
    return StaffNavPayload(
      ok: true,
      layout: (json['layout'] ?? 'v2').toString(),
      layoutNote: (json['layout_note'] ?? '').toString(),
      tabs: tabs,
      redirects: redirects,
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

  static Future<void> load() async {
    if (_loading) return;
    _loading = true;
    try {
      final raw = await Supabase.instance.client.rpc('staff_nav');
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (map is! Map) return;
      final next = StaffNavPayload.fromJson(map.cast<String, dynamic>());
      // A refusal (signed out, a customer) blanks nothing: the shell only
      // draws this bar for admin-surface logins, and a failed refresh keeps
      // the last good answer — boot resilience rule.
      if (!next.ok) return;
      _boundUid = Supabase.instance.client.auth.currentUser?.id;
      _bound = true;
      value.value = next;
      RenderLog.write('c1016_staff_tabs',
          next.visibleTabs.map((t) => t.key).join('>'));
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
      return;
    }
    load();
  }
}
