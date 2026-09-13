import 'package:flutter/material.dart';
import '../design_tokens.dart';
import '../services/staff_nav.dart';
import '../utils/render_log.dart';
import 'offline_banner.dart';

/// CHANGE #1017 (1) → CMD #1947 — zone and date live ONCE for every staff tab,
/// and that one place is now the HEADER ROW itself: a single date·zone chip
/// (widgets/scope_chip.dart) sitting beside the logo on a phone and beside the
/// user menu on the web. The full-width second row this file used to draw —
/// AdminDatePicker + AdminZonePicker under the header, on every staff screen —
/// is gone with it; the two pickers moved into the chip's bottom sheet and
/// still write through admin_set_date_scope / admin_set_zone_scope exactly as
/// before, so every scoped tab follows the header as it always did.
///
/// What stays here is the row's other half: the offline banner, whose template
/// is staff_nav().copy — it is not a scope control and had nowhere else to go.
class StaffOfflineBanner extends StatelessWidget {
  const StaffOfflineBanner({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<StaffNavPayload>(
        valueListenable: StaffNav.value,
        builder: (context, nav, _) {
          if (!nav.ok || nav.isLegacy) return const SizedBox.shrink();
          RenderLog.write('c1947_scope_bar_removed', 1);
          return OfflineBanner(template: nav.copyOf('offline_banner'));
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
