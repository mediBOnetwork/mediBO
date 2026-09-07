// Admin Supplier Shop tab — "View suppliers in map" dropdown.
//
// map_supplier_groups() RPC is the single source of truth: every badge/chip
// tap re-calls it with updated params and this widget renders exactly what
// comes back — no client-side filtering, sorting, grouping, colour/label
// derivation, header building, or count computation happens in Dart. Local
// state is limited to the three RPC params plus purely-visual UI state
// (dropdown open/closed) — never used to filter what's rendered.
//
// CHANGE #754 — three fixes, all of them "stop deciding in Dart":
//   • The card is PINNED at the top of the Supplier Shop tab and is ONE widget
//     instance for the life of the tab. It used to be three separate
//     `const SupplierMapGroupsPanel()`s in three build branches (empty day /
//     list / wide), so an empty day, a filter that matched nothing or a
//     viewport change threw the map away and paid for a fresh provider load.
//   • Two sizes, never zero: the header arrow toggles mini <-> full, both from
//     the payload's own `map_mini_height` / `map_full_height`. The body is
//     never swapped for a SizedBox.shrink() — that disposes the map.
//   • The status chips are a legend/filter row BELOW the map instead of a
//     strip inside the map area, and an empty day writes the backend's
//     `empty_label` OVER the live map rather than in the middle of the tab.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../fulfill/supplier_map_panel_view.dart';
import '../screens/admin/admin_customer_screen.dart' show AdminCustomerScreen;
import '../services/admin_date_scope.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';
import 'adaptive_map.dart';

// Parses a backend-supplied "#RRGGBB" (or "RRGGBB") hex colour string.
// Pure format conversion — Flutter needs a Color object, the RPC gives a
// string; no colour/state decision is made here.
Color _hexColor(String? hex, Color fallback) {
  if (hex == null || hex.isEmpty) return fallback;
  final h = hex.startsWith('#') ? hex.substring(1) : hex;
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? fallback : Color(v);
}

class SupplierMapGroupsPanel extends StatefulWidget {
  const SupplierMapGroupsPanel({super.key});

  @override
  State<SupplierMapGroupsPanel> createState() => _SupplierMapGroupsPanelState();
}

class _SupplierMapGroupsPanelState extends State<SupplierMapGroupsPanel>
    with AutomaticKeepAliveClientMixin {
  /// CHANGE #754 — the tab this card sits on is a page of an IndexedStack, and
  /// a lazily-built list can still deactivate a subtree. Keeping alive is what
  /// makes "one map for the life of the screen" true rather than aspirational.
  @override
  bool get wantKeepAlive => true;

  bool _open = false;
  bool _loading = false;
  Map<String, dynamic>? _data;

  // ONLY three nullable vars, used purely as RPC params — never for local
  // filtering. The rendered content always comes from the last RPC response.
  String? _selectedBadge;
  String? _selectedChipKey;
  String? _selectedChipComplex;

  // Group-open/closed is local UI state (not sent to the backend); kept by
  // group key so it survives a re-fetch instead of collapsing on every tap.
  final Set<String> _openGroups = {};

  final ValueNotifier<bool> _mapTouchLock = ValueNotifier<bool>(false);

  /// CHANGE #1890 — the collapsed card puts the map in a Row (thumbnail on the
  /// right of the filter grid) and the open card puts it in a Column (filters
  /// above, map below). Those are different positions in the tree, and a
  /// different position means a new State — which is exactly the paid Google
  /// Maps reload #754 removed. A GlobalKey reparents the SAME element between
  /// the two, so the map is still created once for the life of the tab.
  final GlobalKey _mapKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _load();
    // The card outlives every date change now, so it has to hear about them
    // itself — it used to be remounted into a fresh _load() by accident.
    AdminDateScope.instance.addListener(_onScopeChanged);
  }

  void _onScopeChanged() {
    if (mounted) _load();
  }

  @override
  void dispose() {
    AdminDateScope.instance.removeListener(_onScopeChanged);
    _mapTouchLock.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // CHANGE #545: p_date OMITTED — map_supplier_groups defaults it to
      // admin_active_date(), the one Dashboard picker's date. Never send it as
      // an explicit null. Every other param is unchanged.
      final res = await Supabase.instance.client.rpc('map_supplier_groups', params: {
        'p_badge': _selectedBadge,
        'p_chip_key': _selectedChipKey,
        'p_chip_complex': _selectedChipComplex,
      }).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _data = Map<String, dynamic>.from(res as Map);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _onTapBadge(Map<String, dynamic> badge) {
    if (badge['is_action'] == true) {
      // Action, not a filter — reuse the Route tab's own optimize-all flow
      // verbatim, don't re-call this RPC and don't reimplement routing.
      final triggered = AdminCustomerScreen.triggerOptimizeAllRoutes();
      showToast(
        context,
        triggered
            ? c('supplier_map_groups.toast_optimizing')
            : c('supplier_map_groups.toast_open_route_tab_first'),
        isError: !triggered,
      );
      return;
    }
    final filterKey = badge['filter_key']?.toString();
    setState(() => _selectedBadge = (_selectedBadge == filterKey) ? null : filterKey);
    _load();
  }

  void _onTapChip(String groupKey, Map<String, dynamic> chip) {
    final chipKey = chip['key']?.toString();
    setState(() {
      if (_selectedChipKey == chipKey && _selectedChipComplex == groupKey) {
        _selectedChipKey = null;
        _selectedChipComplex = null;
      } else {
        _selectedChipKey = chipKey;
        _selectedChipComplex = groupKey;
      }
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    // Every layout answer on this card is [SupplierMapPanelView]'s, which is
    // where the protected test can reach them without a network.
    final v = SupplierMapPanelView.fromJson(_data);

    RenderLog.write('c754_map_pinned', _open ? 'full' : 'mini');
    // CHANGE #1890 — what the card actually drew, so a regression to the old
    // full-height-by-default card shows up in the render-log.
    RenderLog.write('c1890_map_card', _open ? 'expanded' : 'collapsed');
    RenderLog.write('c1890_map_filter_cols',
        '${SupplierMapPanelView.collapsedFilterColumns}');

    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _header(v.headerLabel),
        // ── The map. ONE instance, always in the tree, two layouts. ────────
        // It is deliberately NOT inside the AnimatedSize below: animating a
        // child in and out is what disposed the map on every collapse.
        //
        // CHANGE #1890 — collapsed is the DEFAULT, and collapsed is a fixed
        // block: the status filters in a two-column grid on the left, a square
        // map thumbnail on the right. Tap the thumbnail and the card opens —
        // filters above, map below, capped at the payload's share of the
        // viewport so the supplier list underneath is never pushed off screen.
        if (v.loaded) (_open ? _openBody(v) : _collapsedBody(v)),
        // Only the supplier groups fold away with the arrow.
        AnimatedSize(
          duration: Ds.motion.standard,
          curve: Ds.motion.curve,
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.topCenter,
          child: v.showsGroups(open: _open)
              ? _groupList(v)
              : SizedBox(width: double.infinity, height: Ds.space.x12),
        ),
      ]),
    );
  }

  // ── CHANGE #1890 — collapsed: filters left, map thumbnail right ───────────
  //
  // The card is a fixed block (the thumbnail's own height plus the header), so
  // a day with five filters and a day with two are the same size and the list
  // below never moves. The grid scrolls inside that block rather than growing
  // it, which is what keeps every pill a full 44 px tap target.
  Widget _collapsedBody(SupplierMapPanelView v) {
    return Padding(
      padding:
          EdgeInsets.fromLTRB(Ds.space.x12, 0, Ds.space.x12, Ds.space.x12),
      child: SizedBox(
        // Tall enough for EVERY filter the backend sent, never shorter than
        // the thumbnail. The first cut sized this block to the thumbnail alone
        // and "Optimize route" — the fifth filter, and the only one that is an
        // action — was clipped below the fold of a 120 px scroller. A filter
        // you have to discover by scrolling a postage stamp is a filter that
        // is not there.
        height: _collapsedBodyHeight(v),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Capped, and left-aligned: stretched across a 1100 px desktop these
          // saturated pills read as decorative colour blocks rather than
          // filters (Om's design rules: no decorative multi-colour fills).
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: Ds.space.x48 * 8),
                child: _filterGrid(v.badges),
              ),
            ),
          ),
          SizedBox(width: Ds.space.x12),
          _mapThumb(v),
        ]),
      ),
    );
  }

  /// Open: the filters get the full width above, the map the full width below,
  /// and the map is capped at the payload's share of the viewport. It is the
  /// SAME map widget as the thumbnail — the GlobalKey moves it here rather
  /// than building a second one.
  Widget _openBody(SupplierMapPanelView v) {
    final viewport = MediaQuery.of(context).size.height;
    return Padding(
      padding:
          EdgeInsets.fromLTRB(Ds.space.x12, 0, Ds.space.x12, Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (v.showsLegend) ...[
          if (v.legendLabel.isNotEmpty) ...[
            Text(v.legendLabel, style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
          ],
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [for (final b in v.badges) _badgePill(b)],
          ),
          SizedBox(height: Ds.space.x8),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: Text(c('supplier_map_groups.collapse_hint'),
              style: Ds.t.caption),
        ),
        SizedBox(height: Ds.space.x8),
        _SupplierPointsMap(
          key: _mapKey,
          center: _data?['map_center'] as Map?,
          points: v.mapPoints,
          touchLock: _mapTouchLock,
          height: v.expandedHeight(viewport),
          emptyLabel: v.emptyLabel,
        ),
      ]),
    );
  }

  /// One grid row per pair of filters, each a full tap target, plus the gap
  /// between them — or the thumbnail's height, whichever is larger.
  double _collapsedBodyHeight(SupplierMapPanelView v) {
    final rowH = Ds.touch.minTarget + Ds.space.x8;
    final rows =
        (v.badges.length + SupplierMapPanelView.collapsedFilterColumns - 1) ~/
            SupplierMapPanelView.collapsedFilterColumns;
    final grid = rows == 0 ? 0.0 : rows * rowH - Ds.space.x8;
    return grid > v.collapsedBodyHeight ? grid : v.collapsedBodyHeight;
  }

  /// The status filters as a strict two-column grid. Two columns, not "as many
  /// as fit": a column count that changes with the width is a layout that
  /// jumps every time the phone rotates.
  Widget _filterGrid(List<Map<String, dynamic>> badges) {
    if (badges.isEmpty) return const SizedBox.shrink();
    const cols = SupplierMapPanelView.collapsedFilterColumns;
    final rows = <Widget>[];
    for (var i = 0; i < badges.length; i += cols) {
      final cells = <Widget>[];
      for (var col = 0; col < cols; col++) {
        if (col > 0) cells.add(SizedBox(width: Ds.space.x8));
        final idx = i + col;
        cells.add(Expanded(
          child: idx < badges.length
              ? _badgePill(badges[idx])
              : const SizedBox.shrink(),
        ));
      }
      rows.add(Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x8),
        child: Row(children: cells),
      ));
    }
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    );
  }

  /// The collapsed thumbnail: a square of the payload's mini height, with a
  /// transparent tap layer over it so a tap OPENS the card instead of panning
  /// a map the size of a postage stamp.
  Widget _mapThumb(SupplierMapPanelView v) {
    final side = v.thumbSize;
    return Tooltip(
      message: c('supplier_map_groups.expand_hint'),
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(children: [
          // IgnorePointer, and it is the whole reason the tap works.
          //
          // Measured on the live build: a GestureDetector laid OVER the
          // thumbnail never fired, while the card header's InkWell right above
          // it did. The map draws its own pan/tap recognisers, and in the
          // gesture arena they were taking the pointer. A postage-stamp map
          // has nothing to pan anyway, so collapsed it takes no pointers at
          // all and the tap layer below is the only claimant.
          Positioned.fill(
            child: IgnorePointer(
              child: _SupplierPointsMap(
                key: _mapKey,
                center: _data?['map_center'] as Map?,
                points: v.mapPoints,
                touchLock: _mapTouchLock,
                height: side,
                emptyLabel: v.emptyLabel,
              ),
            ),
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = true),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x4, vertical: Ds.space.x4),
                  color: Ds.c.surface.withValues(alpha: 0.86),
                  child: Text(c('supplier_map_groups.expand_hint'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Ds.t.caption),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _header(String headerLabel) {
    return InkWell(
      borderRadius: Ds.r.rCard,
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        child: Row(children: [
          Icon(Icons.map_outlined, size: Ds.t.bodySize, color: Ds.c.brand),
          SizedBox(width: Ds.space.x8),
          Expanded(child: Text(headerLabel, style: Ds.t.bodyStrong)),
          if (_loading) ...[
            SizedBox(
              width: Ds.t.captionSize,
              height: Ds.t.captionSize,
              child: CircularProgressIndicator(strokeWidth: 2, color: Ds.c.brand),
            ),
            SizedBox(width: Ds.space.x8),
          ],
          AnimatedRotation(
            turns: _open ? 0.5 : 0.0,
            duration: Ds.motion.standard,
            curve: Ds.motion.curve,
            child: Icon(Icons.keyboard_arrow_down_rounded, color: Ds.c.textSecondary),
          ),
        ]),
      ),
    );
  }

  Widget _groupList(SupplierMapPanelView v) {
    final activeChip = _data?['active_chip']?.toString();
    final activeChipComplex = _data?['active_chip_complex']?.toString();
    return ValueListenableBuilder<bool>(
      valueListenable: _mapTouchLock,
      builder: (_, locked, child) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: Ds.space.x48 * 8),
        child: SingleChildScrollView(
          physics: locked ? const NeverScrollableScrollPhysics() : null,
          padding: EdgeInsets.fromLTRB(
              Ds.space.x12, 0, Ds.space.x12, Ds.space.x12),
          child: child,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final g in v.groups) _buildGroup(g, activeChip, activeChipComplex),
      ]),
    );
  }

  Widget _badgePill(Map<String, dynamic> badge) {
    final selected = badge['selected'] == true;
    final bg = _hexColor(badge['fill']?.toString(), Ds.c.bg);
    final fg = _hexColor(badge['fg']?.toString(), Ds.c.text);
    return InkWell(
      borderRadius: Ds.r.rChip,
      onTap: () => _onTapBadge(badge),
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: selected ? fg : Colors.transparent, width: 2),
        ),
        child: Center(
          child: Text(badge['text']?.toString() ?? '',
              style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700, color: fg)),
        ),
      ),
    );
  }

  Widget _buildGroup(Map<String, dynamic> g, String? activeChip, String? activeChipComplex) {
    final key = g['key']?.toString() ?? '';
    final open = _openGroups.contains(key);
    final chips = ((g['chips'] as List?) ?? [])
        .map((c) => Map<String, dynamic>.from(c as Map))
        .toList();
    final suppliers = ((g['suppliers'] as List?) ?? [])
        .map((s) => Map<String, dynamic>.from(s as Map))
        .toList();

    return Container(
      margin: EdgeInsets.only(top: Ds.space.x8),
      decoration: BoxDecoration(
        border: Border.all(color: Ds.c.divider),
        borderRadius: Ds.r.rButton,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: Ds.r.rButton,
          onTap: () => setState(() {
            if (open) {
              _openGroups.remove(key);
            } else {
              _openGroups.add(key);
            }
          }),
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x12),
            child: Row(children: [
              Expanded(
                child: Text(g['header']?.toString() ?? '',
                    style: Ds.t.caption.copyWith(
                        fontWeight: FontWeight.w700, color: Ds.c.text)),
              ),
              AnimatedRotation(
                turns: open ? 0.5 : 0.0,
                duration: Ds.motion.standard,
                curve: Ds.motion.curve,
                child: Icon(Icons.keyboard_arrow_down_rounded,
                    size: Ds.t.bodySize, color: Ds.c.textSecondary),
              ),
            ]),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOutCubic,
          clipBehavior: Clip.antiAlias,
          child: open
              ? Padding(
                  padding: EdgeInsets.fromLTRB(
                      Ds.space.x12, 0, Ds.space.x12, Ds.space.x12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(
                      spacing: Ds.space.x8, runSpacing: Ds.space.x8,
                      children: chips.map((c) => _chipPill(key, c, activeChip, activeChipComplex)).toList(),
                    ),
                    SizedBox(height: Ds.space.x8),
                    for (final s in suppliers) _supplierRow(s),
                  ]),
                )
              : const SizedBox.shrink(),
        ),
      ]),
    );
  }

  Widget _chipPill(
    String groupKey,
    Map<String, dynamic> chip,
    String? activeChip,
    String? activeChipComplex,
  ) {
    final selected = activeChip == chip['key']?.toString() && activeChipComplex == groupKey;
    return InkWell(
      borderRadius: Ds.r.rChip,
      onTap: () => _onTapChip(groupKey, chip),
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: selected ? Ds.c.brand : Ds.c.bg,
          borderRadius: Ds.r.rChip,
        ),
        child: Text(chip['label']?.toString() ?? '',
            style: Ds.t.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? Ds.c.surface : Ds.c.text)),
      ),
    );
  }

  Widget _supplierRow(Map<String, dynamic> s) {
    final dot = (s['dot_packed'] as Map?) ?? {};
    final fill = _hexColor(dot['fill']?.toString(), Ds.c.divider);
    final border = _hexColor(dot['border']?.toString(), Ds.c.textSecondary);
    final shopLabel = s['shop_label']?.toString() ?? '';
    final supplier = s['supplier']?.toString() ?? '';
    final address = s['address']?.toString() ?? '';
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: Ds.space.x8,
          height: Ds.space.x8,
          margin: EdgeInsets.only(top: Ds.space.x4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fill,
            border: Border.all(color: border),
          ),
        ),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$shopLabel  $supplier'.trim(),
                style: Ds.t.caption.copyWith(
                    fontWeight: FontWeight.w600, color: Ds.c.text)),
            if (address.isNotEmpty)
              Text(address, style: Ds.t.caption),
          ]),
        ),
      ]),
    );
  }
}

// ── Map ───────────────────────────────────────────────────────────────────
// CHANGE #634: draws through AdaptiveMap, so the provider and tile source come
// from map_config_get() exactly as they do for the Route tab and the delivery
// map. This file no longer names a map provider or carries an API key. The
// pins are unchanged — still one dot per map_supplier_groups().map_points row,
// in the pin_color the backend chose.
class _SupplierPointsMap extends StatefulWidget {
  final Map? center;
  final List<Map<String, dynamic>> points;
  final ValueNotifier<bool> touchLock;

  /// CHANGE #754 — `map_mini_height` or `map_full_height`, straight off the
  /// payload. Changing it RESIZES the one map; it never replaces it.
  final double height;

  /// CHANGE #754 — the backend's empty-day sentence, laid over the live map.
  /// Empty string means the day has points and nothing is overlaid.
  final String emptyLabel;

  const _SupplierPointsMap({
    super.key,
    required this.center,
    required this.points,
    required this.touchLock,
    required this.height,
    required this.emptyLabel,
  });

  @override
  State<_SupplierPointsMap> createState() => _SupplierPointsMapState();
}

class _SupplierPointsMapState extends State<_SupplierPointsMap> {
  final Map<String, Uint8List> _iconCache = {};

  @override
  void initState() {
    super.initState();
    _prepareIcons();
  }

  @override
  void didUpdateWidget(covariant _SupplierPointsMap old) {
    super.didUpdateWidget(old);
    _prepareIcons();
  }

  Future<void> _prepareIcons() async {
    final wanted = <String>{};
    for (final p in widget.points) {
      final hex = p['pin_color']?.toString();
      if (hex != null && hex.isNotEmpty) wanted.add(hex);
    }
    var changed = false;
    for (final hex in wanted) {
      if (_iconCache.containsKey(hex)) continue;
      _iconCache[hex] = await _dotMarkerIcon(_hexColor(hex, Ds.c.brand));
      changed = true;
    }
    if (mounted && changed) setState(() {});
  }

  Future<Uint8List> _dotMarkerIcon(Color color) async {
    const size = 40.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
    const center = Offset(size / 2, size / 2);
    canvas.drawCircle(center, size / 2 - 3, Paint()..color = color);
    canvas.drawCircle(
      center, size / 2 - 3,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final centerMap = widget.center;
    final centerLat = (centerMap?['lat'] as num?)?.toDouble();
    final centerLng = (centerMap?['lng'] as num?)?.toDouble();

    final pins = <MapPin>[];
    for (final p in widget.points) {
      final lat = (p['lat'] as num?)?.toDouble();
      final lng = (p['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final hex = p['pin_color']?.toString();
      pins.add(MapPin(
        id: 'supplier_${p['supplier']}_${lat}_$lng',
        lat: lat,
        lng: lng,
        iconBytes: hex != null ? _iconCache[hex] : null,
        iconWidth: 24,
        iconHeight: 24,
        tipAtPoint: false,
        fallbackColor: _hexColor(hex, Ds.c.brand),
        title: p['supplier']?.toString() ?? '',
      ));
    }

    // A7 — no plotted suppliers: the empty copy is shown instead of a blank
    // grey map. CHANGE #754 — it OVERLAYS rather than replaces, so the map is
    // never disposed on an empty day, and the sentence is the RPC's
    // `empty_label` (dated, IST) rather than the generic map_config one.
    return AdaptiveMap(
      pins: pins,
      center: (centerLat != null && centerLng != null)
          ? MapPoint(centerLat, centerLng)
          : null,
      cameraSignature: '${pins.length}|$centerLat,$centerLng',
      height: widget.height,
      borderRadius: Ds.r.rButton,
      touchLock: widget.touchLock,
      emptyOverlay: true,
      emptyState: widget.emptyLabel.isEmpty
          ? null
          : Center(
              child: Padding(
                padding: EdgeInsets.all(Ds.space.x16),
                child: Text(widget.emptyLabel,
                    textAlign: TextAlign.center, style: Ds.t.caption),
              ),
            ),
      logKey: 'c634_supplier_map',
    );
  }
}
