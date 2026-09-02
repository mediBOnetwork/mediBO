// CHANGE #653 — ONE interface for super admin, admin and partner.
//
// There is no /partner layout and there are no role-specific screens. Every
// login gets the SAME shell, the SAME nav and the SAME routes; the only
// differentiator is this matrix: per feature, View on/off and Write on/off.
//
// The matrix is authored entirely in Supabase (access_role_default +
// access_grant, resolved by access_effective) and arrives as ONE payload from
// access_boot(). Nothing here decides anything: [AccessMatrix] is a reader of
// the backend's booleans and the backend's refusal wording. A Dart-side rule
// about who may see what would be a second source of truth, and the RPC guard
// would disagree with the nav the first time they drifted.
//
// Deliberately split in two so the decisions are testable on the Dart VM:
//   * [AccessMatrix] — pure, constructed from a plain map, no Supabase.
//   * [Access]       — the singleton that fetches it and notifies the shell.

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The backend's answer for ONE feature.
@immutable
class FeatureAccess {
  const FeatureAccess({required this.canView, required this.canWrite});

  /// Absence is explicit: a feature the payload never mentioned is OFF, which
  /// is not the same as a matrix that has not loaded yet (see
  /// [AccessMatrix.resolved]).
  static const FeatureAccess off =
      FeatureAccess(canView: false, canWrite: false);

  final bool canView;
  final bool canWrite;
}

/// The whole matrix for the signed-in login, rendered verbatim from
/// `access_boot()`.
@immutable
class AccessMatrix {
  const AccessMatrix({
    required this.resolved,
    this.role = 'none',
    this.isSuper = false,
    this.zoneLocked = false,
    this.zoneLabel = '',
    this.deniedViewMessage = '',
    this.deniedWriteMessage = '',
    this.readonlyBadge = '',
    Map<String, FeatureAccess> features = const {},
    Map<String, String> routeFeature = const {},
    Map<String, List<AccessTab>> tabs = const {},
  })  : _features = features,
        _routeFeature = routeFeature,
        _tabs = tabs;

  /// Nothing has been fetched yet.
  ///
  /// [resolved] is false here, and every gate below answers `true` in that
  /// state ON PURPOSE: an unloaded matrix is not the same as "View off", and a
  /// slow or failed boot call must never blank out the shell of an admin who
  /// has every screen. The refusal that matters is the backend one — every
  /// mutation RPC calls `access_require()` server-side, so a permissive
  /// unresolved matrix cannot grant anything.
  static const AccessMatrix unresolved = AccessMatrix(resolved: false);

  final bool resolved;

  /// 'super_admin' | 'admin' | 'partner' | 'none' — the backend's own word.
  final String role;
  final bool isSuper;

  /// Scope, not permission: a partner login is locked to its zone. The zone
  /// rule itself lives in the backend; this is only how the shell labels it.
  final bool zoneLocked;
  final String zoneLabel;

  /// Backend copy. Never worded in Dart.
  final String deniedViewMessage;
  final String deniedWriteMessage;
  final String readonlyBadge;

  final Map<String, FeatureAccess> _features;
  final Map<String, String> _routeFeature;
  final Map<String, List<AccessTab>> _tabs;

  factory AccessMatrix.fromJson(Map<String, dynamic>? json) {
    if (json == null || json['ok'] != true) return unresolved;

    final features = <String, FeatureAccess>{};
    final rawFeatures = (json['features'] as Map?) ?? const {};
    rawFeatures.forEach((k, v) {
      final m = (v as Map?)?.cast<String, dynamic>() ?? const {};
      features[k.toString()] =
          FeatureAccess(canView: m['v'] == true, canWrite: m['w'] == true);
    });

    final routeFeature = <String, String>{};
    final rawRoutes = (json['routes'] as Map?) ?? const {};
    rawRoutes.forEach((k, v) {
      final m = (v as Map?)?.cast<String, dynamic>() ?? const {};
      final feature = (m['feature'] ?? '').toString();
      if (feature.isNotEmpty) routeFeature[k.toString()] = feature;
    });

    final tabs = <String, List<AccessTab>>{};
    final rawTabs = (json['tabs'] as Map?) ?? const {};
    rawTabs.forEach((screen, v) {
      tabs[screen.toString()] = ((v as List?) ?? const [])
          .whereType<Map>()
          .map((e) => AccessTab.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false);
    });

    String s(String k) => (json[k] ?? '').toString();
    return AccessMatrix(
      resolved: true,
      role: s('role'),
      isSuper: json['is_super'] == true,
      zoneLocked: json['zone_locked'] == true,
      zoneLabel: s('zone_label'),
      deniedViewMessage: s('denied_view_message'),
      deniedWriteMessage: s('denied_write_message'),
      readonlyBadge: s('readonly_badge'),
      features: features,
      routeFeature: routeFeature,
      tabs: tabs,
    );
  }

  /// May this login SEE the feature? An unknown key on a resolved matrix is
  /// off — a screen that never registered itself is not a screen anyone has.
  bool canView(String featureKey) {
    if (!resolved) return true;
    return (_features[featureKey] ?? FeatureAccess.off).canView;
  }

  /// May this login CHANGE anything on the feature? Write always implies View
  /// (the backend enforces that on the way in), so this is never true while
  /// [canView] is false.
  bool canWrite(String featureKey) {
    if (!resolved) return true;
    return (_features[featureKey] ?? FeatureAccess.off).canWrite;
  }

  /// The nav and the deep links speak in route keys; the registry maps each
  /// one to its feature. A route this build has never registered is left alone
  /// rather than hidden — hiding it would delete a destination the backend
  /// simply has not catalogued yet.
  bool routeCanView(String routeKey) {
    if (!resolved) return true;
    final feature = _routeFeature[routeKey];
    if (feature == null) return true;
    return canView(feature);
  }

  bool routeCanWrite(String routeKey) {
    if (!resolved) return true;
    final feature = _routeFeature[routeKey];
    if (feature == null) return true;
    return canWrite(feature);
  }

  String featureForRoute(String routeKey) => _routeFeature[routeKey] ?? '';

  /// The tabs of one screen, in payload order, each already carrying its own
  /// two booleans. The screen renders these — it never sorts or filters by a
  /// rule of its own.
  List<AccessTab> tabsFor(String screen) => _tabs[screen] ?? const [];

  /// CHANGE #657 — the `allowedTabs` set for a screen that is addressed by tab
  /// NUMBER (AdminFulfillmentScreen), derived from this login's own matrix.
  ///
  /// Null means UNBOUNDED, and it is returned in exactly two cases: the matrix
  /// has not resolved yet, or the backend granted View on every tab of the
  /// screen. Both are the state every full admin is in, so this never narrows
  /// an admin — it bounds only a login the backend has actually bounded.
  ///
  /// This exists because the fulfilment screen is the one container that does
  /// not gate its own tabs (the supplier and customer screens call
  /// [tabCanView] themselves). Opening it from the shared nav without this
  /// would hand every stage to a partner who was granted three.
  Set<int>? allowedTabIndexes(String screen) {
    if (!resolved) return null;
    final tabs = _tabs[screen] ?? const <AccessTab>[];
    if (tabs.isEmpty) return null;
    if (tabs.every((t) => t.canView)) return null;
    return tabs
        .where((t) => t.canView && t.index >= 0)
        .map((t) => t.index)
        .toSet();
  }

  /// The tab entry for one tab key, or null when the backend did not send it.
  AccessTab? tab(String screen, String tabKey) {
    for (final t in tabsFor(screen)) {
      if (t.tabKey == tabKey) return t;
    }
    return null;
  }

  /// A tab the payload never mentioned stays visible: the tab registry is data
  /// and may lag a new tab by one deploy. A tab it DID mention obeys its flag.
  bool tabCanView(String screen, String tabKey) {
    if (!resolved) return true;
    final t = tab(screen, tabKey);
    return t == null ? true : t.canView;
  }

  bool tabCanWrite(String screen, String tabKey) {
    if (!resolved) return true;
    final t = tab(screen, tabKey);
    return t == null ? true : t.canWrite;
  }
}

/// One tab of one screen, straight from `partner_screen_tab` + the matrix.
@immutable
class AccessTab {
  const AccessTab({
    required this.tabKey,
    required this.label,
    required this.featureKey,
    required this.canView,
    required this.canWrite,
    this.index = -1,
  });

  final String tabKey;
  final String label;
  final String featureKey;
  final bool canView;
  final bool canWrite;

  /// CHANGE #657 — `partner_screen_tab.tab_index`, the BACKEND's own position
  /// for this tab. The screens that take an `allowedTabs` set are addressed by
  /// number, and the number must come from the same table that grants the tab —
  /// a Dart-side list order would silently re-map a grant the day a tab moved.
  /// -1 when the payload did not send one.
  final int index;

  factory AccessTab.fromJson(Map<String, dynamic> json) => AccessTab(
        tabKey: (json['tab_key'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
        featureKey: (json['feature'] ?? '').toString(),
        canView: json['v'] == true,
        canWrite: json['w'] == true,
        index: (json['index'] is num) ? (json['index'] as num).toInt() : -1,
      );
}

/// The app-wide holder. One `access_boot()` per signed-in session.
class Access extends ChangeNotifier {
  Access._();

  static final Access instance = Access._();

  AccessMatrix _matrix = AccessMatrix.unresolved;
  AccessMatrix get matrix => _matrix;

  bool _loading = false;

  /// Test seam: a widget test hands the matrix straight in, no Supabase.
  @visibleForTesting
  void setMatrix(AccessMatrix m) {
    _matrix = m;
    notifyListeners();
  }

  /// Back to unresolved — called on sign-out so the next login never renders
  /// through the previous login's toggles.
  void clear() {
    if (!_matrix.resolved) return;
    _matrix = AccessMatrix.unresolved;
    notifyListeners();
  }

  /// Fetch the matrix. Safe to call more than once; a failure leaves the
  /// previous answer in place rather than blanking the shell.
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    try {
      final raw = await Supabase.instance.client.rpc('access_boot');
      final map = raw is List
          ? (raw.isEmpty ? null : (raw.first as Map).cast<String, dynamic>())
          : (raw as Map?)?.cast<String, dynamic>();
      final next = AccessMatrix.fromJson(map);
      if (next.resolved) {
        _matrix = next;
        notifyListeners();
      }
    } catch (_) {
      // Boot resilience: an access_boot that fails must not stop the app.
      // The matrix stays where it was and every RPC still enforces itself.
    } finally {
      _loading = false;
    }
  }

  // ── Convenience, so a widget reads one short line. ───────────────────────
  bool canView(String featureKey) => _matrix.canView(featureKey);
  bool canWrite(String featureKey) => _matrix.canWrite(featureKey);
  bool routeCanView(String routeKey) => _matrix.routeCanView(routeKey);
  bool routeCanWrite(String routeKey) => _matrix.routeCanWrite(routeKey);
  bool tabCanView(String screen, String tabKey) =>
      _matrix.tabCanView(screen, tabKey);
  bool tabCanWrite(String screen, String tabKey) =>
      _matrix.tabCanWrite(screen, tabKey);
  Set<int>? allowedTabIndexes(String screen) =>
      _matrix.allowedTabIndexes(screen);
  String get deniedViewMessage => _matrix.deniedViewMessage;
  String get deniedWriteMessage => _matrix.deniedWriteMessage;
  String get readonlyBadge => _matrix.readonlyBadge;
  bool get isSuper => _matrix.isSuper;
}
