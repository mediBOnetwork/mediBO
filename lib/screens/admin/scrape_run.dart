/// CMD #1870 — the two decisions the scrape lane used to make in Dart, pulled
/// out of the 15k-line customers screen so they can be held down by a test.
///
/// Both are deliberately dumb:
///
///   * [ScrapeRunView] reads a `scrape_runs_list()` row. Every caption it
///     exposes is a string the backend already wrote — the kept/dropped line,
///     the whole delete confirmation. Nothing is composed, pluralised or
///     formatted here; an absent field is absent, not a Dart fallback.
///
///   * [ScrapeStartArgs] builds the `lead_scrape_start()` parameters. The
///     Include / Exclude trays are sent as the chip keys the admin actually
///     tapped. Resolving those into Google types (include minus exclude, a
///     parent implying its children) is the BACKEND's job now — Flutter no
///     longer knows what a Google place type is.
library;

/// The delete confirmation, exactly as `scrape_runs_list().delete` sent it.
class ScrapeRunDelete {
  final String label;
  final String title;
  final String body;
  final String ok;
  final String cancel;
  final int count;

  const ScrapeRunDelete({
    required this.label,
    required this.title,
    required this.body,
    required this.ok,
    required this.cancel,
    required this.count,
  });

  static ScrapeRunDelete? from(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final label = (m['label'] ?? '').toString();
    // No caption means the backend is not offering the action at all.
    if (label.isEmpty) return null;
    return ScrapeRunDelete(
      label: label,
      title: (m['title'] ?? '').toString(),
      body: (m['body'] ?? '').toString(),
      ok: (m['ok'] ?? '').toString(),
      cancel: (m['cancel'] ?? '').toString(),
      count: (m['count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One row of `scrape_runs_list()`.
class ScrapeRunView {
  final String runId;
  final String city;
  final String status;
  final String typesLabel;
  final String summaryLabel;

  /// "12 kept · 3 dropped by your chips" — null when the backend sent none
  /// (a run from before the filter existed, or one that stored nothing).
  final String? keptDroppedLabel;

  final String? error;
  final ScrapeRunDelete? delete;

  const ScrapeRunView({
    required this.runId,
    required this.city,
    required this.status,
    required this.typesLabel,
    required this.summaryLabel,
    required this.keptDroppedLabel,
    required this.error,
    required this.delete,
  });

  factory ScrapeRunView.from(Map<String, dynamic> r) {
    String? nonEmpty(Object? v) {
      final s = (v ?? '').toString();
      return s.isEmpty ? null : s;
    }

    return ScrapeRunView(
      runId: (r['run_id'] ?? '').toString(),
      city: (r['city'] ?? '').toString(),
      status: (r['status'] ?? '').toString(),
      typesLabel: (r['types_label'] ?? '').toString(),
      summaryLabel: (r['summary_label'] ?? '').toString(),
      keptDroppedLabel: nonEmpty(r['kept_dropped_label']),
      error: nonEmpty(r['error']),
      // can_delete:false hides the action however complete the block is.
      delete: r['can_delete'] == false ? null : ScrapeRunDelete.from(r['delete']),
    );
  }

  bool get canDelete => delete != null;
}

/// The parameters of one `lead_scrape_start()` call.
class ScrapeStartArgs {
  final String name;
  final String level;
  final List<String> include;
  final List<String> exclude;
  final int maxCalls;

  const ScrapeStartArgs({
    required this.name,
    required this.level,
    required this.include,
    required this.exclude,
    required this.maxCalls,
  });

  /// Sets are unordered; the wire is not. Sorting keeps two identical
  /// selections producing one identical call.
  factory ScrapeStartArgs.fromTrays({
    required String name,
    required String level,
    required Set<String> include,
    required Set<String> exclude,
    required int maxCalls,
  }) {
    final inc = include.toList()..sort();
    final exc = exclude.where((k) => !include.contains(k)).toList()..sort();
    return ScrapeStartArgs(
      name: name.trim(),
      level: level,
      include: inc,
      exclude: exc,
      maxCalls: maxCalls,
    );
  }

  Map<String, dynamic> toParams() => {
        'p_name': name,
        'p_level': level,
        'p_include': include,
        'p_exclude': exclude,
        'p_cell_km': null,
        'p_max_calls': maxCalls,
      };
}
