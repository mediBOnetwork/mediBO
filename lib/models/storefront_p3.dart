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
      items: ((m['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Product.fromHomeCard(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      offset: (m['offset'] as num?)?.toInt() ?? 0,
      hasMore: m['has_more'] == true,
    );
  }
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
