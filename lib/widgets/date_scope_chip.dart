// CHANGE #444 — shared date-scope chip + "N older open items" pill, used on
// Customer Orders, Supplier Orders and all 5 Fulfill tabs (Supplier Shop,
// Warehouse, Bag, Pack, Disputes). One widget, no per-screen copies.
//
// CHANGE #531 — the chip no longer formats a date. Its text is fw_date_label()'s
// `relative` (falling back to that same payload's `label`), read through
// FulfillLookups. While the payload is in flight the chip shows a neutral
// placeholder — there is deliberately no client dmy() fallback.
import 'package:flutter/material.dart';

import '../fulfill/fulfill_lookups.dart';
import '../fulfill/fulfill_view_logic.dart' show BoxOlder;
import '../services/fulfill_date_scope.dart';
import '../utils/ist_date.dart';

/// Tappable date chip that opens a Material date picker. Cancelling the picker
/// changes nothing. The label is backend copy, never constructed here.
class DateScopeChip extends StatefulWidget {
  final DateTime selected;
  final bool isToday;
  final ValueChanged<DateTime> onChanged;
  final DateTime? firstDate;

  const DateScopeChip({
    super.key,
    required this.selected,
    required this.isToday,
    required this.onChanged,
    this.firstDate,
  });

  @override
  State<DateScopeChip> createState() => _DateScopeChipState();
}

class _DateScopeChipState extends State<DateScopeChip> {
  @override
  void initState() {
    super.initState();
    FulfillLookups.instance.addListener(_onLookups);
    FulfillLookups.instance.ensureLoaded();
  }

  @override
  void dispose() {
    FulfillLookups.instance.removeListener(_onLookups);
    super.dispose();
  }

  void _onLookups() {
    if (mounted) setState(() {});
  }

  /// fw_date_label()'s `relative` (`Today` / `Yesterday` / `DD Mon YYYY`),
  /// else its `label`. Null until the payload for THIS date has landed — the
  /// cache only holds the label for FulfillDateScope's current date, so a chip
  /// pointing at some other date stays on the placeholder rather than printing
  /// the wrong day's copy.
  String? get _label {
    // CHANGE #531: resolve the label for THIS chip's own date. FulfillLookups
    // caches fw_date_label per date and fetches on miss, so the chips in
    // admin_customer_screen / admin_supplier_screen — whose date is NOT synced
    // to FulfillDateScope — resolve too instead of showing a placeholder.
    final lk = FulfillLookups.instance;
    return lk.dateRelativeFor(widget.selected) ?? lk.dateLabelFor(widget.selected);
  }

  Future<void> _pick(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.selected,
      firstDate: widget.firstDate ?? DateTime(2024),
      lastDate: todayIst(),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: Color(0xFF1B7A43)),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      widget.onChanged(DateTime(picked.year, picked.month, picked.day));
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = _label;
    return InkWell(
      onTap: () => _pick(context),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.calendar_today_outlined, size: 13, color: Color(0xFF6B7280)),
          const SizedBox(width: 5),
          // Neutral placeholder (an em dash) while the backend label is absent.
          Text(label ?? '—',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: label == null
                      ? const Color(0xFF9CA3AF)
                      : const Color(0xFF374151))),
          const SizedBox(width: 3),
          const Icon(Icons.arrow_drop_down, size: 16, color: Color(0xFF6B7280)),
        ]),
      ),
    );
  }
}

// CHANGE #531 — the "N older open items — tap to include" pill (OlderOpenPill)
// is DELETED. Project rule: there is no "+N from earlier dates" chrome anywhere
// — the date picker is the only way to change the date. Its client-side plural
// ('item'/'items') and amber/green colour derivations went with it.

/// CHANGE #471 — per-box date heading for a single open fw_get_state box
/// (Supplier Shop / Warehouse). date_label is printed VERBATIM from the
/// backend — never formatted or constructed here. Renders nothing when
/// [dateLabel] is null/empty.
///
/// CHANGE #531 — the include-older pill that used to sit on the right of this
/// row is deleted, same rule as OlderOpenPill above. [older]/[includeOlder]/[onToggleOlder]
/// are accepted and ignored so the single caller still compiles.
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
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
        ),
      ]),
    );
  }
}
