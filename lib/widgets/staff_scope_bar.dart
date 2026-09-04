import 'package:flutter/material.dart';
import '../design_tokens.dart';
import '../services/admin_date_scope.dart';
import '../services/admin_zone_scope.dart';
import '../services/staff_nav.dart';
import 'admin_date_picker.dart';
import 'admin_zone_picker.dart';
import 'offline_banner.dart';

/// CHANGE #1017 (1) — zone and date live ONCE, in the header, for every
/// staff tab. This is that header row: the backend's own scope labels, the two
/// pickers that already exist (they write through admin_zone_scope /
/// admin_date_scope exactly as before), and the offline banner beneath.
///
/// It reads `staff_nav().scope` and `staff_nav().copy` verbatim. A partner
/// (zone_locked) gets a static label, never a picker. After a change the nav
/// is re-read so the labels — and every scoped screen — follow the header.
class StaffScopeBar extends StatefulWidget {
  const StaffScopeBar({super.key, this.onScopeChanged});
  final VoidCallback? onScopeChanged;

  @override
  State<StaffScopeBar> createState() => _StaffScopeBarState();
}

class _StaffScopeBarState extends State<StaffScopeBar> {
  // The pickers write through the two scope services; this bar listens to
  // those, so a pick anywhere re-reads the nav and the labels follow.
  @override
  void initState() {
    super.initState();
    AdminZoneScope.instance.addListener(_changed);
    AdminDateScope.instance.addListener(_changed);
  }

  @override
  void dispose() {
    AdminZoneScope.instance.removeListener(_changed);
    AdminDateScope.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    StaffNav.load();
    widget.onScopeChanged?.call();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<StaffNavPayload>(
        valueListenable: StaffNav.value,
        builder: (context, nav, _) {
          if (!nav.ok || nav.isLegacy) return const SizedBox.shrink();
          final scope = nav.scope;
          final zoneLocked = scope['zone_locked'] == true;
          final canPickZone = scope['can_pick_zone'] == true;
          final canPickDate = scope['can_pick_date'] != false;
          final zoneLabel = (scope['zone_label'] ?? '').toString();
          final lockedLabel = (scope['zone_locked_label'] ?? '').toString();

          return Column(mainAxisSize: MainAxisSize.min, children: [
            Material(
              color: Ds.c.surface,
              child: Container(
                key: const Key('c1017_scope_bar'),
                height: Ds.touch.minTarget + Ds.space.x8,
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: Ds.c.divider)),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    if (canPickDate) const AdminDatePicker(key: Key('c1017_date_pick'), bare: true),
                    if (canPickDate) SizedBox(width: Ds.space.x8),
                    if (canPickZone && !zoneLocked)
                      const AdminZonePicker(key: Key('c1017_zone_pick'))
                    else if (zoneLabel.isNotEmpty)
                      // a partner's zone is a fact, not a choice
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: Ds.space.x12, vertical: Ds.space.x8),
                        decoration: BoxDecoration(color: Ds.c.brandSoft, borderRadius: Ds.r.rChip),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.place_outlined, size: Ds.space.x16, color: Ds.c.brand),
                          SizedBox(width: Ds.space.x4),
                          Text(zoneLabel, style: Ds.t.caption.copyWith(color: Ds.c.brand, fontWeight: FontWeight.w600)),
                          if (lockedLabel.isNotEmpty) ...[
                            SizedBox(width: Ds.space.x4),
                            Text('· $lockedLabel', style: Ds.t.caption),
                          ],
                        ]),
                      ),
                  ]),
                ),
              ),
            ),
            OfflineBanner(template: nav.copyOf('offline_banner')),
          ]);
        },
      );
}

/// CHANGE #1017 (7) — the preview banner. Only ever drawn when the backend
/// said `view_as.active`; its sentence and its exit label are the backend's.
class StaffPreviewBanner extends StatelessWidget {
  const StaffPreviewBanner({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<StaffNavPayload>(
        valueListenable: StaffNav.value,
        builder: (context, nav, _) {
          if (!nav.isPreview || nav.previewBanner.isEmpty) return const SizedBox.shrink();
          return Material(
            key: const Key('c1017_preview_banner'),
            color: Ds.c.infoSoft,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16, vertical: Ds.space.x8),
              child: Row(children: [
                Icon(Icons.visibility_outlined, size: Ds.space.x16 + Ds.space.x4, color: Ds.c.info),
                SizedBox(width: Ds.space.x8),
                Expanded(child: Text(nav.previewBanner, style: Ds.t.caption.copyWith(color: Ds.c.text), maxLines: 2, overflow: TextOverflow.ellipsis)),
                TextButton(
                  onPressed: () => StaffNav.preview(null),
                  child: Text(nav.previewExitLabel),
                ),
              ]),
            ),
          );
        },
      );
}
