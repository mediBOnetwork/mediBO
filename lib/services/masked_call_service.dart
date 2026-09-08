// CHANGE #404 — the app's whole half of the masking layer.
//
// Two calls, and neither of them knows a phone number:
//
//   targets(orderIds)  -> which masked call buttons this viewer gets, with the
//                         backend's own labels. The screen renders the list.
//   place(order, role) -> the edge function resolves both legs, checks the
//                         allow matrix, reserves a DID and returns a session.
//
// Nothing here decides whether a call is permitted, what a button says, or who
// the counterparty is. If this file ever needs to know a counterparty's number
// to do its job, the masking has already failed.
import 'package:supabase_flutter/supabase_flutter.dart';

/// One masked-call button, exactly as the backend described it.
class MaskedCallTarget {
  const MaskedCallTarget({
    required this.orderId,
    required this.targetRole,
    required this.label,
    required this.privacyNote,
  });

  final String orderId;
  final String targetRole;
  final String label;
  final String privacyNote;

  static MaskedCallTarget? from(String orderId, Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    if (m['has'] != true) return null;
    final role = (m['target_role'] ?? '').toString();
    final label = (m['label'] ?? '').toString();
    if (role.isEmpty || label.isEmpty) return null;
    return MaskedCallTarget(
      orderId: (m['order_id'] ?? orderId).toString(),
      targetRole: role,
      label: label,
      privacyNote: (m['privacy_note'] ?? '').toString(),
    );
  }
}

/// The reply to a placed call. `did` is the MASKING number — the only number
/// that ever reaches a device, and the reason it is safe to print.
class MaskedCallResult {
  const MaskedCallResult({
    required this.ok,
    required this.mode,
    required this.did,
    required this.message,
    required this.privacyNote,
    required this.stubNotice,
    required this.targetName,
  });

  final bool ok;

  /// `provider_dials` — the provider is ringing both legs; the app shows the
  /// message and does nothing. `user_dials` — the app opens `tel:` on the DID.
  final String mode;
  final String did;
  final String message;
  final String privacyNote;
  final String stubNotice;
  final String targetName;

  bool get shouldDial => ok && mode == 'user_dials' && did.isNotEmpty;

  factory MaskedCallResult.from(Object? raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return MaskedCallResult(
      ok: m['ok'] == true,
      mode: (m['mode'] ?? '').toString(),
      did: (m['did'] ?? '').toString(),
      // A refusal carries the backend's own sentence under `message`; there is
      // no Dart fallback wording on purpose, because inventing one here is how a
      // screen starts disagreeing with the server about why a call failed.
      message: (m['message'] ?? '').toString(),
      privacyNote: (m['privacy_note'] ?? '').toString(),
      stubNotice: (m['stub_notice'] ?? '').toString(),
      targetName: (m['target_name'] ?? '').toString(),
    );
  }
}

class MaskedCallService {
  static SupabaseClient get _c => Supabase.instance.client;

  /// Injectable seams so the protected test can drive both paths with no
  /// network. Production leaves them null and gets Supabase.
  static Future<Map<String, dynamic>> Function(List<String> orderIds)? targetsFn;
  static Future<Map<String, dynamic>> Function(String orderId, String role)? placeFn;

  /// order_id -> the buttons this viewer gets on it. Orders with no permitted
  /// counterparty are simply absent from the map.
  static Future<Map<String, List<MaskedCallTarget>>> targets(List<String> orderIds) async {
    if (orderIds.isEmpty) return const {};
    final Map<String, dynamic> res = targetsFn != null
        ? await targetsFn!(orderIds)
        : Map<String, dynamic>.from(
            (await _c.rpc('call_mask_targets', params: {'p_order_ids': orderIds})) as Map);

    final orders = res['orders'];
    if (orders is! Map) return const {};

    final out = <String, List<MaskedCallTarget>>{};
    orders.forEach((key, value) {
      if (value is! List) return;
      final id = key.toString();
      final list = <MaskedCallTarget>[];
      for (final raw in value) {
        final t = MaskedCallTarget.from(id, raw);
        if (t != null) list.add(t);
      }
      if (list.isNotEmpty) out[id] = list;
    });
    return out;
  }

  /// Place the call. The app sends an order and a role — never a number.
  static Future<MaskedCallResult> place(String orderId, String targetRole) async {
    if (placeFn != null) {
      return MaskedCallResult.from(await placeFn!(orderId, targetRole));
    }
    final res = await _c.functions.invoke('mask-call',
        body: {'order_id': orderId, 'target_role': targetRole});
    return MaskedCallResult.from(res.data);
  }
}
