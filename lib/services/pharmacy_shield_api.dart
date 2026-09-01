// CMD #413 — the one door to the expiry watch and the stock check.
//
// Both surfaces are pure renderers. Every rupee, every plural, every "closes in
// 3 days", every tone name and every refusal sentence is built in Supabase and
// arrives in the payload; this file forwards a call and hands back a map. It
// computes nothing, formats nothing and decides nothing — including who may see
// the stock check, which is `pharmacy_shield_entry().is_owner`, resolved in the
// backend from the login itself.
import 'package:supabase_flutter/supabase_flutter.dart';

/// The signature every surface here accepts, so a test hands it a payload
/// instead of a network.
typedef ShieldRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class PharmacyShieldApi {
  PharmacyShieldApi._();

  static Future<Map<String, dynamic>> call(
    String fn,
    Map<String, dynamic> params,
  ) async {
    final raw = await Supabase.instance.client.rpc(
      fn,
      params: params.isEmpty ? null : params,
    );
    final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
    return map is Map ? Map<String, dynamic>.from(map) : <String, dynamic>{};
  }

  /// Which tiles this account may see, with their labels. One cheap call — the
  /// shell holds no label and runs no role test of its own.
  static Future<Map<String, dynamic>> entry() =>
      call('pharmacy_shield_entry', const {});

  // ── expiry watch ──────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> expiryHome() =>
      call('pharmacy_expiry_home', const {});

  static Future<Map<String, dynamic>> expiryItems(
    String bucketKey, {
    int limit = 50,
    int offset = 0,
  }) => call('pharmacy_expiry_items', {
    'p_bucket': bucketKey,
    'p_limit': limit,
    'p_offset': offset,
  });

  /// The one tap. The backend decides what belongs on the list — the screen
  /// never filters by a day count of its own.
  static Future<Map<String, dynamic>> buildReturnList() =>
      call('pharmacy_expiry_return_build', const {});

  static Future<Map<String, dynamic>> returnList(String listId) =>
      call('pharmacy_expiry_return_get', {'p_list_id': listId});

  static Future<Map<String, dynamic>> raiseOnMediBo(
    String listId, {
    String? photoPath,
  }) => call('pharmacy_expiry_return_send', {
    'p_list_id': listId,
    ?'p_photo_path': photoPath,
  });

  // ── stock check (owner only — the gate is the RPC, not this file) ─────────
  static Future<Map<String, dynamic>> startCount({int skus = 10}) =>
      call('pharmacy_count_start', {'p_n': skus});

  static Future<Map<String, dynamic>> countDetail(String sessionId) =>
      call('pharmacy_count_detail', {'p_session_id': sessionId});

  /// Only ANSWERED lines are sent. A line the owner left blank is omitted, never
  /// defaulted to zero — "I did not count it" and "I counted zero" are
  /// different facts and the report must not conflate them.
  static Future<Map<String, dynamic>> submitCount(
    String sessionId,
    List<Map<String, dynamic>> lines,
  ) => call('pharmacy_count_submit', {
    'p_session_id': sessionId,
    'p_lines': lines,
  });

  static Future<Map<String, dynamic>> varianceReport({int days = 7}) =>
      call('pharmacy_variance_report', {'p_days': days});
}
