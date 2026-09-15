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
      items: ((m['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Product.fromHomeCard(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      offset: (m['offset'] as num?)?.toInt() ?? 0,
      hasMore: m['has_more'] == true,
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
