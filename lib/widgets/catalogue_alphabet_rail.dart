import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_tokens.dart';
import '../models/catalogue.dart';

/// The A–Z index of a catalogue list.
///
/// CHANGE #799 built it as a rail down the right edge of the company list.
/// CMD #1908 turns it on its side: a HORIZONTAL strip that sits under the
/// breadcrumb on the company, salt and class lists — one component, three
/// screens, always in the same place, and never floating over the rows.
///
/// The track is EVERY letter the backend sent, always, with `enabled` saying
/// which ones have rows behind them. A track that grows and shrinks as the
/// list filters is a track nobody can learn the shape of.
///
/// It decides nothing: the letters, their order, their labels and the "All"
/// word all arrive in the payload's `rail`. Every child is built (a Row inside
/// one scroll view, not a lazy list) so the whole alphabet exists whether or
/// not it is on screen — the strip is an index, and an index you cannot reach
/// by scrolling to it is not one.
class CatalogueAlphabetRail extends StatelessWidget {
  final CatRail rail;

  /// The letter currently applied, or null for "All".
  final String? active;

  /// Called with the letter key, or null for "All".
  final ValueChanged<String?> onPick;

  const CatalogueAlphabetRail({
    super.key,
    required this.rail,
    required this.active,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    if (rail.letters.isEmpty) return const SizedBox.shrink();

    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Semantics(
        label: rail.label,
        child: SizedBox(
          height: Ds.touch.minTarget,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            child: Row(
              children: [
                if (rail.allLabel.isNotEmpty)
                  _Letter(
                    label: rail.allLabel,
                    enabled: true,
                    selected: active == null,
                    wide: true,
                    onTap: () => onPick(null),
                  ),
                for (final l in rail.letters)
                  _Letter(
                    label: l.label,
                    enabled: l.enabled,
                    selected: l.key == active,
                    wide: false,
                    onTap: l.enabled ? () => onPick(l.key) : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One cell of the strip. A full touch target wide and tall even for a single
/// character, because a 13 px letter is not a button.
class _Letter extends StatelessWidget {
  final String label;
  final bool enabled;
  final bool selected;
  final bool wide;
  final VoidCallback? onTap;

  const _Letter({
    required this.label,
    required this.enabled,
    required this.selected,
    required this.wide,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? Ds.c.divider
        : (selected ? Ds.c.brand : Ds.c.textSecondary);
    return InkWell(
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap!();
            },
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(
          minWidth: Ds.touch.minTarget,
          minHeight: Ds.touch.minTarget,
        ),
        padding: wide
            ? EdgeInsets.symmetric(horizontal: Ds.space.x12)
            : EdgeInsets.zero,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Ds.c.brandSoft : null,
          borderRadius: Ds.r.rChip,
        ),
        child: Text(label, style: Ds.t.body.copyWith(color: color)),
      ),
    );
  }
}
