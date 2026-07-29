// CHANGE #545/#546 — THE date picker for the admin interface. There is exactly
// one, it lives on the Dashboard directly above the ORDER HOURS card, and every
// date-scoped tab (Customer Orders, Supplier Orders, Inquiry, Supplier Shop,
// Warehouse, Bag, Pack, Disputes) follows it through AdminDateScope.
//
// CHANGE #546 replaces the 3-option radio dropdown with a real month calendar
// built from admin_date_scope_state().calendar[] (60 days), bounded by
// min_date/max_date, with the backend's own order badge on each day cell.
//
// BACKEND-OWNED, rendered verbatim:
//   • button text        -> long_label
//   • day cell badge     -> entry.badge          (only when non-null)
//   • badge colours      -> entry.badge_colors {bg, fg}
//   • month section head -> the backend `label` of that month's first day
//   • selectable range   -> whatever calendar[] contains (min_date..max_date)
// The client NEVER formats a date and NEVER counts orders.
//
// The ONE thing derived client-side is grid STRUCTURE — which of the 7 columns
// a day occupies and which month it groups under — read off the ISO `date`
// string. No date TEXT is produced from it: the day number is an integer, and
// every string on screen comes from the RPC.
import 'package:flutter/material.dart';

import '../services/admin_date_scope.dart';
import '../utils/render_log.dart';

class AdminDatePicker extends StatefulWidget {
  /// CHANGE #609 — drop this widget's own bottom padding and left-align
  /// wrapper so it can sit inside the Dashboard's filter row beside
  /// AdminZonePicker. The button itself is unchanged; only the outer spacing
  /// differs, so the two filters line up.
  final bool bare;

  const AdminDatePicker({super.key, this.bare = false});

  @override
  State<AdminDatePicker> createState() => _AdminDatePickerState();
}

class _AdminDatePickerState extends State<AdminDatePicker> {
  final GlobalKey _anchorKey = GlobalKey();

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

  Future<void> _open() async {
    final scope = AdminDateScope.instance;
    if (scope.calendar.isEmpty) return;
    RenderLog.write('c546_calendar_open', 'days=${scope.calendar.length}');

    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;

    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final position = RelativeRect.fromLTRB(
      origin.dx,
      origin.dy + box.size.height + 6,
      (overlay.size.width - origin.dx - box.size.width)
          .clamp(0.0, overlay.size.width),
      0,
    );

    final picked = await showMenu<String>(
      context: context,
      position: position,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: _CalendarBody(onPick: (d) => Navigator.of(context).pop(d)),
        ),
      ],
    );

    if (picked != null) await AdminDateScope.instance.select(picked);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AdminDateScope.instance;
    final text = scope.longLabel;
    RenderLog.write('c545_picker', 'label=$text');

    final button = InkWell(
          key: _anchorKey,
          onTap: _open,
          borderRadius: BorderRadius.circular(10),
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
              // Neutral placeholder until the backend label lands — there is
              // deliberately no client-side date fallback.
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
        );

    if (widget.bare) return button;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(alignment: Alignment.centerLeft, child: button),
    );
  }
}

// ── Calendar ────────────────────────────────────────────────────────────────

/// One month's worth of backend calendar entries.
class _MonthGroup {
  final int year;
  final int month;

  /// Backend `label` of this month's earliest day — used verbatim as the
  /// section heading, because the payload carries no month-name field and the
  /// client is not allowed to build one.
  final String heading;

  /// Day-of-month -> backend entry.
  final Map<int, Map<String, dynamic>> days;

  const _MonthGroup({
    required this.year,
    required this.month,
    required this.heading,
    required this.days,
  });
}

class _CalendarBody extends StatelessWidget {
  final ValueChanged<String> onPick;
  const _CalendarBody({required this.onPick});

  static const _weekdayHeads = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  /// Groups the backend calendar into months. Structure only — the ISO date is
  /// parsed for year / month / day-of-month integers and nothing else.
  List<_MonthGroup> _group(List<Map<String, dynamic>> cal) {
    final byKey = <String, Map<int, Map<String, dynamic>>>{};
    final order = <String>[];
    final heading = <String, String>{};
    final ym = <String, List<int>>{};

    // calendar[] is newest-first; walk it oldest-first so each month's heading
    // comes from that month's earliest day.
    for (final e in cal.reversed) {
      final iso = e['date']?.toString();
      if (iso == null) continue;
      final d = DateTime.tryParse(iso);
      if (d == null) continue;
      final key = '${d.year}-${d.month}';
      if (!byKey.containsKey(key)) {
        byKey[key] = <int, Map<String, dynamic>>{};
        order.add(key);
        ym[key] = [d.year, d.month];
        heading[key] = e['label']?.toString() ?? '';
      }
      byKey[key]![d.day] = e;
    }

    return [
      for (final k in order)
        _MonthGroup(
          year: ym[k]![0],
          month: ym[k]![1],
          heading: heading[k] ?? '',
          days: byKey[k]!,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final groups = _group(AdminDateScope.instance.calendar);
    RenderLog.write('c546_calendar_months', '${groups.length}');

    return SizedBox(
      width: 316,
      height: 372,
      child: Column(children: [
        // Weekday column heads — static UI chrome, not derived from any date.
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
          child: Row(children: [
            for (final w in _weekdayHeads)
              Expanded(
                child: Center(
                  child: Text(w,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF9CA3AF))),
                ),
              ),
          ]),
        ),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: groups.length,
            // Newest month first, matching the backend's own ordering.
            itemBuilder: (_, i) =>
                _MonthGrid(group: groups[groups.length - 1 - i], onPick: onPick),
          ),
        ),
      ]),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  final _MonthGroup group;
  final ValueChanged<String> onPick;
  const _MonthGrid({required this.group, required this.onPick});

  /// Days in this calendar month — pure structure.
  int get _daysInMonth => DateTime(group.year, group.month + 1, 0).day;

  /// Weekday column (0 = Monday) of the 1st — pure structure.
  int get _leadBlanks => DateTime(group.year, group.month, 1).weekday - 1;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        // Backend string, verbatim. The payload has no month-name field, so
        // this is that month's first day's own label rather than a client-built
        // "July 2026".
        child: Text(group.heading,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF6B7280))),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var i = 0; i < _leadBlanks; i++) const SizedBox.shrink(),
            for (var day = 1; day <= _daysInMonth; day++)
              _DayCell(entry: group.days[day], day: day, onPick: onPick),
          ],
        ),
      ),
      const SizedBox(height: 4),
    ]);
  }
}

class _DayCell extends StatelessWidget {
  /// Null when this square falls outside the backend's 60-day window (i.e.
  /// outside min_date..max_date) — not selectable, and never badged.
  final Map<String, dynamic>? entry;
  final int day;
  final ValueChanged<String> onPick;

  const _DayCell(
      {required this.entry, required this.day, required this.onPick});

  static Color? _hex(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final h = raw.startsWith('#') ? raw.substring(1) : raw;
    final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
    return v == null ? null : Color(v);
  }

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final iso = e?['date']?.toString();
    final selected = e?['is_selected'] == true;
    final isToday = e?['is_today'] == true;

    // Rendered ONLY when the backend supplies one — never synthesised, and
    // never derived from customer_orders/supplier_orders by the client.
    final badge = e?['badge']?.toString();
    final hasBadge = badge != null && badge.isNotEmpty;
    final colors = e?['badge_colors'];
    final badgeBg = _hex(colors is Map ? colors['bg']?.toString() : null);
    final badgeFg = _hex(colors is Map ? colors['fg']?.toString() : null);

    final enabled = iso != null;

    return InkWell(
      onTap: enabled ? () => onPick(iso) : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1B7A43) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: (!selected && isToday)
              ? Border.all(color: const Color(0xFF1B7A43))
              : null,
        ),
        child: Stack(clipBehavior: Clip.none, children: [
          Center(
            // An integer position within the month, not a formatted date.
            child: Text(
              '$day',
              style: TextStyle(
                fontSize: 13,
                fontWeight:
                    (selected || isToday) ? FontWeight.w700 : FontWeight.w500,
                color: !enabled
                    ? const Color(0xFFD1D5DB)
                    : selected
                        ? Colors.white
                        : const Color(0xFF111827),
              ),
            ),
          ),
          if (hasBadge && badgeBg != null)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                constraints: const BoxConstraints(minWidth: 14),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badge,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: badgeFg ?? Colors.white,
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
