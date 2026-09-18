/// CMD #2074 — `pdp_salt_compare()`'s payload, turned ninety degrees.
///
/// Products are ROWS now and attributes are COLUMNS, because the question the
/// product page asks is "what else is this salt" and the answer is a LIST of
/// brands — twenty of them — not three ticked packs across the top. The tray's
/// own table (`product_compare()`, `ProductCompare` in product_compare.dart)
/// still has the old shape and is a different surface; nothing here touches it.
///
/// [columns] arrives in render order and every [CompareTableRow.cells] entry
/// sits at the SAME index as the column it belongs to, so the screen zips two
/// lists and prints strings. It does not know that "Margin" is a percentage
/// and "Profit" is money, and it must not: the moment the app formats a cell
/// there are two renderings of one number again, which is the bug this
/// codebase keeps paying for.
///
/// [CompareTableCell.has] is the whole no-false-numbers rule (#366) in one
/// bool, and [CompareTableCell.locked] is #1895's: a pack with no real trade
/// rate arrives locked on the sale, margin AND profit cells, all three
/// carrying the same literal word and the same pill colours, from the one
/// `price_locked` fact. There is no fallback to MRP anywhere — MRP is the
/// legal ceiling printed on the pack, not a price mediBO sells at, so a margin
/// derived from it would be invented.
class CompareTable {
  final bool ok;
  final bool has;
  final String title;
  final String note;
  final String empty;
  final int max;

  /// The column order, labels and widths — all the backend's. Column 0 is the
  /// frozen one; it exists even when [has] is false, so the empty state draws
  /// under a real heading instead of under nothing.
  final List<CompareColumn> columns;

  /// One entry per product, in payload order: the opened pack is first.
  final List<CompareTableRow> rows;

  /// The table's geometry, from `app_settings.compare_layout`. A table needs
  /// column widths and this is the one place they live, so widening a column
  /// is an UPDATE, never a deploy.
  final CompareLayout layout;

  const CompareTable({
    required this.ok,
    required this.has,
    required this.title,
    required this.note,
    required this.empty,
    required this.max,
    required this.columns,
    required this.rows,
    required this.layout,
  });

  static const CompareTable failed = CompareTable(
      ok: false, has: false, title: '', note: '', empty: '', max: 0,
      columns: [], rows: [], layout: CompareLayout.fallback);

  static String _s(Object? v) => v?.toString() ?? '';

  static double _d(Object? v, double fallback) {
    if (v is num) return v.toDouble();
    return double.tryParse(_s(v)) ?? fallback;
  }

  factory CompareTable.fromMap(Map<String, dynamic> m) {
    if (m['ok'] != true) return CompareTable.failed;
    final mx = m['max'];
    return CompareTable(
      ok: true,
      has: m['has'] == true,
      title: _s(m['title']),
      note: _s(m['note']),
      empty: _s(m['empty']),
      max: mx is int ? mx : int.tryParse(_s(mx)) ?? 0,
      columns: ((m['columns'] as List?) ?? const [])
          .whereType<Map>()
          .map((c) => CompareColumn.fromMap(c.cast<String, dynamic>()))
          .toList(growable: false),
      rows: ((m['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => CompareTableRow.fromMap(r.cast<String, dynamic>()))
          .toList(growable: false),
      layout: m['layout'] is Map
          ? CompareLayout.fromMap((m['layout'] as Map).cast<String, dynamic>())
          : CompareLayout.fallback,
    );
  }
}

/// One column heading. [kind] is the backend telling the screen WHAT to draw,
/// never what to decide: `name` is the frozen, tappable product column, `pill`
/// a chip, `add` the cart control, anything else plain text — and an unknown
/// kind falls back to text rather than drawing nothing.
class CompareColumn {
  final String key;
  final String label;
  final String kind;
  final String align;
  final bool frozen;

  /// Logical px, for a scrolling column. The frozen column sends none: its
  /// width is a SHARE of the viewport, so it survives a 320px phone.
  final double width;

  const CompareColumn({
    required this.key,
    required this.label,
    required this.kind,
    required this.align,
    required this.frozen,
    required this.width,
  });

  bool get isName => kind == 'name';
  bool get isAdd => kind == 'add';
  bool get isRight => align == 'right';

  factory CompareColumn.fromMap(Map<String, dynamic> m) => CompareColumn(
        key: CompareTable._s(m['key']),
        label: CompareTable._s(m['label']),
        kind: CompareTable._s(m['kind']),
        align: CompareTable._s(m['align']),
        frozen: m['frozen'] == true,
        width: CompareTable._d(m['width'], 96),
      );
}

class CompareLayout {
  final double namePct;
  final double nameMin;
  final double nameMax;
  final double rowH;
  final double headH;

  const CompareLayout({
    required this.namePct,
    required this.nameMin,
    required this.nameMax,
    required this.rowH,
    required this.headH,
  });

  /// Only ever reached by [CompareTable.failed], which draws no table at all —
  /// a payload-less table has no geometry to argue about.
  static const CompareLayout fallback = CompareLayout(
      namePct: 42, nameMin: 116, nameMax: 200, rowH: 64, headH: 44);

  factory CompareLayout.fromMap(Map<String, dynamic> m) => CompareLayout(
        namePct: CompareTable._d(m['name_pct'], fallback.namePct),
        nameMin: CompareTable._d(m['name_min'], fallback.nameMin),
        nameMax: CompareTable._d(m['name_max'], fallback.nameMax),
        rowH: CompareTable._d(m['row_h'], fallback.rowH),
        headH: CompareTable._d(m['head_h'], fallback.headH),
      );

  /// The frozen column is a SHARE of whatever viewport it is handed, clamped
  /// by the backend's own bounds — the one piece of arithmetic on this screen,
  /// and it is layout, not money.
  double nameWidth(double viewport) {
    final lo = nameMin <= nameMax ? nameMin : nameMax;
    final hi = nameMin <= nameMax ? nameMax : nameMin;
    if (viewport <= 0) return lo;
    return (viewport * namePct / 100.0).clamp(lo, hi).toDouble();
  }
}

/// One product. The name, the tag and the ADD verdict sit on the ROW because
/// two different columns read them; every other fact is in [cells], at the
/// index of its own column.
class CompareTableRow {
  final String id;
  final String name;
  final String company;
  final bool isCurrent;

  /// The word on the row whose page opened the table (`cmp_current_tag`), and
  /// empty on every other row. An empty tag draws nothing.
  final String tag;

  /// `storefront_cta()`'s own verdict, the same one the card's pill reads:
  /// [canAdd] false is the ONLY out-of-stock signal, and [ctaLabel] is the
  /// word. No word from the backend means no control at all.
  final bool canAdd;
  final String ctaLabel;

  final List<CompareTableCell> cells;

  const CompareTableRow({
    required this.id,
    required this.name,
    required this.company,
    required this.isCurrent,
    required this.tag,
    required this.canAdd,
    required this.ctaLabel,
    required this.cells,
  });

  factory CompareTableRow.fromMap(Map<String, dynamic> m) => CompareTableRow(
        id: CompareTable._s(m['id']),
        name: CompareTable._s(m['name']),
        company: CompareTable._s(m['company']),
        isCurrent: m['is_current'] == true,
        tag: CompareTable._s(m['tag']),
        canAdd: m['can_add'] == true,
        ctaLabel: CompareTable._s(m['cta_label']),
        cells: ((m['cells'] as List?) ?? const [])
            .whereType<Map>()
            .map((c) => CompareTableCell.fromMap(c.cast<String, dynamic>()))
            .toList(growable: false),
      );

  /// The cell for column [i], or an absent one: a payload with fewer cells
  /// than columns leaves a blank in the table and never throws under a
  /// customer's thumb mid-decision.
  CompareTableCell cell(int i) =>
      (i >= 0 && i < cells.length) ? cells[i] : CompareTableCell.absent;
}

class CompareTableCell {
  /// false = "we do not know this". The value is still a printable string (the
  /// backend's own dash), so the table never has a hole and the app never has
  /// to invent a placeholder.
  final bool has;
  final String value;
  final String tone;

  /// CMD #2074 — true while this cell shows the literal PTR word instead of an
  /// amount. Sale price, Margin and Profit carry it TOGETHER, off the one
  /// `card_price.price_locked` fact, so they can never disagree.
  final bool locked;

  /// Chip colours, for a cell the backend wants drawn as a pill. Empty is
  /// "plain text" — the app picks no fill of its own.
  final String pillBg;
  final String pillFg;
  bool get isPill => pillBg.isNotEmpty;

  const CompareTableCell({
    required this.has,
    required this.value,
    required this.tone,
    this.locked = false,
    this.pillBg = '',
    this.pillFg = '',
  });

  static const CompareTableCell absent =
      CompareTableCell(has: false, value: '', tone: 'text');

  factory CompareTableCell.fromMap(Map<String, dynamic> m) {
    final pill = m['pill'];
    return CompareTableCell(
      has: m['has'] == true,
      value: CompareTable._s(m['value']),
      tone: CompareTable._s(m['tone']),
      locked: m['locked'] == true,
      pillBg: pill is Map ? CompareTable._s(pill['bg']) : '',
      pillFg: pill is Map ? CompareTable._s(pill['fg']) : '',
    );
  }
}
