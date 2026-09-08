/// CMD #1875 — the ₹ chip row on a route card and on the plan summary.
///
/// The chips exist because a plan that says "18.6 km" says nothing about what
/// the day COSTS. The cost itself, the ₹ per converted lead and every word of
/// both are computed and formatted by the backend (`_c1875_cost_block`), so
/// the only thing left to decide is which chips are present and what tone each
/// one carries. That decision lives here, in a pure class, rather than inside a
/// 16,000-line screen where it cannot be tested.
///
/// Rules this class holds down:
///  * No cost_label => no chip row at all. An absent cost is absent, never
///    "₹0".
///  * The "per converted lead" chip is ALWAYS shown once a cost exists — but
///    its tone comes from the backend's `has_conversions` flag, never from
///    reading the number in the string. With no conversions yet the backend
///    sends its own copy ("No conversions yet") and the chip goes quiet.
///  * Labels are printed verbatim. Nothing here formats money, pluralises, or
///    appends a currency symbol.
library;

/// The tone a chip is drawn in. The screen maps these onto Ds tokens; keeping
/// them as names means this file needs no Flutter import and the test needs no
/// widget binding.
enum RouteChipTone { brand, success, muted, info, warning }

class RouteCostChip {
  final String label;
  final RouteChipTone tone;
  const RouteCostChip(this.label, this.tone);

  @override
  String toString() => '$label(${tone.name})';
}

class RouteCostChips {
  final String? cost;
  final String? perConverted;
  final String? converted;
  final bool hasConversions;

  const RouteCostChips({
    this.cost,
    this.perConverted,
    this.converted,
    this.hasConversions = false,
  });

  static String? _s(Object? v) {
    final t = v?.toString();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// Reads a `_c1875_cost_block` payload — a route object or the plan summary.
  factory RouteCostChips.from(Map<String, dynamic> m) => RouteCostChips(
        cost: _s(m['cost_label']),
        perConverted: _s(m['cost_per_converted_label']),
        converted: _s(m['converted_label']),
        hasConversions: m['has_conversions'] == true,
      );

  bool get isEmpty => cost == null;

  List<RouteCostChip> get chips {
    if (isEmpty) return const [];
    return [
      RouteCostChip(cost!, RouteChipTone.brand),
      if (perConverted != null)
        RouteCostChip(perConverted!,
            hasConversions ? RouteChipTone.success : RouteChipTone.muted),
      if (converted != null) RouteCostChip(converted!, RouteChipTone.info),
    ];
  }
}

/// CMD #1875 — the version chips on a plan card. A plan that was never rebuilt
/// is v1 and says nothing; a rebuilt one names its version, and the plan it
/// replaced names its successor.
class RoutePlanVersionChips {
  final int version;
  final String? versionLabel;
  final String? supersededLabel;

  const RoutePlanVersionChips({
    required this.version,
    this.versionLabel,
    this.supersededLabel,
  });

  factory RoutePlanVersionChips.from(Map<String, dynamic> header) =>
      RoutePlanVersionChips(
        version: (header['version'] as num?)?.toInt() ?? 1,
        versionLabel: RouteCostChips._s(header['version_label']),
        supersededLabel: RouteCostChips._s(header['superseded_label']),
      );

  List<RouteCostChip> get chips => [
        if (version > 1 && versionLabel != null)
          RouteCostChip(versionLabel!, RouteChipTone.info),
        if (supersededLabel != null)
          RouteCostChip(supersededLabel!, RouteChipTone.warning),
      ];
}
