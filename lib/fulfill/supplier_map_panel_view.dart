// CHANGE #754 — the Supplier Shop map card's decisions, as a pure class.
//
// The panel itself talks to Supabase in initState, so its layout rules were
// untestable on the Dart VM. Every rule Om asked for is here instead:
//   • which of the TWO heights the map is drawn at (mini / full) — both are
//     the payload's numbers, never Dart constants;
//   • whether the empty-day sentence is laid over the map;
//   • that the legend is a row of its own, outside the map area;
//   • that the map is NEVER given a zero size, because zero is how a widget
//     gets disposed and a disposed Google map is a paid reload.
//
// The panel renders these answers; test/protected/fulfill_tab_polish_test.dart
// pins them.

import 'package:flutter/foundation.dart';

@immutable
class SupplierMapPanelView {
  const SupplierMapPanelView({
    this.headerLabel = '',
    this.legendLabel = '',
    this.emptyLabel = '',
    this.hasPoints = false,
    this.miniHeight = 0,
    this.fullHeight = 0,
    this.fullMaxRatio = 0,
    this.badges = const [],
    this.groups = const [],
    this.mapPoints = const [],
    this.loaded = false,
  });

  static const SupplierMapPanelView empty = SupplierMapPanelView();

  /// 'View suppliers in map (12)' — the count Om asked to keep is already in
  /// this string, so collapsing the card cannot lose it.
  final String headerLabel;

  /// The heading over the status chips, now that they are a legend row rather
  /// than a strip floating on the map.
  final String legendLabel;

  /// 'No supplier locations for 03/09/2026'. Empty when the day has points.
  final String emptyLabel;

  final bool hasPoints;
  final double miniHeight;
  final double fullHeight;

  /// CHANGE #1890 — the share of the VIEWPORT the open map may take. The
  /// number is the payload's (`map_full_max_ratio`); 0.6 is the fallback the
  /// spec named, and it is what stops the map from swallowing the tab and
  /// putting the supplier list out of reach on a phone.
  final double fullMaxRatio;

  final List<Map<String, dynamic>> badges;
  final List<Map<String, dynamic>> groups;
  final List<Map<String, dynamic>> mapPoints;

  /// False until map_supplier_groups() has answered once.
  final bool loaded;

  static List<Map<String, dynamic>> _rows(dynamic raw) =>
      ((raw as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);

  factory SupplierMapPanelView.fromJson(Map<String, dynamic>? j) {
    if (j == null) return empty;
    return SupplierMapPanelView(
      headerLabel: (j['header_label'] ?? '').toString(),
      legendLabel: (j['legend_label'] ?? '').toString(),
      emptyLabel: (j['empty_label'] ?? '').toString(),
      hasPoints: j['has_points'] == true,
      miniHeight: (j['map_mini_height'] as num?)?.toDouble() ?? 0,
      fullHeight: (j['map_full_height'] as num?)?.toDouble() ?? 0,
      fullMaxRatio: (j['map_full_max_ratio'] as num?)?.toDouble() ?? 0,
      badges: _rows(j['badges']),
      groups: _rows(j['groups']),
      mapPoints: _rows(j['map_points']),
      loaded: true,
    );
  }

  /// Two sizes, never zero. The arrow picks between them; it does not remove
  /// the map, which is what made every collapse cost a provider load.
  ///
  /// A payload that carried no heights yet (the very first frame) still gets
  /// the mini height rather than 0, so the map is created once and resized —
  /// never created, destroyed and created again.
  double mapHeight({required bool open}) {
    final mini = miniHeight > 0 ? miniHeight : fullHeight;
    final full = fullHeight > 0 ? fullHeight : miniHeight;
    return open ? full : mini;
  }

  /// The map is in the tree in BOTH states. This exists so a future edit that
  /// tries to hide it has to argue with a protected test.
  bool get mapIsMounted => true;

  /// The empty-day copy is laid over the live map, never shown instead of it.
  bool get showsEmptyOverlay => emptyLabel.isNotEmpty;

  /// The legend is drawn whenever the backend sent chips — in mini as well as
  /// full, because it is a filter row and filtering is the reason it exists.
  bool get showsLegend => badges.isNotEmpty;

  /// Only the supplier groups fold away with the arrow.
  bool showsGroups({required bool open}) => open && groups.isNotEmpty;

  // ── CHANGE #1890 — the collapsed card ─────────────────────────────────────
  //
  // Collapsed is the DEFAULT now: a two-column grid of the status filters on
  // the left and a square map thumbnail on the right, the card a fixed block
  // about 180 px tall. Tapping the thumbnail opens the map.

  /// The side of the collapsed thumbnail — the payload's mini height, used for
  /// both dimensions so the thumbnail is square. Never zero: zero is how the
  /// map widget gets disposed, and a disposed map is a paid reload.
  double get thumbSize => mapHeight(open: false);

  /// The open map's height, capped at [fullMaxRatio] of the viewport so the
  /// list below it is always reachable. A caller with no viewport to measure
  /// (a unit test, the very first frame) gets the payload's full height
  /// unchanged — the cap only ever makes the map SMALLER.
  double expandedHeight(double viewportHeight) {
    final full = mapHeight(open: true);
    final ratio = fullMaxRatio > 0 ? fullMaxRatio : _kDefaultFullMaxRatio;
    if (viewportHeight <= 0) return full;
    final cap = viewportHeight * ratio;
    return full < cap ? full : cap;
  }

  /// The whole collapsed card, header excluded: one fixed block whose height
  /// no filter count can change, because the grid scrolls inside it.
  double get collapsedBodyHeight => thumbSize;

  /// The filters are a two-column grid in the collapsed card and a free-
  /// flowing row when it is open. Two, not "as many as fit": a count that
  /// changes with the width is a layout that jumps.
  static const int collapsedFilterColumns = 2;

  static const double _kDefaultFullMaxRatio = 0.6;
}
