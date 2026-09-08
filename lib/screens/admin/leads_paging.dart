// CHANGE #1867 — the paging decisions for Customers > S Leads and > Routes,
// as a pure class so they can be tested without a screen, a network or a
// Supabase client (test/protected/sleads_paging_test.dart).
//
// Both lists are the SAME contract: one RPC returns an envelope of
//   { rows[], total, page_size, offset, has_more, next_offset,
//     count_label, empty_label, more_label, end_label }
// and this holds it. Two rules are the whole point of the class:
//   • "is there another page" is the BACKEND's has_more, never rows.length
//     compared against a total the client did its own arithmetic on;
//   • the next fetch starts at the BACKEND's next_offset, never at
//     rows.length — a filtered list whose page came back short would
//     otherwise re-read rows it already has.
// Every label is carried through verbatim. Nothing here formats or composes.

/// One page-able list: the rows loaded so far plus the envelope that came
/// with the most recent page.
class PagedList {
  const PagedList({
    this.rows = const [],
    this.meta = const {},
    this.hasMore = false,
    this.nextOffset,
    this.total = 0,
    this.loaded = false,
  });

  /// Every row appended so far, in payload order. Never re-sorted.
  final List<Map<String, dynamic>> rows;

  /// The most recent envelope with `rows` removed — the labels live here.
  final Map<String, dynamic> meta;

  /// The backend's own answer to "is there another page".
  final bool hasMore;

  /// Where the next page starts, per the backend. Null when there is none.
  final int? nextOffset;

  /// The backend's total for the CURRENT filter set.
  final int total;

  /// True once a page has actually come back — so "no rows yet" and
  /// "the filters match nothing" are different states on screen.
  final bool loaded;

  /// The offset to ask for next. Page 1 is always 0; otherwise the backend's
  /// next_offset, falling back to what we hold only if it never sent one.
  int offsetFor({required bool reset}) =>
      reset ? 0 : (nextOffset ?? rows.length);

  /// Fold one envelope in. `reset` replaces the list (a filter changed, a
  /// search was typed); otherwise the page is APPENDED in arrival order.
  PagedList applyPage(Map<String, dynamic> env, {required bool reset}) {
    final page = ((env['rows'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final next = env['next_offset'];
    return PagedList(
      rows: reset ? page : [...rows, ...page],
      meta: Map<String, dynamic>.from(env)..remove('rows'),
      hasMore: env['has_more'] == true,
      nextOffset: next is num ? next.toInt() : null,
      total: (env['total'] as num?)?.toInt() ?? 0,
      loaded: true,
    );
  }

  /// May another page be requested right now? The backend decides; a caller
  /// adds its own in-flight guard on top.
  bool get canLoadMore => hasMore && nextOffset != null;

  /// True only once a page has come back and it was empty.
  bool get isEmpty => loaded && rows.isEmpty;

  String? _label(String key) {
    final v = meta[key];
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  String? get countLabel => _label('count_label');
  String? get emptyLabel => _label('empty_label');
  String? get moreLabel => _label('more_label');

  /// Printed only when the backend both sent it and says nothing is left.
  String? get endLabel => hasMore ? null : _label('end_label');
}

/// One S-Leads list row, resolved from whichever payload produced it.
///
/// sleads_page() sends the row fully labelled. A saved run's own leads
/// (scrape_run_export) predate that call and carry the raw column of the same
/// meaning, so each field falls back to it. A field neither payload has stays
/// null and its line is simply not drawn — absence is explicit, never a
/// placeholder invented here.
class SLeadRow {
  const SLeadRow({
    this.id,
    this.title = '',
    this.typeLabel,
    this.ratingLabel,
    this.openLabel,
    this.openBg,
    this.openFg,
    this.addressLabel,
    this.phoneLabel,
    this.branchesLabel,
    this.branchesExpandable = false,
    this.revisitLabel,
  });

  final int? id;
  final String title;
  final String? typeLabel;
  final String? ratingLabel;
  final String? openLabel;
  final String? openBg;
  final String? openFg;
  final String? addressLabel;
  final String? phoneLabel;

  /// CMD #1871 — leads sharing one phone are ONE row. The label is the
  /// backend's ("3 branches" collapsed, "1 of 3 branches" once the toggle is
  /// on) and `branchesExpandable` is the backend's answer to whether tapping
  /// it has anything to open. Neither is derived from a count here.
  final String? branchesLabel;
  final bool branchesExpandable;

  /// CMD #1874 — the revisit engine's chip. The backend sends a label ONLY
  /// when the lead's revisit date has come due, so the row shows a chip
  /// exactly when the next plan build would pick this lead up again. Nothing
  /// here compares a date.
  final String? revisitLabel;

  static String? _s(Map<String, dynamic> r, List<String> keys) {
    for (final k in keys) {
      final v = r[k];
      if (v == null) continue;
      final s = v.toString();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  factory SLeadRow.from(Map<String, dynamic> r) => SLeadRow(
        id: (r['id'] as num?)?.toInt(),
        title: _s(r, const ['title', 'name']) ?? '',
        typeLabel: _s(r, const ['type_label']),
        ratingLabel: _s(r, const ['rating_label']),
        openLabel: _s(r, const ['open_label']),
        openBg: _s(r, const ['open_bg']),
        openFg: _s(r, const ['open_fg']),
        addressLabel: _s(r, const ['address_label', 'short_address', 'address']),
        phoneLabel: _s(r, const ['phone_label', 'phone']),
        branchesLabel: _s(r, const ['branches_label']),
        branchesExpandable: r['branches_expandable'] == true,
        revisitLabel: _s(r, const ['revisit_label']),
      );
}
