// CHANGE #342: shared tap-icon widget for voice mention rows (Shop/Warehouse/Pack).
// Replaces the #338 hold gesture entirely — one tap = delete or re-add.
import 'package:flutter/material.dart';

// Tap icon shown left of the qty chip on every mention row.
// status 'deleted' → green add icon; else → red remove icon.
// frozen → 40% opacity, tap logs c342_frozen_tap but does nothing else.
// isBusy → 16px spinner in icon position (prevents double-tap via parent busy flag).
class MentionActionIcon extends StatelessWidget {
  final String status;
  final bool isBusy;
  final bool frozen;
  final VoidCallback? onTap; // null when frozen or busy is handled by parent

  const MentionActionIcon({
    super.key,
    required this.status,
    this.isBusy = false,
    this.frozen = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (isBusy) {
      return const SizedBox(
        width: 34,
        height: 34,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFF1B7A43),
            ),
          ),
        ),
      );
    }

    final isDeleted = status == 'deleted';
    final icon = isDeleted
        ? Icons.add_circle_outline
        : Icons.remove_circle_outline;
    final color = isDeleted
        ? const Color(0xFF1B7A43) // app primary green
        : const Color(0xFFDC2626); // app danger red

    Widget child = InkWell(
      onTap: frozen ? null : onTap,
      borderRadius: BorderRadius.circular(18),
      splashColor: isDeleted
          ? const Color(0xFF1B7A43).withValues(alpha: 0.12)
          : const Color(0xFFDC2626).withValues(alpha: 0.12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        child: Padding(
          padding: EdgeInsets.zero,
          child: Center(
            child: Semantics(
              label: isDeleted ? 'Re-add count' : 'Remove count',
              child: Icon(icon, size: 22, color: frozen ? color.withValues(alpha: 0.4) : color),
            ),
          ),
        ),
      ),
    );

    return child;
  }
}

