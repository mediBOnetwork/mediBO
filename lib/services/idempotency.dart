import 'dart:math';

/// CHANGE #472 — one action id per user INTENT, not per attempt.
///
/// The backend edges (`place_order_v2`, `sup_record_payment`,
/// `settlement_record_payment`, `refund_request`, …) each take a
/// `p_client_action_id` and answer a repeat with the first answer instead of
/// applying the money a second time. That guarantee is only as good as the
/// key: if the screen mints a fresh uuid on every tap, every tap is a new
/// action and the ledger never matches.
///
/// So the rule this file exists to enforce is: **mint once when the user
/// commits to the action, reuse it for every retry, and clear it only when the
/// action has actually succeeded.** `ActionKey` is deliberately tiny and has no
/// dependencies, so the protected test can drive it on the Dart VM.
///
/// The house shape this follows is delivery_replay's offline queue, which has
/// carried a `client_action_id` per queued action since #462.
class ActionKey {
  ActionKey._();

  static final Random _rng = Random.secure();

  /// A v4 uuid. `Uuid` is not a dependency of this package and a key only has
  /// to be unique, not meaningful.
  static String mint() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 1
    String h(int s, int e) =>
        b.sublist(s, e).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
  }
}

/// Holds the key for ONE in-flight user intent.
///
/// ```dart
/// final _placeOrder = ActionSlot();          // one per screen, not per tap
/// ...
/// final res = await rpc('place_order_v2',
///     params: {'p_client_action_id': _placeOrder.key});
/// if (ok) _placeOrder.done();                // next order gets a new key
/// ```
///
/// A failed attempt keeps its key, so the retry is the SAME action. Only
/// success (or an explicit abandon) starts a new one.
class ActionSlot {
  String? _key;

  /// The key for the action in flight, minting one on first use.
  String get key => _key ??= ActionKey.mint();

  /// True once a key has been handed out and not yet cleared.
  bool get isInFlight => _key != null;

  /// The action landed. The next intent is a genuinely new action.
  void done() => _key = null;

  /// The user walked away from this action without it landing.
  void abandon() => _key = null;
}
