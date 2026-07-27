// CHANGE #545 — THE date picker for the admin interface. There is exactly one,
// it lives on the Dashboard directly above the ORDER HOURS card, and every
// date-scoped tab (Customer Orders, Supplier Orders, Inquiry, Supplier Shop,
// Warehouse, Bag, Pack, Disputes) follows it through AdminDateScope.
//
// Nothing here formats a date. The button text is the backend's `long_label`
// and each menu row is an option's own `label`, both verbatim. Selecting a row
// calls admin_set_date_scope(<date>) — or admin_set_date_scope(null) for the
// "Today" row — and the returned jsonb becomes the new state.
//
// Deliberately NOT a Material showDatePicker: the choices are the real order
// dates the backend reports, not an open calendar.
import 'package:flutter/material.dart';

import '../services/admin_date_scope.dart';
import '../utils/render_log.dart';

class AdminDatePicker extends StatefulWidget {
  const AdminDatePicker({super.key});

  @override
  State<AdminDatePicker> createState() => _AdminDatePickerState();
}

class _AdminDatePickerState extends State<AdminDatePicker> {
  @override
  void initState() {
    super.initState();
    AdminDateScope.instance.addListener(_onScope);
    AdminDateScope.instance.ensureLoaded();
  }

  @override
  void dispose() {
    AdminDateScope.instance.removeListener(_onScope);
    super.dispose();
  }

  void _onScope() {
    if (mounted) setState(() {});
  }

  /// The "Today" row plus every backend option, with the one option that IS
  /// today dropped so Today never appears twice. `null` value = snap to Today.
  List<_Row> _rows(AdminDateScope s) {
    final today = s.todayYmd;
    return [
      _Row(date: null, label: 'Today', selected: s.isToday),
      for (final o in s.options)
        if (o['date']?.toString() != today)
          _Row(
            date: o['date']?.toString(),
            label: o['label']?.toString() ?? '',
            selected: o['is_selected'] == true,
          ),
    ];
  }

  Future<void> _select(String? date) => AdminDateScope.instance.select(date);

  @override
  Widget build(BuildContext context) {
    final scope = AdminDateScope.instance;
    final text = scope.longLabel;
    RenderLog.write('c545_picker', 'label=$text');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: PopupMenuButton<String?>(
          tooltip: '',
          position: PopupMenuPosition.under,
          onSelected: _select,
          itemBuilder: (_) => [
            for (final r in _rows(scope))
              PopupMenuItem<String?>(
                value: r.date,
                child: Row(children: [
                  Icon(
                    r.selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: r.selected
                        ? const Color(0xFF1B7A43)
                        : const Color(0xFF9CA3AF),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    r.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          r.selected ? FontWeight.w700 : FontWeight.w500,
                      color: const Color(0xFF374151),
                    ),
                  ),
                ]),
              ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.calendar_today_outlined,
                  size: 14, color: Color(0xFF6B7280)),
              const SizedBox(width: 7),
              // Neutral placeholder (an em dash) until the backend label lands —
              // there is deliberately no client-side date fallback.
              Text(
                text.isEmpty ? '—' : text,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: text.isEmpty
                      ? const Color(0xFF9CA3AF)
                      : const Color(0xFF374151),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_drop_down,
                  size: 18, color: Color(0xFF6B7280)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Row {
  final String? date;
  final String label;
  final bool selected;
  const _Row({required this.date, required this.label, required this.selected});
}
