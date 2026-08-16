/// CHANGE #173 — the reorder screen's only decisions, in one testable place.
///
/// The screen itself renders `reorder_suggestions()` verbatim. The few things
/// it must still do in Dart — split the payload into the two sections it draws,
/// read a label without inventing a fallback, and turn what the pharmacy typed
/// into RPC params — live here so `test/protected/reorder_suite_test.dart` can
/// hold them down without a network, a Supabase client or a widget tree.
library;

class ReorderSuggestions {
  final Map<String, dynamic> payload;
  const ReorderSuggestions(this.payload);

  bool get hasHistory => payload['has_history'] == true;
  bool get hasDue => payload['has_due'] == true;

  /// Every row, in the order the backend ranked them. Never re-sorted here:
  /// "due first, then most overdue, then most frequent" is the server's call.
  List<Map<String, dynamic>> get items => ((payload['items'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList(growable: false);

  /// The two sections the screen draws. Partitioning preserves payload order
  /// inside each section — it is a filter, not a sort.
  List<Map<String, dynamic>> get due =>
      items.where((e) => e['due'] == true).toList(growable: false);
  List<Map<String, dynamic>> get rest =>
      items.where((e) => e['due'] != true).toList(growable: false);

  /// A screen-level string. An absent key is empty — never a Dart word, so a
  /// missing backend label shows as nothing rather than as English invented here.
  String label(String key) => (payload[key] ?? '').toString();

  /// A row-level string, same rule.
  static String field(Map<String, dynamic> item, String key) =>
      (item[key] ?? '').toString();

  /// Availability is the backend's flag, never a stock number read here.
  static bool canAdd(Map<String, dynamic> item) => item['can_add'] == true;

  /// Whether the low-stock reminder is currently on for this row.
  static bool remindOn(Map<String, dynamic> item) => item['remind_on'] == true;
}

/// The params for `reorder_prefs_set`. The shelf level is optional: an empty or
/// unparseable box means "no shelf level", which must reach the backend as NULL
/// so it CLEARS the stored one — sending 0 would mean a real shelf level of 0.
class ReorderPrefsRequest {
  static Map<String, dynamic> build({
    required String productId,
    required String shelfText,
    required bool notify,
  }) =>
      <String, dynamic>{
        'p_product_id': productId,
        'p_shelf_level': int.tryParse(shelfText.trim()),
        'p_notify': notify,
      };
}
