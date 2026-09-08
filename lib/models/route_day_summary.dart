/// CMD #1877 — the day summary: what the field team actually did today.
///
/// `route_day_summary()` answers it once and TWO surfaces print the answer —
/// the card at the top of the Routes tab and the compact "Field" strip on the
/// Leads tab. Both read this class, so the two can never drift apart: there is
/// one RPC, one payload and one parse.
///
/// Every number in the payload arrives already worded and already formatted —
/// "3 of 3 stops closed", "0.7 km", "₹65 cost", "33% converted". Nothing here
/// computes a total, rounds a distance, appends a ₹ or pluralises a noun. The
/// only decision this file makes is which tone a chip is drawn in, and even
/// that is the backend's `tone` name mapped onto the shared enum.
library;

import 'route_cost_chips.dart' show RouteChipTone, RouteCostChip;

RouteChipTone _tone(Object? name) {
  switch (name?.toString()) {
    case 'brand':
      return RouteChipTone.brand;
    case 'success':
      return RouteChipTone.success;
    case 'warning':
      return RouteChipTone.warning;
    case 'danger':
      return RouteChipTone.danger;
    case 'info':
      return RouteChipTone.info;
    default:
      return RouteChipTone.muted;
  }
}

String? _s(Object? v) {
  final t = v?.toString();
  return (t == null || t.isEmpty) ? null : t;
}

List<RouteCostChip> _chips(Object? raw) => ((raw as List?) ?? const [])
    .whereType<Map>()
    .map((e) => RouteCostChip(e['label']?.toString() ?? '', _tone(e['tone'])))
    .where((c) => c.label.isNotEmpty)
    .toList();

/// One line of the summary: a worker's day, or the whole team's totals, or the
/// Leads strip. Same fields, same rendering, three callers.
class RouteDayRow {
  final String label;
  final String? progressLabel;
  final String? kmLabel;
  final String? costLabel;
  final String? conversionLabel;
  final List<RouteCostChip> chips;

  const RouteDayRow({
    required this.label,
    this.progressLabel,
    this.kmLabel,
    this.costLabel,
    this.conversionLabel,
    this.chips = const [],
  });

  factory RouteDayRow.worker(Map<String, dynamic> m) => RouteDayRow(
        label: m['worker_label']?.toString() ?? '',
        progressLabel: _s(m['progress_label']),
        kmLabel: _s(m['km_label']),
        costLabel: _s(m['cost_label']),
        conversionLabel: _s(m['conversion_label']),
        chips: _chips(m['chips']),
      );
}

/// The Leads tab's strip. `has` is the BACKEND's flag — the strip is absent on
/// a day with no field work, never a row of zeroes.
class RouteDayStrip {
  final bool has;
  final String title;
  final String? headerLabel;
  final String? summaryLabel;
  final String? costLabel;
  final String? conversionLabel;
  final String? linkLabel;
  final List<RouteCostChip> chips;

  const RouteDayStrip({
    this.has = false,
    this.title = '',
    this.headerLabel,
    this.summaryLabel,
    this.costLabel,
    this.conversionLabel,
    this.linkLabel,
    this.chips = const [],
  });

  factory RouteDayStrip.from(Map<String, dynamic> m) => RouteDayStrip(
        has: m['has'] == true,
        title: m['title']?.toString() ?? '',
        headerLabel: _s(m['header_label']),
        summaryLabel: _s(m['summary_label']),
        costLabel: _s(m['cost_label']),
        conversionLabel: _s(m['conversion_label']),
        linkLabel: _s(m['link_label']),
        chips: _chips(m['chips']),
      );
}

class RouteDaySummary {
  final bool ok;
  final bool has;
  final bool isAdmin;
  final String title;
  final String? headerLabel;
  final String? countLabel;
  final String? emptyLabel;
  final RouteDayRow? totals;
  final List<RouteDayRow> workers;
  final RouteDayStrip strip;

  const RouteDaySummary({
    this.ok = false,
    this.has = false,
    this.isAdmin = false,
    this.title = '',
    this.headerLabel,
    this.countLabel,
    this.emptyLabel,
    this.totals,
    this.workers = const [],
    this.strip = const RouteDayStrip(),
  });

  factory RouteDaySummary.from(Map<String, dynamic> m) {
    final totals = m['totals'];
    return RouteDaySummary(
      ok: m['ok'] == true,
      has: m['has'] == true,
      isAdmin: m['is_admin'] == true,
      title: m['title']?.toString() ?? '',
      headerLabel: _s(m['header_label']),
      countLabel: _s(m['count_label']),
      emptyLabel: _s(m['empty_label']),
      totals: totals is Map
          ? RouteDayRow(
              label: '',
              progressLabel: _s(totals['progress_label']),
              kmLabel: _s(totals['km_label']),
              costLabel: _s(totals['cost_label']),
              conversionLabel: _s(totals['conversion_label']),
              chips: _chips(totals['chips']),
            )
          : null,
      workers: ((m['workers'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => RouteDayRow.worker(Map<String, dynamic>.from(e)))
          .toList(),
      strip: m['strip'] is Map
          ? RouteDayStrip.from(Map<String, dynamic>.from(m['strip'] as Map))
          : const RouteDayStrip(),
    );
  }

  /// The card draws only when the caller was allowed AND the backend said so.
  /// An `ok:false` payload (partner staff on the Routes tab) draws nothing at
  /// all — not an error, not an empty state.
  bool get showCard => ok;

  /// A team totals line is an ADMIN thing: one worker looking at his own day
  /// would just read the same numbers twice.
  bool get showTotals => isAdmin && workers.length > 1 && totals != null;
}
