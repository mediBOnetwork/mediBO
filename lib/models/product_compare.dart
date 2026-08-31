import 'product.dart' show Pricing;

/// CMD #410 — the `product_compare(p_ids)` payload.
///
/// The table is COMPOSED by the backend: rows arrive in render order, each
/// already carrying its own label and one cell per chosen product, in the
/// order the customer picked them. The widget runs a nested loop and prints
/// strings. It does not know that "Net rate" is money and "Fill rate" is a
/// percentage, and it must not — the moment the app formats a cell there are
/// two renderings of one number again, which is the bug this codebase keeps
/// paying for.
///
/// [CompareCell.has] is the whole no-false-numbers rule (#366) in one bool. A
/// product with no real trade rate arrives has:false on the rate row AND the
/// margin row, and [CompareCell.value] is the backend's own dash. There is no
/// fallback to MRP anywhere: MRP is the legal ceiling printed on the pack, not
/// a price mediBO sells at, so a margin derived from it would be invented.
class ProductCompare {
  final bool ok;
  final bool has;
  final String title;
  final String note;
  final String empty;
  final int max;
  final Map<String, String> labels;
  final List<CompareProduct> products;
  final List<CompareRow> rows;

  const ProductCompare({
    required this.ok,
    required this.has,
    required this.title,
    required this.note,
    required this.empty,
    required this.max,
    required this.labels,
    required this.products,
    required this.rows,
  });

  static const ProductCompare failed = ProductCompare(
    ok: false, has: false, title: '', note: '', empty: '', max: 3,
    labels: {}, products: [], rows: []);

  String label(String key) => labels[key] ?? '';

  static String _s(Object? v) => v?.toString() ?? '';

  factory ProductCompare.fromMap(Map<String, dynamic> m) {
    if (m['ok'] != true) return ProductCompare.failed;
    final raw = m['labels'];
    final mx = m['max'];
    return ProductCompare(
      ok: true,
      has: m['has'] == true,
      title: _s(m['title']),
      note: _s(m['note']),
      empty: _s(m['empty']),
      max: mx is int ? mx : int.tryParse(_s(mx)) ?? 3,
      labels: raw is Map
          ? raw.map((k, v) => MapEntry(k.toString(), _s(v)))
          : const {},
      products: ((m['products'] as List?) ?? const [])
          .whereType<Map>()
          .map((p) => CompareProduct.fromMap(p.cast<String, dynamic>()))
          .toList(growable: false),
      rows: ((m['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => CompareRow.fromMap(r.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }
}

class CompareProduct {
  final String id;
  final String name;
  final String company;
  final String image;

  /// The SAME price block every card reads, so a compare column and the
  /// product page can never quote different money.
  final Pricing? pricing;

  const CompareProduct({
    required this.id,
    required this.name,
    required this.company,
    required this.image,
    required this.pricing,
  });

  factory CompareProduct.fromMap(Map<String, dynamic> m) => CompareProduct(
        id: ProductCompare._s(m['id']),
        name: ProductCompare._s(m['name']),
        company: ProductCompare._s(m['company']),
        image: ProductCompare._s(m['image']),
        pricing: m['pricing'] is Map
            ? Pricing.fromMap((m['pricing'] as Map).cast<String, dynamic>())
            : null,
      );
}

class CompareRow {
  final String key;
  final String label;
  final List<CompareCell> cells;
  const CompareRow({
    required this.key,
    required this.label,
    required this.cells,
  });

  factory CompareRow.fromMap(Map<String, dynamic> m) => CompareRow(
        key: ProductCompare._s(m['key']),
        label: ProductCompare._s(m['label']),
        cells: ((m['cells'] as List?) ?? const [])
            .whereType<Map>()
            .map((c) => CompareCell.fromMap(c.cast<String, dynamic>()))
            .toList(growable: false),
      );
}

class CompareCell {
  /// false = "we do not know this". The value is still a printable string (the
  /// backend's dash), so the table never has a hole and the app never has to
  /// invent a placeholder.
  final bool has;
  final String value;
  final String tone;
  const CompareCell({
    required this.has,
    required this.value,
    required this.tone,
  });

  factory CompareCell.fromMap(Map<String, dynamic> m) => CompareCell(
        has: m['has'] == true,
        value: ProductCompare._s(m['value']),
        tone: ProductCompare._s(m['tone']),
      );
}
