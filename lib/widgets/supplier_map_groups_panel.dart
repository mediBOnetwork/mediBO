// Admin Supplier Shop tab — "View suppliers in map" dropdown.
//
// map_supplier_groups() RPC is the single source of truth: every badge/chip
// tap re-calls it with updated params and this widget renders exactly what
// comes back — no client-side filtering, sorting, grouping, colour/label
// derivation, header building, or count computation happens in Dart. Local
// state is limited to the three RPC params plus purely-visual UI state
// (dropdown open/closed) — never used to filter what's rendered.
//
// Purely additive: mounted above the existing Supplier Shop list in
// admin_fulfillment_screen.dart; does not touch that list, the Warehouse
// tab, or any other screen.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../screens/admin/admin_customer_screen.dart' show AdminCustomerScreen;
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

class _SupplierMapGroupsPanelState extends State<SupplierMapGroupsPanel> {
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
            ? 'Optimizing routes — check the Customer → Route tab for progress.'
            : 'Open the Customer → Route tab once first, then try again.',
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
    final headerLabel = _data?['header_label']?.toString() ?? 'View suppliers in map';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              const Icon(Icons.map_outlined, size: 18, color: Color(0xFF1B7A43)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(headerLabel,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
              if (_loading) ...[
                const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)),
                ),
                const SizedBox(width: 10),
              ],
              AnimatedRotation(
                turns: _open ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeInOutCubic,
                child: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF6B7280)),
              ),
            ]),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOutCubic,
          clipBehavior: Clip.antiAlias,
          child: (_open && _data != null) ? _buildBody(_data!) : const SizedBox.shrink(),
        ),
      ]),
    );
  }

  Widget _buildBody(Map<String, dynamic> data) {
    final badges = ((data['badges'] as List?) ?? [])
        .map((b) => Map<String, dynamic>.from(b as Map))
        .toList();
    final mapPoints = ((data['map_points'] as List?) ?? [])
        .map((p) => Map<String, dynamic>.from(p as Map))
        .toList();
    final mapCenter = data['map_center'] as Map?;
    final groups = ((data['groups'] as List?) ?? [])
        .map((g) => Map<String, dynamic>.from(g as Map))
        .toList();
    final activeChip = data['active_chip']?.toString();
    final activeChipComplex = data['active_chip_complex']?.toString();

    return ValueListenableBuilder<bool>(
      valueListenable: _mapTouchLock,
      builder: (_, locked, child) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 620),
        child: SingleChildScrollView(
          physics: locked ? const NeverScrollableScrollPhysics() : null,
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: child,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: badges.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) => _badgePill(badges[i]),
          ),
        ),
        const SizedBox(height: 12),
        _SupplierPointsMap(center: mapCenter, points: mapPoints, touchLock: _mapTouchLock),
        const SizedBox(height: 12),
        for (final g in groups) _buildGroup(g, activeChip, activeChipComplex),
      ]),
    );
  }

  Widget _badgePill(Map<String, dynamic> badge) {
    final selected = badge['selected'] == true;
    final bg = _hexColor(badge['fill']?.toString(), const Color(0xFFF3F4F6));
    final fg = _hexColor(badge['fg']?.toString(), const Color(0xFF374151));
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _onTapBadge(badge),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? fg : Colors.transparent, width: 2),
        ),
        child: Center(
          child: Text(badge['text']?.toString() ?? '',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
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
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() {
            if (open) {
              _openGroups.remove(key);
            } else {
              _openGroups.add(key);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Expanded(
                child: Text(g['header']?.toString() ?? '',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              AnimatedRotation(
                turns: open ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOutCubic,
                child: const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: Color(0xFF6B7280)),
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
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(
                      spacing: 8, runSpacing: 8,
                      children: chips.map((c) => _chipPill(key, c, activeChip, activeChipComplex)).toList(),
                    ),
                    const SizedBox(height: 10),
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
      borderRadius: BorderRadius.circular(16),
      onTap: () => _onTapChip(groupKey, chip),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1B7A43) : const Color(0xFFF1F3F4),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(chip['label']?.toString() ?? '',
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600,
                color: selected ? Colors.white : const Color(0xFF374151))),
      ),
    );
  }

  Widget _supplierRow(Map<String, dynamic> s) {
    final dot = (s['dot_packed'] as Map?) ?? {};
    final fill = _hexColor(dot['fill']?.toString(), const Color(0xFFD1D5DB));
    final border = _hexColor(dot['border']?.toString(), const Color(0xFF9CA3AF));
    final shopLabel = s['shop_label']?.toString() ?? '';
    final supplier = s['supplier']?.toString() ?? '';
    final address = s['address']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 10, height: 10,
          margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fill,
            border: Border.all(color: border, width: 1.5),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$shopLabel  $supplier'.trim(),
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
            if (address.isNotEmpty) ...[
              const SizedBox(height: 1),
              Text(address, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            ],
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
  const _SupplierPointsMap({
    required this.center,
    required this.points,
    required this.touchLock,
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
      _iconCache[hex] = await _dotMarkerIcon(_hexColor(hex, const Color(0xFF1B7A43)));
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
        fallbackColor: _hexColor(hex, const Color(0xFF1B7A43)),
        title: p['supplier']?.toString() ?? '',
      ));
    }

    // A7 — no plotted suppliers: AdaptiveMap prints map_config.empty_label
    // instead of a blank grey map. No copy is written in this file.
    return AdaptiveMap(
      pins: pins,
      center: (centerLat != null && centerLng != null)
          ? MapPoint(centerLat, centerLng)
          : null,
      cameraSignature: '${pins.length}|$centerLat,$centerLng',
      height: 320,
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      touchLock: widget.touchLock,
      logKey: 'c634_supplier_map',
    );
  }
}
