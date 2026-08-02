import 'product.dart' show Availability, Pricing;

/// CHANGE #636 — the `product_detail(p_product_id)` payload, parsed and nothing
/// more.
///
/// Every string in here is printed verbatim. There is no formatting, no
/// concatenation, no "if empty then …" fallback text and no derivation: the
/// page is one RPC and the RPC already decided everything, including the
/// section headings and the not-found copy (`labels`, from the
/// storefront_ui_label table, so changing wording is an UPDATE not a deploy).
///
/// product_detail() never returns null inside its payload — absence is encoded
/// explicitly as [hasMrp] / [hasGst] / [hasSupplierLabel] / [hasHistory] with
/// the string itself falling back to ''. So a missing value reads as "do not
/// show this row", never as "invent something to show".
class ProductDetail {
  final bool ok;
  final String id;
  final Map<String, String> labels;

  // header
  final String name;
  final String company;
  final String packLabel;
  final String formChip;
  final bool rxRequired;
  final List<String> images;

  // price
  final bool hasMrp;
  final String mrpLabel;
  final String mrpNote;
  final bool hasGst;
  final String gstLabel;

  // buy state — the SAME verdict the storefront card renders
  final Availability? availability;

  /// CHANGE #638 — the SAME price block the cards render.
  ///
  /// The page used to print `price.mrp_label` big while every card printed
  /// `pricing.price_display`. Two renderings of one number is exactly the
  /// shape of bug this codebase keeps paying for, so the page now reads the
  /// card's source. `price.mrp_label` stays in the payload but is no longer
  /// the headline.
  final Pricing? pricing;

  // stock
  final bool buyable;
  final bool hasSupplierLabel;
  final String supplierLabel;

  final List<PdOverviewRow> overview;
  final List<PdSection> sections;
  final List<PdSimilar> similar;

  final bool hasHistory;
  final String historyLabel;

  const ProductDetail({
    required this.ok,
    required this.id,
    required this.labels,
    required this.name,
    required this.company,
    required this.packLabel,
    required this.formChip,
    required this.rxRequired,
    required this.images,
    required this.hasMrp,
    required this.mrpLabel,
    required this.mrpNote,
    required this.hasGst,
    required this.gstLabel,
    required this.availability,
    required this.pricing,
    required this.buyable,
    required this.hasSupplierLabel,
    required this.supplierLabel,
    required this.overview,
    required this.sections,
    required this.similar,
    required this.hasHistory,
    required this.historyLabel,
  });

  /// One backend label, e.g. `pdp_overview_title`. Missing reads as '' — never
  /// a Dart-side default, which would be the app writing user-facing copy.
  String label(String key) => labels[key] ?? '';

  static String _s(Object? v) => v?.toString() ?? '';

  static Map<String, String> _labels(Object? raw) {
    if (raw is! Map) return const {};
    return raw.map((k, v) => MapEntry(k.toString(), _s(v)));
  }

  factory ProductDetail.fromMap(Map<String, dynamic> m) {
    final labels = _labels(m['labels']);

    // ok:false still carries `labels`, so the not-found page renders backend
    // copy rather than a string typed here.
    if (m['ok'] != true) {
      return ProductDetail.notFound(labels);
    }

    final header = (m['header'] as Map?)?.cast<String, dynamic>() ?? const {};
    final price = (m['price'] as Map?)?.cast<String, dynamic>() ?? const {};
    final stock = (m['stock'] as Map?)?.cast<String, dynamic>() ?? const {};
    final hist = (m['my_history'] as Map?)?.cast<String, dynamic>() ?? const {};

    return ProductDetail(
      ok: true,
      id: _s(m['id']),
      labels: labels,
      name: _s(header['name']),
      company: _s(header['company']),
      packLabel: _s(header['pack_label']),
      formChip: _s(header['form_chip']),
      rxRequired: header['rx_required'] == true,
      images: ((header['images'] as List?) ?? const [])
          .map(_s)
          .where((s) => s.isNotEmpty)
          .toList(growable: false),
      hasMrp: price['has_mrp'] == true,
      mrpLabel: _s(price['mrp_label']),
      mrpNote: _s(price['mrp_note']),
      hasGst: price['has_gst'] == true,
      gstLabel: _s(price['gst_label']),
      availability: Availability.fromMap(m['availability']),
      pricing: Pricing.fromMap(m['pricing']),
      buyable: stock['buyable'] == true,
      hasSupplierLabel: stock['has_supplier_label'] == true,
      supplierLabel: _s(stock['supplier_label']),
      overview: ((m['overview'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => PdOverviewRow(
              label: _s(r['label']), value: _s(r['value'])))
          .toList(growable: false),
      sections: ((m['sections'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => PdSection(title: _s(r['title']), body: _s(r['body'])))
          .toList(growable: false),
      similar: ((m['similar'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => PdSimilar(
                id: _s(r['id']),
                name: _s(r['name']),
                company: _s(r['company']),
                packLabel: _s(r['pack_label']),
                formChip: _s(r['form_chip']),
                image: _s(r['image']),
                mrpLabel: _s(r['mrp_label']),
              ))
          .toList(growable: false),
      hasHistory: hist['has'] == true,
      historyLabel: _s(hist['label']),
    );
  }

  /// The not-found page. Carries the backend's own labels so even this state
  /// shows no Dart-authored copy.
  factory ProductDetail.notFound(Map<String, String> labels) => ProductDetail(
        ok: false,
        id: '',
        labels: labels,
        name: '',
        company: '',
        packLabel: '',
        formChip: '',
        rxRequired: false,
        images: const [],
        hasMrp: false,
        mrpLabel: '',
        mrpNote: '',
        hasGst: false,
        gstLabel: '',
        availability: null,
        pricing: null,
        buyable: false,
        hasSupplierLabel: false,
        supplierLabel: '',
        overview: const [],
        sections: const [],
        similar: const [],
        hasHistory: false,
        historyLabel: '',
      );
}

class PdOverviewRow {
  final String label;
  final String value;
  const PdOverviewRow({required this.label, required this.value});
}

class PdSection {
  final String title;
  final String body;
  const PdSection({required this.title, required this.body});
}

class PdSimilar {
  final String id;
  final String name;
  final String company;
  final String packLabel;
  final String formChip;
  final String image;
  final String mrpLabel;
  const PdSimilar({
    required this.id,
    required this.name,
    required this.company,
    required this.packLabel,
    required this.formChip,
    required this.image,
    required this.mrpLabel,
  });
}
