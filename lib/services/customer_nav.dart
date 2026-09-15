import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

/// CHANGE #630 — the customer bottom bar, as the backend hands it over.
///
/// Om, live on the command: "customer bottom-nav SEQUENCE changes to exactly
/// Home · Catalogue · Bulk · Orders · My Shop (My Shop LAST, Bulk moves to
/// third). Registry sort_order owns it; do not hardcode the order in Dart."
///
/// `customer_nav()` answers with one entry per `customer_nav_slot` row, in the
/// registry's own order, each carrying its label, its icon key, the badge it
/// wears and the shell page it opens. It also resolves WHO is offered each
/// slot (the row's `visibility`) against the caller, which is why the answer
/// changes on login and why this notifier re-asks on an identity change: a bar
/// fetched once at boot would show a signed-out visitor's four slots for the
/// rest of the session.
///
/// Same shape as PosEntry (#411), StockEntry (#412) and ShopBadge (#536) — the
/// shell listens, so the bar's contents never become the shell's business, and
/// home_shell.dart does not grow a fetch, a cache and an auth listener for
/// every registry it draws.
class CustomerNav {
  CustomerNav._();

  static final ValueNotifier<List<Map<String, dynamic>>> value =
      ValueNotifier<List<Map<String, dynamic>>>(const []);

  /// The auth identity the current answer was fetched for. Login, account
  /// switch and logout all change which slots come back.
  static String? _boundUid;
  static bool _bound = false;

  static Future<void> load() async {
    try {
      final raw = await Supabase.instance.client.rpc('customer_nav');
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (map is! Map) return;
      final slots = ((map['slots'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
      if (slots.isEmpty) return; // never blank a bar on a thin answer
      _boundUid = Supabase.instance.client.auth.currentUser?.id;
      _bound = true;
      value.value = slots;
      RenderLog.write('c630_nav_slots',
          slots.map((s) => (s['key'] ?? '').toString()).join('>'));
    } catch (_) {
      // A bar that cannot ask keeps whatever it has. Boot resilience rule.
    }
  }

  /// The auth identity moved — re-ask. Never blanks what is already drawn: a
  /// failed refresh keeps the last good answer.
  static void syncIdentity() {
    if (!_bound) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == _boundUid) return;
    _boundUid = uid;
    load();
  }
}
