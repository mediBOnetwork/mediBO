// CMD #1947 — the staff header's date·zone chip, BINDING half.
//
// One chip in the header row replaces the old second row of filters. Tapping it
// opens a bottom sheet holding the two controls that already existed: the
// calendar (AdminCalendarBody) and the zone list (ScopeZoneList). Selecting
// writes through the unchanged RPCs — admin_set_date_scope /
// admin_set_zone_scope, via AdminDateScope / AdminZoneScope — so every
// date- and zone-scoped tab refetches exactly as it does today.
//
// The split mirrors admin_zone_picker.dart / zone_picker_view.dart: everything
// touching Supabase and RenderLog lives here, so the view stays unit-testable.
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/admin_date_scope.dart';
import '../services/admin_scope_chip.dart';
import '../services/admin_zone_scope.dart';
import '../utils/render_log.dart';
import 'admin_date_picker.dart';
import 'scope_chip_view.dart';

class ScopeChip extends StatefulWidget {
  /// Web's <1000 px form: calendar icon + the backend's compact_label only.
  final bool compact;

  /// Hard ceiling so the chip gives way before the centred logo does.
  final double? maxWidth;

  const ScopeChip({super.key, this.compact = false, this.maxWidth});

  @override
  State<ScopeChip> createState() => _ScopeChipState();
}

class _ScopeChipState extends State<ScopeChip> {
  @override
  void initState() {
    super.initState();
    AdminScopeChip.instance.addListener(_onChip);
    AdminScopeChip.instance.ensureLoaded();
    // The sheet renders both pickers from the chip payload, but the WRITES go
    // through these two, and every other tab listens to them.
    AdminDateScope.instance.ensureLoaded();
    AdminZoneScope.instance.ensureLoaded();
  }

  @override
  void dispose() {
    AdminScopeChip.instance.removeListener(_onChip);
    super.dispose();
  }

  void _onChip() {
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    final payload = AdminScopeChip.instance.payload;
    if (payload['show'] != true) return;
    RenderLog.write('c1947_scope_sheet_open', 1);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (sheetContext) => _ScopeSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chip = AdminScopeChip.instance;
    RenderLog.write('c1947_scope_chip',
        'show=${chip.show};compact=${widget.compact};label=${chip.payload['label'] ?? ''}');
    return ScopeChipView(
      payload: chip.payload,
      compact: widget.compact,
      maxWidth: widget.maxWidth,
      onTap: _open,
    );
  }
}

/// The sheet. Rebuilds itself on every scope move so the tick and the chip
/// text follow the backend without the sheet being closed and reopened.
class _ScopeSheet extends StatefulWidget {
  @override
  State<_ScopeSheet> createState() => _ScopeSheetState();
}

class _ScopeSheetState extends State<_ScopeSheet> {
  @override
  void initState() {
    super.initState();
    AdminScopeChip.instance.addListener(_onChip);
  }

  @override
  void dispose() {
    AdminScopeChip.instance.removeListener(_onChip);
    super.dispose();
  }

  void _onChip() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final payload = AdminScopeChip.instance.payload;
    final zone = payload['zone'] is Map
        ? Map<String, dynamic>.from(payload['zone'] as Map)
        : const <String, dynamic>{};
    final dateBlock = payload['date'] is Map
        ? Map<String, dynamic>.from(payload['date'] as Map)
        : const <String, dynamic>{};
    final calendar = dateBlock['calendar'] is List
        ? (dateBlock['calendar'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];
    final media = MediaQuery.of(context);
    final maxSheet = media.size.height * 0.85;
    final calWidth = media.size.width - Ds.space.x32;
    final calHeight = (maxSheet * 0.55).clamp(Ds.space.x48 * 4, 372.0);

    RenderLog.write('c1947_scope_sheet', 'zone_options=${(zone['options'] is List) ? (zone['options'] as List).length : 0}');

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxSheet),
      child: SingleChildScrollView(
        child: ScopeSheetView(
          payload: payload,
          dateChild: AdminCalendarBody(
            calendar: calendar,
            width: calWidth,
            height: calHeight,
            onPick: (iso) async {
              await AdminDateScope.instance.select(iso);
              await AdminScopeChip.instance.refresh();
            },
          ),
          zoneChild: ScopeZoneList(
            zone: zone,
            onSelect: (zoneId) async {
              await AdminZoneScope.instance.select(zoneId);
              await AdminScopeChip.instance.refresh();
            },
          ),
          onDone: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}
