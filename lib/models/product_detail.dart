import 'product.dart' show Availability, Pricing, PurchaseOverlay;
import 'product_reviews.dart' show RatingSummary;

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

  /// CHANGE #461/#170 — the prescription class from `rx_badge()`, and the
  /// buyer's drug-licence state for it. Both are the backend's words:
  /// `rx` is `{has,is_rx,label,title,note,tone}` and `rxLicence` is
  /// `{has,reason,licence,ok_note,...}`. Absent → the PDP shows nothing.
  ///
  /// CMD #1825 — the PDP renders `rx` as a small tag (label + tone) beside
  /// the name. `title` and `note` stay parsed for other surfaces; the licence
  /// state is carried untouched for the cart, where the rule still speaks.
  final Map<String, dynamic>? rx;
  final Map<String, dynamic>? rxLicence;

  bool get hasRxTag => rx?['has'] == true;
  bool get hasRxBlock => hasRxTag;
  bool get isRx => rx?['is_rx'] == true;
  String get rxLabel => (rx?['label'] ?? '').toString();
  String get rxTitle => (rx?['title'] ?? '').toString();
  String get rxNote => (rx?['note'] ?? '').toString();
  Map<String, dynamic>? get rxTone => (rx?['tone'] as Map?)?.cast<String, dynamic>();

  /// The licence line only exists for an Rx product AND a signed-in pharmacy.
  bool get rxLicenceOk => rxLicence?['has'] == true;
  String get rxLicenceNote => (rxLicence?['ok_note'] ?? '').toString();
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
  /// CHANGE #640 — `stock.buyable` is now DERIVED, not read.
  ///
  /// The live bug this closes: product 252328 had `supplier_count = 11` and
  /// `buyable = false` on the same row, so the storefront listed it, the cart
  /// accepted it, and the cart then called it unavailable. Three surfaces, three
  /// different fields, three different answers.
  ///
  /// There is now exactly ONE availability answer in this payload — the
  /// [availability] verdict `storefront_cta()` renders — and every surface reads
  /// it. This field is that verdict's `is_available`, so nothing on the page can
  /// disagree with the button at the bottom of it. `stock.buyable` is consulted
  /// only when the payload carried no verdict at all (an outage fallback), which
  /// is the one case where there is nothing better to read.
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

  /// CMD #791 — the pack shots. `product_gallery()` sends up to five URLs in
  /// slot order (image_url_1..5, which is what `r2_cutover()` rewrites in
  /// place, so these become the R2 URLs the moment a product is migrated and
  /// nothing here changes) plus a PRE-RENDERED "2 / 5" per image. The viewer
  /// prints the counter at the index it is showing; it never builds "x / y".
  final PdGallery gallery;

  /// CMD #791 — salt & strength, form, pack, Rx/OTC, habit forming, cold
  /// chain, storage. One list of {label, value}, both halves stored strings.
  /// A blank column is an ABSENT row, never a dash.
  final PdFacts facts;

  /// CMD #791 — this buyer's own history with the pack. `has` is false for an
  /// anonymous visitor because `purchase_overlay()` returns nothing without a
  /// customer account, not because the page checked a login flag.
  final PurchaseOverlay purchase;

  /// CMD #791 — frequently bought together, from the nightly co-purchase job.
  /// Pairs are formed only between products of the SAME prescription class, so
  /// an OTC pack can never surface a Schedule-H companion.
  final PdCompanions companions;

  /// CMD #1826 — the supply-confidence band. A label, a tone and an optional
  /// sub-line / speed line, ALL worded by `pdp_supply_confidence()`. There is
  /// no count and no supplier name anywhere in it, and `has` is false for a
  /// pack nobody has answered on lately — the page then draws nothing.
  final PdSupply supply;

  /// CMD #1826 — BOTH prices, every time: the MRP row (printed pack ceiling)
  /// and the sale-price row (what the buyer pays, or the backend's "On quote"
  /// copy when no pricing_ready row exists). The sticky bar's main number and
  /// its small MRP are the same block's `sticky` object. Nothing here is
  /// formatted or chosen in Dart.
  final PdPriceLines priceLines;

  /// CMD #1896 — the title block: pack-type pill, name, company and the
  /// rendered pack sentence. `has:false` is a payload older than this change,
  /// and the page then reads the `header` fields it always did.
  final PdTitle title;

  /// CMD #1903 — the pack family, and the only place it appears any more: an
  /// "Other packs" strip under the price. `has` is false for a pack that is
  /// the only one of its brand, so the page draws nothing rather than a strip
  /// with a single chip in it.
  final PdOtherPacks otherPacks;

  final bool hasHistory;
  final String historyLabel;

  // wishlist — gated to approved customers; populated by product_detail()
  final bool showWishlist;
  final bool isWishlisted;

  /// CMD #410 — the reviews aggregate, from product_rating_summary() via
  /// product_detail_v2. `has` is false below the review floor, and then the
  /// header shows NOTHING: a 5.0 written by one customer is an anecdote, not
  /// a rating, and this is a buying screen.
  final RatingSummary rating;

  /// CMD #410 — the compare checkbox's caption and the tray's cap, both the
  /// backend's. The app owns only WHICH products are in the tray.
  final String compareAddLabel;
  final String compareCtaLabel;
  final int compareMax;

  const ProductDetail({
    this.rx,
    this.rxLicence,
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
    this.gallery = const PdGallery.empty(),
    this.facts = const PdFacts.empty(),
    this.purchase = const PurchaseOverlay.absent(),
    this.companions = const PdCompanions.empty(),
    this.supply = const PdSupply.empty(),
    this.priceLines = const PdPriceLines.empty(),
    this.title = const PdTitle.empty(),
    this.otherPacks = const PdOtherPacks.empty(),
    required this.hasHistory,
    required this.historyLabel,
    required this.showWishlist,
    required this.isWishlisted,
    this.rating = RatingSummary.absent,
    this.compareAddLabel = '',
    this.compareCtaLabel = '',
    this.compareMax = 3,
  });

  /// One backend label, e.g. `pdp_overview_title`. Missing reads as '' — never
  /// a Dart-side default, which would be the app writing user-facing copy.
  String label(String key) => labels[key] ?? '';

  /// CHANGE #640 — the ONE add decision for this page.
  ///
  /// Every "can this be bought?" question on the product page resolves here:
  /// the appbar's out-of-stock probe, the stock chip and the bottom bar. They
  /// used to ask three times and could get three answers ([availability] when
  /// present, the raw `stock.buyable` column when not). One getter, one answer.
  bool get canAdd => availability?.canAdd ?? buyable;

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

    // CHANGE #640 — parsed ONCE, so the page cannot end up holding two
    // availability answers for one product.
    final av = Availability.fromMap(m['availability']);

    return ProductDetail(
      ok: true,
      id: _s(m['id']),
      labels: labels,
      name: _s(header['name']),
      company: _s(header['company']),
      packLabel: _s(header['pack_label']),
      formChip: _s(header['form_chip']),
      rxRequired: header['rx_required'] == true,
      rx: (m['rx'] as Map?)?.cast<String, dynamic>(),
      rxLicence: (m['rx_licence'] as Map?)?.cast<String, dynamic>(),
      images: ((header['images'] as List?) ?? const [])
          .map(_s)
          .where((s) => s.isNotEmpty)
          .toList(growable: false),
      hasMrp: price['has_mrp'] == true,
      mrpLabel: _s(price['mrp_label']),
      mrpNote: _s(price['mrp_note']),
      hasGst: price['has_gst'] == true,
      gstLabel: _s(price['gst_label']),
      availability: av,
      pricing: Pricing.fromMap(m['pricing']),
      // CHANGE #640 — one source. The verdict wins whenever there is one; the
      // legacy column is the outage fallback, never a second opinion.
      buyable: av?.isAvailable ?? (stock['buyable'] == true),
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
      gallery: PdGallery.fromMap(m['gallery'], header['images']),
      facts: PdFacts.fromMap(m['facts']),
      purchase: PurchaseOverlay.fromMap(m['purchase']),
      companions: PdCompanions.fromMap(m['companions']),
      supply: PdSupply.fromMap(m['supply']),
      priceLines: PdPriceLines.fromMap(m['price_lines']),
      title: PdTitle.fromMap(m['title']),
      otherPacks: PdOtherPacks.fromMap(m['other_packs']),
      hasHistory: hist['has'] == true,
      historyLabel: _s(hist['label']),
      showWishlist: m['show_wishlist'] == true,
      isWishlisted: m['is_wishlisted'] == true,
      rating: RatingSummary.fromMap(m['rating']),
      compareAddLabel: _s((m['compare'] as Map?)?['add_label']),
      compareCtaLabel: _s((m['compare'] as Map?)?['cta_label']),
      compareMax: ((m['compare'] as Map?)?['max'] is int)
          ? (m['compare'] as Map)['max'] as int
          : int.tryParse(_s((m['compare'] as Map?)?['max'])) ?? 3,
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


/// CMD #791 — one pack shot plus the counter string the backend rendered for
/// its position ("2 / 5"). The viewer prints [counterLabel] verbatim.
class PdGalleryImage {
  final String url;
  final String counterLabel;
  const PdGalleryImage({required this.url, required this.counterLabel});
}

/// CMD #791 — the gallery block.
///
/// [has] and [count] are the backend's, so a product with one shot renders one
/// shot and no dots rather than a page control the app decided to hide. The
/// legacy `header.images` list is still parsed as the fallback when a cached
/// payload predates this change: the gallery is then built from those URLs with
/// EMPTY counter labels, because a counter this app assembled would be exactly
/// the string the backend is supposed to own.
class PdGallery {
  final bool has;
  final int count;
  final String zoomHint;
  final String closeLabel;
  final List<PdGalleryImage> images;

  const PdGallery({
    required this.has,
    required this.count,
    required this.zoomHint,
    required this.closeLabel,
    required this.images,
  });

  const PdGallery.empty()
      : has = false,
        count = 0,
        zoomHint = '',
        closeLabel = '',
        images = const [];

  factory PdGallery.fromMap(Object? raw, Object? legacyImages) {
    if (raw is Map) {
      final m = raw.cast<String, dynamic>();
      final imgs = ((m['images'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => PdGalleryImage(
                url: ProductDetail._s(e['url']),
                counterLabel: ProductDetail._s(e['counter_label']),
              ))
          .where((e) => e.url.isNotEmpty)
          .toList(growable: false);
      if (imgs.isNotEmpty || m['has'] == true) {
        return PdGallery(
          has: m['has'] == true,
          count: (m['count'] is num)
              ? (m['count'] as num).toInt()
              : int.tryParse(ProductDetail._s(m['count'])) ?? imgs.length,
          zoomHint: ProductDetail._s(m['zoom_hint']),
          closeLabel: ProductDetail._s(m['close_label']),
          images: imgs,
        );
      }
    }
    final legacy = ((legacyImages as List?) ?? const [])
        .map(ProductDetail._s)
        .where((s) => s.isNotEmpty)
        .map((u) => PdGalleryImage(url: u, counterLabel: ''))
        .toList(growable: false);
    if (legacy.isEmpty) return const PdGallery.empty();
    return PdGallery(
      has: true,
      count: legacy.length,
      zoomHint: '',
      closeLabel: '',
      images: legacy,
    );
  }
}

/// CMD #791 — one fact row. [key] is the backend's stable identifier for the
/// row (salt / form / pack / rx / habit / cold_chain / storage); the app uses
/// it for nothing but a widget key, because every word to show is already in
/// [label] and [value].
class PdFactRow {
  final String key;
  final String label;
  final String value;
  const PdFactRow({required this.key, required this.label, required this.value});
}

class PdFacts {
  final bool has;
  final String title;
  final List<PdFactRow> rows;
  const PdFacts({required this.has, required this.title, required this.rows});
  const PdFacts.empty() : has = false, title = '', rows = const [];

  factory PdFacts.fromMap(Object? raw) {
    if (raw is! Map) return const PdFacts.empty();
    final m = raw.cast<String, dynamic>();
    return PdFacts(
      has: m['has'] == true,
      title: ProductDetail._s(m['title']),
      rows: ((m['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => PdFactRow(
                key: ProductDetail._s(r['key']),
                label: ProductDetail._s(r['label']),
                value: ProductDetail._s(r['value']),
              ))
          .toList(growable: false),
    );
  }
}

/// CMD #791 — one companion tile. [pricing] and [availability] are the SAME
/// blocks the storefront card reads, so a companion's price and its own card's
/// price cannot drift apart. [supportLabel] is the backend's evidence string
/// ("6 orders"); the app never prints a support NUMBER of its own.
class PdCompanion {
  final String id;
  final String name;
  final String company;
  final String packLabel;
  final String formChip;
  final String image;
  final String supportLabel;
  final Pricing? pricing;
  final Availability? availability;

  const PdCompanion({
    required this.id,
    required this.name,
    required this.company,
    required this.packLabel,
    required this.formChip,
    required this.image,
    required this.supportLabel,
    required this.pricing,
    required this.availability,
  });

  factory PdCompanion.fromMap(Map<String, dynamic> m) => PdCompanion(
        id: ProductDetail._s(m['id']),
        name: ProductDetail._s(m['name']),
        company: ProductDetail._s(m['company']),
        packLabel: ProductDetail._s(m['pack_label']),
        formChip: ProductDetail._s(m['form_chip']),
        image: ProductDetail._s(m['image']),
        supportLabel: ProductDetail._s(m['support_label']),
        pricing: Pricing.fromMap(m['pricing']),
        availability: Availability.fromMap(m['availability']),
      );
}

/// CMD #791 — the co-purchase rail. [has] is the backend's verdict: a product
/// nobody has bought alongside anything else yet shows NO rail, rather than a
/// "you might also like" the platform invented.
class PdCompanions {
  final bool has;
  final String title;
  final String note;
  final List<PdCompanion> items;
  const PdCompanions({
    required this.has,
    required this.title,
    required this.note,
    required this.items,
  });
  const PdCompanions.empty()
      : has = false,
        title = '',
        note = '',
        items = const [];

  factory PdCompanions.fromMap(Object? raw) {
    if (raw is! Map) return const PdCompanions.empty();
    final m = raw.cast<String, dynamic>();
    return PdCompanions(
      has: m['has'] == true,
      title: ProductDetail._s(m['title']),
      note: ProductDetail._s(m['note']),
      items: ((m['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => PdCompanion.fromMap(r.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }
}

/// CMD #1826 — the supply-confidence band, printed verbatim. `tone` is the
/// backend's colour word (success / warning / danger); the page maps it
/// through ONE lookup and never re-derives it from `band` or from anything
/// else in the payload.
class PdSupply {
  final bool has;
  final String band;
  final String label;
  final String tone;
  final bool hasSub;
  final String sub;
  final bool hasSpeed;
  final String speed;
  const PdSupply({
    required this.has,
    required this.band,
    required this.label,
    required this.tone,
    required this.hasSub,
    required this.sub,
    required this.hasSpeed,
    required this.speed,
  });
  const PdSupply.empty()
      : has = false,
        band = '',
        label = '',
        tone = '',
        hasSub = false,
        sub = '',
        hasSpeed = false,
        speed = '';

  factory PdSupply.fromMap(Object? raw) {
    if (raw is! Map || raw['has'] != true) return const PdSupply.empty();
    return PdSupply(
      has: true,
      band: raw['band']?.toString() ?? '',
      label: raw['label']?.toString() ?? '',
      tone: raw['tone']?.toString() ?? '',
      hasSub: raw['has_sub'] == true,
      sub: raw['sub']?.toString() ?? '',
      hasSpeed: raw['has_speed'] == true,
      speed: raw['speed']?.toString() ?? '',
    );
  }
}

/// One labelled price line: a caption, a value that is EITHER a backend-
/// formatted rupee string or the backend's own words ("On quote"), and an
/// optional sub-line. `hasAmount` says which; `tone` says how loud.
class PdPriceLine {
  final String caption;
  final String value;
  final bool hasAmount;
  final bool hasNote;
  final String note;
  final String tone;

  /// CMD #1896 — the MRP is struck when the backend says so. It is not "strike
  /// whenever there is a discount", because whether the printed ceiling is a
  /// ceiling is the backend's statement about the pack, not a conclusion the
  /// page reaches by comparing two numbers it was handed.
  final bool strike;

  /// CMD #1896 — the (i) beside the MRP. `text` is the sentence that used to be
  /// printed under the price; it is a tooltip now, and it is still the
  /// backend's sentence.
  final PdInfoNote info;

  /// CMD #1896 — "₹19.91 / tablet", divided and worded in SQL from the pack
  /// sentence. Absent for a one-unit pack and for a viewer with no trade rate.
  final PdChip perUnit;

  const PdPriceLine({
    required this.caption,
    required this.value,
    required this.hasAmount,
    required this.hasNote,
    required this.note,
    required this.tone,
    this.strike = false,
    this.info = const PdInfoNote.empty(),
    this.perUnit = const PdChip.empty(),
  });
  const PdPriceLine.empty()
      : caption = '',
        value = '',
        hasAmount = false,
        hasNote = false,
        note = '',
        tone = '',
        strike = false,
        info = const PdInfoNote.empty(),
        perUnit = const PdChip.empty();

  factory PdPriceLine.fromMap(Object? raw) {
    if (raw is! Map) return const PdPriceLine.empty();
    return PdPriceLine(
      caption: raw['caption']?.toString() ?? '',
      value: raw['value']?.toString() ?? '',
      hasAmount: raw['has_amount'] == true,
      hasNote: raw['has_note'] == true,
      note: raw['note']?.toString() ?? '',
      tone: raw['tone']?.toString() ?? '',
      strike: raw['strike'] == true,
      info: PdInfoNote.fromMap(raw['info']),
      perUnit: PdChip.fromMap(raw['per_unit']),
    );
  }
}

/// CMD #1896 — a short backend string that may or may not have been sent, with
/// the tone word the page maps to a colour. Used for the pack-type pill, the
/// per-unit line and the discount chip: three places that all had to answer
/// "did the backend send one?" before they answered "what does it say?".
class PdChip {
  final bool has;
  final String label;
  final String tone;
  const PdChip({required this.has, required this.label, required this.tone});
  const PdChip.empty()
      : has = false,
        label = '',
        tone = '';

  factory PdChip.fromMap(Object? raw) {
    if (raw is! Map || raw['has'] != true) return const PdChip.empty();
    final label = raw['label']?.toString() ?? '';
    // `has:true` with nothing to print is still nothing to print.
    if (label.isEmpty) return const PdChip.empty();
    return PdChip(has: true, label: label, tone: raw['tone']?.toString() ?? '');
  }
}

/// CMD #1896 — the words behind an (i): an accessible label and the sentence.
class PdInfoNote {
  final bool has;
  final String label;
  final String text;
  const PdInfoNote({
    required this.has,
    required this.label,
    required this.text,
  });
  const PdInfoNote.empty()
      : has = false,
        label = '',
        text = '';

  factory PdInfoNote.fromMap(Object? raw) {
    if (raw is! Map || raw['has'] != true) return const PdInfoNote.empty();
    final text = raw['text']?.toString() ?? '';
    if (text.isEmpty) return const PdInfoNote.empty();
    return PdInfoNote(
      has: true,
      label: raw['label']?.toString() ?? '',
      text: text,
    );
  }
}

/// CMD #1896 — the title block: the pack-type pill, the name, the company and
/// the pack sentence, all rendered by `product_detail`. `has:false` is an app
/// build reading a payload older than this change, and the page then falls back
/// to the `header` fields it always used.
class PdTitle {
  final bool has;
  final String name;
  final String company;
  final PdChip formChip;
  final PdChip packLine;

  const PdTitle({
    required this.has,
    required this.name,
    required this.company,
    required this.formChip,
    required this.packLine,
  });
  const PdTitle.empty()
      : has = false,
        name = '',
        company = '',
        formChip = const PdChip.empty(),
        packLine = const PdChip.empty();

  factory PdTitle.fromMap(Object? raw) {
    if (raw is! Map || raw['has'] != true) return const PdTitle.empty();
    return PdTitle(
      has: true,
      name: raw['name']?.toString() ?? '',
      company: raw['company']?.toString() ?? '',
      formChip: PdChip.fromMap(raw['form_chip']),
      packLine: PdChip.fromMap(raw['pack_line']),
    );
  }
}

/// The sticky bar's numbers: the sale-price value as the main line and the
/// small MRP beside it, both already worded.
class PdSticky {
  final String main;
  final String mainCaption;
  final String mainTone;
  final bool hasSide;
  final String side;
  const PdSticky({
    required this.main,
    required this.mainCaption,
    required this.mainTone,
    required this.hasSide,
    required this.side,
  });
  const PdSticky.empty()
      : main = '',
        mainCaption = '',
        mainTone = '',
        hasSide = false,
        side = '';

  factory PdSticky.fromMap(Object? raw) {
    if (raw is! Map) return const PdSticky.empty();
    return PdSticky(
      main: raw['main']?.toString() ?? '',
      mainCaption: raw['main_caption']?.toString() ?? '',
      mainTone: raw['main_tone']?.toString() ?? '',
      hasSide: raw['has_side'] == true,
      side: raw['side']?.toString() ?? '',
    );
  }
}

/// CMD #1826 — `price_lines`: the MRP row, the sale-price row and the sticky
/// bar's pair. `has` false only when an older backend sent no block at all,
/// in which case the page falls back to the CHANGE #638 single price.
class PdPriceLines {
  final bool has;
  final PdPriceLine mrp;
  final PdPriceLine sale;
  final PdSticky sticky;

  /// CMD #1896 — "24% off", sent only when a real trade rate exists to
  /// discount from. The page never subtracts one price from another.
  final PdChip discount;

  const PdPriceLines({
    required this.has,
    required this.mrp,
    required this.sale,
    required this.sticky,
    this.discount = const PdChip.empty(),
  });
  const PdPriceLines.empty()
      : has = false,
        mrp = const PdPriceLine.empty(),
        sale = const PdPriceLine.empty(),
        sticky = const PdSticky.empty(),
        discount = const PdChip.empty();

  factory PdPriceLines.fromMap(Object? raw) {
    if (raw is! Map || raw['has'] != true) return const PdPriceLines.empty();
    return PdPriceLines(
      has: true,
      mrp: PdPriceLine.fromMap(raw['mrp']),
      sale: PdPriceLine.fromMap(raw['sale']),
      sticky: PdSticky.fromMap(raw['sticky']),
      discount: PdChip.fromMap(raw['discount']),
    );
  }
}

/// CMD #1903 — the "Other packs" strip: the same brand's other packs, worded
/// by `pdp_other_packs()` inside `product_detail()`.
///
/// The page renders the labels verbatim and switches to the tapped pack's own
/// product id. Nothing here derives a label from a name, and the pack being
/// viewed is always in the list, always [PdPack.selected] — the strip is a
/// switch, not a set of links away from the page.
class PdPack {
  final String productId;
  final String label;
  final bool selected;
  const PdPack(
      {required this.productId, required this.label, required this.selected});
}

class PdOtherPacks {
  final bool has;
  final String title;
  final List<PdPack> items;

  const PdOtherPacks(
      {required this.has, required this.title, required this.items});
  const PdOtherPacks.empty()
      : has = false,
        title = '',
        items = const <PdPack>[];

  factory PdOtherPacks.fromMap(Object? raw) {
    if (raw is! Map || raw['has'] != true) return const PdOtherPacks.empty();
    final items = ((raw['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => PdPack(
              productId: (e['product_id'] ?? '').toString(),
              label: (e['label'] ?? '').toString(),
              selected: e['selected'] == true,
            ))
        .where((p) => p.productId.isNotEmpty && p.label.isNotEmpty)
        .toList(growable: false);
    if (items.length < 2) return const PdOtherPacks.empty();
    return PdOtherPacks(
      has: true,
      title: (raw['title'] ?? '').toString(),
      items: items,
    );
  }
}
