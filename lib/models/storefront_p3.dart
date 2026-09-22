import 'product.dart';

/// CHANGE #638 — payload models for the company page and the stock-notify
/// feature. Parsing only: no formatting, no derivation, no invented text.

/// One page of `storefront_company_page(p_key, p_offset, p_limit)`.
class CompanyPage {
  final bool ok;

  /// 'company_not_found' when the key is unknown. Empty when ok.
  final String error;

  final String label;
  final String key;
  final String countLabel;

  /// CHANGE #799 — the header's own furniture: the initial the logo box falls
  /// back to, and the salts this company actually makes. `saltCloudHas` is the
  /// backend's flag, so a company with none draws no section at all rather
  /// than an empty heading.
  ///
  /// The cloud arrives from its OWN call (`company_salt_cloud`), after the
  /// first page of products is already on screen: the group-by behind it costs
  /// a second on a big marketer and a header must not hold the grid.
  final String iconLetter;
  final bool saltCloudHas;
  final String saltCloudTitle;
  final List<({String key, String label, String countLabel})> saltCloud;
  final String backLabel;

  /// CMD #2118 — "Search in this company". The hint, the empty line and the
  /// term the payload was built for are all the backend's; the box is a box.
  final String searchHint;
  final String emptyLabel;
  final String q;

  final List<Product> items;
  final int offset;

  /// The BACKEND's answer to "is there another page?". The app never infers
  /// this from `items.length == limit`, which is wrong on an exact boundary.
  final bool hasMore;

  const CompanyPage({
    required this.ok,
    required this.error,
    required this.label,
    required this.key,
    required this.countLabel,
    required this.iconLetter,
    required this.saltCloudHas,
    required this.saltCloudTitle,
    required this.saltCloud,
    required this.backLabel,
    required this.searchHint,
    required this.emptyLabel,
    required this.q,
    required this.items,
    required this.offset,
    required this.hasMore,
  });

  static const CompanyPage failed = CompanyPage(
    ok: false,
    error: '',
    label: '',
    key: '',
    countLabel: '',
    iconLetter: '',
    saltCloudHas: false,
    saltCloudTitle: '',
    saltCloud: [],
    backLabel: '',
    searchHint: '',
    emptyLabel: '',
    q: '',
    items: <Product>[],
    offset: 0,
    hasMore: false,
  );

  bool get notFound => !ok && error == 'company_not_found';

  factory CompanyPage.fromMap(Map<String, dynamic> m) {
    if (m['ok'] != true) {
      return CompanyPage(
        ok: false,
        error: m['error']?.toString() ?? '',
        label: '',
        key: '',
        countLabel: '',
        iconLetter: '',
        saltCloudHas: false,
        saltCloudTitle: '',
        saltCloud: const [],
        backLabel: '',
        searchHint: '',
        emptyLabel: '',
        q: '',
        items: const [],
        offset: 0,
        hasMore: false,
      );
    }
    final c = (m['company'] as Map?)?.cast<String, dynamic>() ?? const {};
    return CompanyPage(
      ok: true,
      error: '',
      label: c['label']?.toString() ?? '',
      key: c['key']?.toString() ?? '',
      countLabel: c['count_label']?.toString() ?? '',
      iconLetter: c['icon_letter']?.toString() ?? '',
      saltCloudHas: false,
      saltCloudTitle: '',
      saltCloud: const [],
      backLabel: m['back_label']?.toString() ?? '',
      searchHint: m['search_hint']?.toString() ?? '',
      emptyLabel: m['empty_label']?.toString() ?? '',
      q: m['q']?.toString() ?? '',
      items: ((m['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Product.fromHomeCard(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      offset: (m['offset'] as num?)?.toInt() ?? 0,
      hasMore: m['has_more'] == true,
    );
  }
}

/// CMD #2118 — one company as `storefront_company_search` returns it: the
/// name, the count sentence and the key that opens its page. Nothing is
/// computed here — `countLabel` is already "668 products" in the payload.
class CompanyHit {
  final String key;
  final String label;
  final String countLabel;

  /// CMD #2165 — the single character the row's tile shows. It is the
  /// BACKEND's letter: taking `label[0]` in Dart is a rule about names
  /// (leading punctuation, a numeral, an accented initial) and rules about
  /// names live in Postgres. Empty means the payload sent none and the tile
  /// stays blank rather than inventing a mark.
  final String iconLetter;

  const CompanyHit({
    required this.key,
    required this.label,
    required this.countLabel,
    this.iconLetter = '',
  });

  factory CompanyHit.fromMap(Map<String, dynamic> m) => CompanyHit(
        key: m['key']?.toString() ?? '',
        label: m['label']?.toString() ?? '',
        countLabel: m['count_label']?.toString() ?? '',
        iconLetter: m['icon_letter']?.toString() ?? '',
      );
}

/// CMD #2165 — every size and colour the Companies block draws with, as
/// `storefront_search_page().companies_style` sends them.
///
/// The design fixes a 60dp row, a 40dp tile and 14.5 / 12.5 / 13 sp text —
/// numbers that sit between the Ds type steps. Rather than writing them into
/// the widget (which the design-literal gate rightly refuses) they travel in
/// the payload, so the redline is retuned with one `app_settings` UPDATE and
/// no deploy. Every field falls back to its Ds token when the payload omits
/// it, which is what makes a missing settings row harmless.
class CompanyBlockStyle {
  final double? rowH;
  final double? tile;
  final double? tileRadius;
  final double? titleSize;
  final double? titleTracking;
  final double? labelSize;
  final double? countSize;
  final double? gap;
  final double? padH;
  final double? divider;
  final double? chevron;

  /// Hex strings (`#E8F5EE`), resolved against a Ds colour by the widget.
  final String tileBg;
  final String tileFg;

  const CompanyBlockStyle({
    this.rowH,
    this.tile,
    this.tileRadius,
    this.titleSize,
    this.titleTracking,
    this.labelSize,
    this.countSize,
    this.gap,
    this.padH,
    this.divider,
    this.chevron,
    this.tileBg = '',
    this.tileFg = '',
  });

  static const CompanyBlockStyle none = CompanyBlockStyle();

  static double? _d(Object? v) => v is num ? v.toDouble() : null;

  factory CompanyBlockStyle.fromMap(Map<String, dynamic> m) =>
      CompanyBlockStyle(
        rowH: _d(m['row_h']),
        tile: _d(m['tile']),
        tileRadius: _d(m['tile_radius']),
        titleSize: _d(m['title_size']),
        titleTracking: _d(m['title_tracking']),
        labelSize: _d(m['label_size']),
        countSize: _d(m['count_size']),
        gap: _d(m['gap']),
        padH: _d(m['pad_h']),
        divider: _d(m['divider']),
        chevron: _d(m['chevron']),
        tileBg: m['tile_bg']?.toString() ?? '',
        tileFg: m['tile_fg']?.toString() ?? '',
      );
}

/// CMD #2118 — the Companies block. It rides on `storefront_search_page` above
/// the medicine results, and the "Shop by company" filter box draws the same
/// rows from `storefront_company_search`. The heading, the hint and the empty
/// line are the payload's; absent (`none`) means the backend sent no block and
/// the app draws nothing at all.
class CompanyHits {
  final bool ok;
  final String title;
  final String hint;
  final String emptyLabel;
  final List<CompanyHit> rows;

  /// CMD #2165 — the block's redline, as the payload sent it.
  final CompanyBlockStyle style;

  /// CMD #2165 — the RPC a tapped row opens, named by the backend
  /// (`storefront_company_page`). The route itself still belongs to the
  /// screen; this is the payload saying WHICH page a row means.
  final String rpc;

  const CompanyHits({
    required this.ok,
    required this.title,
    required this.hint,
    required this.emptyLabel,
    required this.rows,
    this.style = CompanyBlockStyle.none,
    this.rpc = '',
  });

  static const CompanyHits none = CompanyHits(
    ok: false,
    title: '',
    hint: '',
    emptyLabel: '',
    rows: <CompanyHit>[],
  );

  bool get has => ok && rows.isNotEmpty;

  factory CompanyHits.fromMap(Map<String, dynamic> m) => CompanyHits(
        ok: m['ok'] == true,
        title: m['title']?.toString() ?? '',
        hint: m['hint']?.toString() ?? '',
        emptyLabel: m['empty_label']?.toString() ?? '',
        rows: ((m['rows'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => CompanyHit.fromMap(Map<String, dynamic>.from(e)))
            .toList(growable: false),
      );

  /// CMD #2165 — the block as the SEARCH envelope carries it.
  ///
  /// `storefront_search_page` decides everything: it caps the list at three,
  /// withholds it below the minimum query length and on every page after the
  /// first, and answers `companies_has` outright. So "is there a block?" is
  /// read from that flag — never inferred from a row count, and never from a
  /// rule the client keeps its own copy of.
  factory CompanyHits.fromEnvelope(Map<String, dynamic> env) {
    final rows = ((env['companies'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => CompanyHit.fromMap(Map<String, dynamic>.from(e)))
        .toList(growable: false);
    return CompanyHits(
      ok: env['companies_has'] == true,
      title: env['companies_title']?.toString() ?? '',
      hint: '',
      emptyLabel: '',
      rows: rows,
      rpc: env['companies_rpc']?.toString() ?? '',
      style: env['companies_style'] is Map
          ? CompanyBlockStyle.fromMap(
              Map<String, dynamic>.from(env['companies_style'] as Map))
          : CompanyBlockStyle.none,
    );
  }
}

/// Result of `wishlist_toggle(p_product_id)`.
class WishlistResult {
  final bool ok;
  final bool isWishlisted;
  final String toast;
  final String error;

  const WishlistResult({
    required this.ok,
    required this.isWishlisted,
    required this.toast,
    required this.error,
  });

  static const WishlistResult failed =
      WishlistResult(ok: false, isWishlisted: false, toast: '', error: '');

  bool get loginRequired => error == 'login_required';

  factory WishlistResult.fromMap(Map<String, dynamic> m) => WishlistResult(
        ok: m['ok'] == true,
        isWishlisted: m['is_wishlisted'] == true,
        toast: m['toast']?.toString() ?? '',
        error: m['error']?.toString() ?? '',
      );
}

/// Result of `stock_notify_request(p_product_id)`.
class NotifyResult {
  final bool ok;
  final bool subscribed;

  /// The confirmation to show, worded by the backend. Printed verbatim.
  final String toast;
  final String error;

  const NotifyResult({
    required this.ok,
    required this.subscribed,
    required this.toast,
    required this.error,
  });

  static const NotifyResult failed =
      NotifyResult(ok: false, subscribed: false, toast: '', error: '');

  /// The one error the app acts on rather than just reports: it routes to
  /// login. Every other failure surfaces the backend's own text.
  bool get loginRequired => error == 'login_required';

  factory NotifyResult.fromMap(Map<String, dynamic> m) => NotifyResult(
        ok: m['ok'] == true,
        subscribed: m['subscribed'] == true,
        toast: m['toast']?.toString() ?? '',
        error: m['error']?.toString() ?? '',
      );
}

/// `my_stock_notifications()` — the back-in-stock strip.
class BackInStock {
  final bool ok;

  /// The strip heading, from the storefront_ui_label table.
  final String title;
  final List<Product> items;

  const BackInStock({
    required this.ok,
    required this.title,
    required this.items,
  });

  static const BackInStock empty =
      BackInStock(ok: false, title: '', items: <Product>[]);

  /// The strip renders only when the backend actually sent products.
  bool get show => ok && items.isNotEmpty;

  /// The ids currently on screen — handed straight back to
  /// `stock_notify_seen` so the strip clears next visit.
  List<int> get ids => items
      .map((p) => int.tryParse(p.id))
      .whereType<int>()
      .toList(growable: false);

  factory BackInStock.fromMap(Map<String, dynamic> m) => BackInStock(
        ok: m['ok'] == true,
        title: m['title']?.toString() ?? '',
        items: ((m['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Product.fromHomeCard(Map<String, dynamic>.from(e)))
            .toList(growable: false),
      );
}


/// CHANGE #799 — `company_salt_cloud(p_key)`, the company header's salt list.
///
/// Its own payload because it is its own call. `has` is the backend's verdict,
/// so a company with no salt data draws no section rather than a heading over
/// nothing.
class CompanySaltCloud {
  final bool has;
  final String title;
  final List<({String key, String label, String countLabel})> items;

  const CompanySaltCloud({
    required this.has,
    required this.title,
    required this.items,
  });

  static const CompanySaltCloud none =
      CompanySaltCloud(has: false, title: '', items: []);

  factory CompanySaltCloud.fromMap(Map<String, dynamic> m) => CompanySaltCloud(
        has: m['has'] == true,
        title: (m['title'] ?? '').toString(),
        items: ((m['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => (
                  key: (e['key'] ?? '').toString(),
                  label: (e['label'] ?? '').toString(),
                  countLabel: (e['count_label'] ?? '').toString(),
                ))
            .toList(growable: false),
      );
}
