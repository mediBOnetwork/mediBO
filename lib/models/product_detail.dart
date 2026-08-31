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

  /// CMD #367 (row 177) — the supply trust strip. Fill rate + cold chain,
  /// computed and worded by `product_trust_strip()`. There is deliberately NO
  /// expiry field: expiry and batch change with every purchase, so a
  /// minimum-expiry promise made before the stock is bought would be false.
  final PdTrust trust;

  final List<PdOverviewRow> overview;
  final List<PdSection> sections;
  final List<PdSimilar> similar;

  /// CMD #366 (row 171) — the PRICED substitute block. `similar` above is the
  /// original salt rail and keeps its exact shape (a protected test pins it);
  /// this is the same mechanism extended, as Om asked, rather than a second
  /// rail alongside it: normalised salt+strength+form, a real price, and a
  /// saving computed net-rate against net-rate. It is deliberately possible
  /// for an item here to carry NO price, NO margin and NO saving — MRP is the
  /// legal ceiling, not a rate we sell at, so a saving derived from it would
  /// be a number we invented.
  final PdSubstitutes substitutes;

  /// CMD #366 (row 175) — "usually delivered in ...", the rolling average of
  /// our OWN past deliveries to this area. `has` is false until enough real
  /// deliveries exist, and then the page shows nothing at all rather than a
  /// promise we never measured.
  final PdPromise deliveryPromise;

  final bool hasHistory;
  final String historyLabel;

  // wishlist — gated to approved customers; populated by product_detail()
  final bool showWishlist;
  final bool isWishlisted;

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
    required this.trust,
    required this.overview,
    required this.sections,
    required this.similar,
    required this.substitutes,
    required this.deliveryPromise,
    required this.hasHistory,
    required this.historyLabel,
    required this.showWishlist,
    required this.isWishlisted,
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
      trust: PdTrust.fromMap(m['trust']),
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
      substitutes: PdSubstitutes.fromMap(m['substitutes']),
      deliveryPromise: PdPromise.fromMap(m['delivery_promise']),
      hasHistory: hist['has'] == true,
      historyLabel: _s(hist['label']),
      showWishlist: m['show_wishlist'] == true,
      isWishlisted: m['is_wishlisted'] == true,
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
        trust: const PdTrust.empty(),
        overview: const [],
        sections: const [],
        similar: const [],
        substitutes: const PdSubstitutes.empty(),
        deliveryPromise: const PdPromise.empty(),
        hasHistory: false,
        historyLabel: '',
        showWishlist: false,
        isWishlisted: false,
      );
}

/// CMD #366 row 171. Every string here is `same_composition_options()`'s —
/// heading, note, empty state, the match label and the saving sentence. The
/// widget prints them in payload order and computes nothing, least of all a
/// price comparison.
class PdSubstitutes {
  final bool has;
  final String heading;
  final String note;
  final String empty;
  final List<PdSubstitute> items;
  const PdSubstitutes({
    required this.has,
    required this.heading,
    required this.note,
    required this.empty,
    required this.items,
  });
  const PdSubstitutes.empty()
      : has = false,
        heading = '',
        note = '',
        empty = '',
        items = const [];

  factory PdSubstitutes.fromMap(Object? raw) {
    if (raw is! Map) return const PdSubstitutes.empty();
    final m = raw.cast<String, dynamic>();
    return PdSubstitutes(
      has: m['has'] == true,
      heading: ProductDetail._s(m['heading']),
      note: ProductDetail._s(m['note']),
      empty: ProductDetail._s(m['empty']),
      items: ((m['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => PdSubstitute.fromMap(r.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }
}

class PdSubstitute {
  final String id;
  final String name;
  final String company;
  final String packLabel;
  final String image;
  final String matchLabel;

  /// The same pricing block every card reads — so the substitute's price and
  /// the catalogue's price can never disagree.
  final Pricing? pricing;

  /// Present only when BOTH this item and the one being viewed have a real
  /// trade rate. No rate on either side => hasSaving is false and there is no
  /// line, never a "saves 0%".
  final bool hasSaving;
  final String savingLabel;

  /// Present only when the backend emitted has_margin, which needs
  /// pricing_ready AND an entitled viewer.
  final bool hasMargin;
  final String marginLabel;

  const PdSubstitute({
    required this.id,
    required this.name,
    required this.company,
    required this.packLabel,
    required this.image,
    required this.matchLabel,
    required this.pricing,
    required this.hasSaving,
    required this.savingLabel,
    required this.hasMargin,
    required this.marginLabel,
  });

  factory PdSubstitute.fromMap(Map<String, dynamic> m) {
    final saving = (m['saving'] as Map?)?.cast<String, dynamic>() ?? const {};
    final margin = (m['margin'] as Map?)?.cast<String, dynamic>() ?? const {};
    final chip = (margin['chip'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PdSubstitute(
      id: ProductDetail._s(m['id']),
      name: ProductDetail._s(m['name']),
      company: ProductDetail._s(m['company']),
      packLabel: ProductDetail._s(m['pack_label']),
      image: ProductDetail._s(m['image']),
      matchLabel: ProductDetail._s(m['match_label']),
      pricing: m['pricing'] is Map
          ? Pricing.fromMap((m['pricing'] as Map).cast<String, dynamic>())
          : null,
      hasSaving: saving['has'] == true,
      savingLabel: ProductDetail._s(saving['label']),
      hasMargin: margin['has'] == true,
      marginLabel: ProductDetail._s(chip['label']),
    );
  }
}

/// CMD #366 row 175. `has` is the backend's answer to "have we delivered here
/// enough times to promise anything", never a client-side sample count.
class PdPromise {
  final bool has;
  final String label;
  final String note;
  const PdPromise({required this.has, required this.label, required this.note});
  const PdPromise.empty() : has = false, label = '', note = '';

  factory PdPromise.fromMap(Object? raw) {
    if (raw is! Map) return const PdPromise.empty();
    final m = raw.cast<String, dynamic>();
    return PdPromise(
      has: m['has'] == true,
      label: ProductDetail._s(m['label']),
      note: ProductDetail._s(m['note']),
    );
  }
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


/// One chip on the PDP trust strip. Every field is a backend string — the app
/// picks no words and computes no percentage.
class PdTrustChip {
  final String key;
  final String label;
  final String note;
  final String tone;
  const PdTrustChip({
    required this.key,
    required this.label,
    required this.note,
    required this.tone,
  });
}

/// The trust strip. `has` is the backend's own verdict on whether there is
/// anything worth showing — the page never re-derives it from chips.length,
/// and a product nobody has asked for yet shows nothing rather than an
/// invented 100%.
class PdTrust {
  final bool has;
  final String title;
  final List<PdTrustChip> chips;
  const PdTrust({required this.has, required this.title, required this.chips});
  const PdTrust.empty()
      : has = false,
        title = '',
        chips = const [];

  factory PdTrust.fromMap(Object? raw) {
    if (raw is! Map) return const PdTrust.empty();
    return PdTrust(
      has: raw['has'] == true,
      title: raw['title']?.toString() ?? '',
      chips: ((raw['chips'] as List?) ?? const [])
          .whereType<Map>()
          .map((c) => PdTrustChip(
                key: c['key']?.toString() ?? '',
                label: c['label']?.toString() ?? '',
                note: c['note']?.toString() ?? '',
                tone: c['tone']?.toString() ?? '',
              ))
          .toList(growable: false),
    );
  }
}
