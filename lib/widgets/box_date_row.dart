// CHANGE #545 — this file used to be date_scope_chip.dart and held DateScopeChip,
// the per-screen date picker shared by Customer Orders, Supplier Orders and the
// five Fulfill tabs. Every one of those pickers is DELETED: the admin interface
// now has exactly ONE date picker (AdminDatePicker, on the Dashboard above the
// ORDER HOURS card) and every tab follows it through AdminDateScope.
//
// What survives is the per-box date heading below, which only PRINTS a
// backend-owned label — it has never been tappable.
import 'package:flutter/material.dart';

import '../fulfill/fulfill_view_logic.dart' show BoxOlder;

/// CHANGE #471 — per-box date heading for a single open fw_get_state box
/// (Supplier Shop / Warehouse). date_label is printed VERBATIM from the
/// backend — never formatted or constructed here. Renders nothing when
/// [dateLabel] is null/empty.
///
/// CHANGE #531 — the include-older pill that used to sit on the right of this
/// row is deleted (project rule: no "+N from earlier dates" chrome anywhere —
/// the date picker is the only way to change the date). [older]/[includeOlder]/
/// [onToggleOlder] are accepted and ignored so the single caller still compiles.
class BoxDateOlderRow extends StatelessWidget {
  final String? dateLabel;
  final BoxOlder older;
  final bool includeOlder;
  final VoidCallback onToggleOlder;
  final EdgeInsets padding;

  const BoxDateOlderRow({
    super.key,
    required this.dateLabel,
    required this.older,
    required this.includeOlder,
    required this.onToggleOlder,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 0),
  });

  @override
  Widget build(BuildContext context) {
    final label = dateLabel;
    if (label == null || label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6B7280))),
        ),
      ]),
    );
  }
}
