import 'package:flutter/foundation.dart';

/// CHANGE #638 — the storefront's user-facing strings, fetched once.
///
/// `storefront_labels()` returns the whole `storefront_ui_label` table as one
/// flat object. The product page already receives its labels inside the
/// `product_detail` payload, but a feed CARD carries no labels of its own, and
/// asking per card would be one RPC per tile. So the set is loaded once and
/// read synchronously from here.
///
/// This is a cache, never a source of truth: it is only ever filled from the
/// backend, and a miss returns '' rather than a word chosen in Dart. A control
/// whose label is '' renders nothing — which is correct, because a string the
/// backend did not send is a string this app is not allowed to invent.
class StorefrontLabels {
  StorefrontLabels._();

  static Map<String, String> _labels = const {};

  static bool get isLoaded => _labels.isNotEmpty;

  /// One label. Missing reads as '' — never a Dart-side default.
  static String get(String key) => _labels[key] ?? '';

  /// Adopts a freshly fetched label set. Ignores an empty set so a failed
  /// fetch never wipes labels that are already on screen.
  static void adopt(Map<String, String> next) {
    if (next.isEmpty) return;
    _labels = Map.unmodifiable(next);
  }

  @visibleForTesting
  static void seed(Map<String, String> m) => _labels = Map.unmodifiable(m);

  @visibleForTesting
  static void reset() => _labels = const {};

  // Keys used by this build.
  static const kNotify = 'card_notify_label';
  static const kNotifySubscribed = 'notify_subscribed_label';
  static const kOutOfStock = 'stock_out_label';

  /// CHANGE #673 — the search field's placeholder. It used to be the Dart
  /// literal 'Search for medicines', which meant the app was telling the user
  /// what the catalogue contains. It contains companies and brands too, and
  /// changing that sentence should never have needed a build.
  static const kSearchHint = 'search_hint';
}
