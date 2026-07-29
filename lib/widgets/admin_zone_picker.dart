// CHANGE #609 — THE admin zone filter. One picker, beside the date picker.
//
// This file is the BINDING half: it wires the server-side zone scope to
// ZonePickerView (widgets/zone_picker_view.dart), which does the rendering.
// The split keeps the view free of dart:html so it stays unit-testable.
//
// The selection is server-side state, like the date. Nothing here caches a
// zone, and no screen is handed one — the order tabs refetch their own RPC,
// which applies the saved scope itself.
//
// Visual treatment matches AdminDatePicker deliberately: the two filters sit
// side by side and must read as one control pair.
import 'package:flutter/material.dart';

import '../services/admin_zone_scope.dart';
import '../utils/render_log.dart';
import 'zone_picker_view.dart';

/// Binds ZonePickerView to the server-side scope.
class AdminZonePicker extends StatefulWidget {
  /// Called after the backend confirmed a change, so a host screen can refetch.
  /// The zone itself is server-side state — nothing is passed.
  final VoidCallback? onChanged;

  const AdminZonePicker({super.key, this.onChanged});

  @override
  State<AdminZonePicker> createState() => _AdminZonePickerState();
}

class _AdminZonePickerState extends State<AdminZonePicker> {
  @override
  void initState() {
    super.initState();
    AdminZoneScope.instance.addListener(_onScope);
    AdminZoneScope.instance.ensureLoaded();
  }

  @override
  void dispose() {
    AdminZoneScope.instance.removeListener(_onScope);
    super.dispose();
  }

  void _onScope() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scope = AdminZoneScope.instance;
    RenderLog.write('c609_zone_picker',
        'show=${scope.show};can_change=${scope.canChange};label=${scope.selectedLabel}');
    return ZonePickerView(
      payload: {
        'show': scope.show,
        'can_change': scope.canChange,
        'title': scope.title,
        'selected_label': scope.selectedLabel,
        'options': scope.options,
      },
      onSelect: (zoneId) async {
        // null reaches the RPC as null.
        final ok = await AdminZoneScope.instance.select(zoneId);
        if (ok) widget.onChanged?.call();
      },
    );
  }
}
