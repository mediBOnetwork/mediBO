// CHANGE #342: shared tap-icon widget for voice mention rows (Shop/Warehouse/Pack).
// Replaces the #338 hold gesture entirely — one tap = delete or re-add.
//
// CHANGE #531: the icon/colour/semantics no longer fork on `status == 'deleted'`.
// get_voice_clip_mentions / get_pack_clip_mentions already return the finished
// values, so they are read verbatim:
//   • is_complete    -> which glyph (a live count can be removed, a removed one
//                       can be added back)
//   • status_colors  -> {bg,fg}; fg is the glyph colour
//   • status_label   -> the accessibility label
// frozen → 40% opacity, tap logs c342_frozen_tap but does nothing else.
// isBusy → 16px spinner in icon position (prevents double-tap via parent busy flag).
import 'package:flutter/material.dart';

/// '#RRGGBB' / '#AARRGGBB' -> Color. Fallback is a COLOUR only — never copy.
Color _hexColor(String? hex, Color fallback) {
  if (hex == null || hex.isEmpty) return fallback;
  final h = hex.startsWith('#') ? hex.substring(1) : hex;
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? fallback : Color(v);
}

class MentionActionIcon extends StatelessWidget {
  /// get_voice_clip_mentions / get_pack_clip_mentions `is_complete`.
  final bool isComplete;

  /// `status_colors` as returned: {bg,fg}.
  final Map? statusColors;

  /// `status_label`, printed verbatim as the semantics label.
  final String? statusLabel;

  final bool isBusy;
  final bool frozen;
  final VoidCallback? onTap; // null when frozen or busy is handled by parent

  const MentionActionIcon({
    super.key,
    required this.isComplete,
    this.statusColors,
    this.statusLabel,
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

    // Backend-owned. A complete (counted/re-added) mention offers "remove"; an
    // incomplete one (removed / merged / needs-bag) offers "add back".
    final icon = isComplete
        ? Icons.remove_circle_outline
        : Icons.add_circle_outline;
    final color = _hexColor(
        statusColors?['fg']?.toString(), const Color(0xFF5A5A57));

    Widget child = InkWell(
      onTap: frozen ? null : onTap,
      borderRadius: BorderRadius.circular(18),
      splashColor: color.withValues(alpha: 0.12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        child: Padding(
          padding: EdgeInsets.zero,
          child: Center(
            child: Semantics(
              label: statusLabel,
              child: Icon(icon, size: 22, color: frozen ? color.withValues(alpha: 0.4) : color),
            ),
          ),
        ),
      ),
    );

    return child;
  }
}
