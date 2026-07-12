// CHANGE #444 — shared date-scope chip + "N older open items" pill, used on
// Customer Orders, Supplier Orders and all 5 Fulfill tabs (Supplier Shop,
// Warehouse, Bag, Pack, Disputes). One widget, no per-screen copies.
import 'package:flutter/material.dart';

import '../utils/ist_date.dart';

/// Tappable "Today · DD/MM/YYYY" (or "DD/MM/YYYY" for a past date) chip that
/// opens a Material date picker. Cancelling the picker changes nothing.
class DateScopeChip extends StatelessWidget {
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

  String get _label => isToday ? 'Today · ${dmy(selected)}' : dmy(selected);

  Future<void> _pick(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selected,
      firstDate: firstDate ?? DateTime(2024),
      lastDate: todayIst(),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: Color(0xFF1B7A43)),
        ),
        child: child!,
      ),
    );
    if (picked != null) onChanged(DateTime(picked.year, picked.month, picked.day));
  }

  @override
  Widget build(BuildContext context) {
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
          Text(_label,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          const SizedBox(width: 3),
          const Icon(Icons.arrow_drop_down, size: 16, color: Color(0xFF6B7280)),
        ]),
      ),
    );
  }
}

/// Amber "N older open items — tap to include" / green "Including N older
/// open items — tap to hide" pill. Renders nothing when olderOpen == 0.
/// Fulfill-tabs-only — Customer Orders / Supplier Orders never show this.
class OlderOpenPill extends StatelessWidget {
  final int olderOpen;
  final bool includeOlder;
  final VoidCallback onTap;

  const OlderOpenPill({
    super.key,
    required this.olderOpen,
    required this.includeOlder,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (olderOpen <= 0) return const SizedBox.shrink();
    final plural = olderOpen == 1 ? 'item' : 'items';
    final bg = includeOlder ? const Color(0xFFD1FAE5) : const Color(0xFFFEF3C7);
    final fg = includeOlder ? const Color(0xFF065F46) : const Color(0xFF92400E);
    final label = includeOlder
        ? 'Including $olderOpen older open $plural — tap to hide'
        : '$olderOpen older open $plural — tap to include';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
      ),
    );
  }
}
