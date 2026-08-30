// CHANGE #307 — the partner surface's one door to the backend.
//
// A partner is a zone-locked fulfilment login. Every string, every tile, every
// permission and the zone itself arrive from `partner_home()`; nothing on this
// class decides anything. `partner_open()` is asked BEFORE a screen is pushed,
// so a permission change lands on the very next tap with no cache to clear —
// and the same call is what writes the audit row.
import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature every partner screen accepts, so a test can hand it a payload
/// instead of a network.
typedef PartnerRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

class PartnerApi {
  PartnerApi._();

  static Future<Map<String, dynamic>> call(
      String fn, Map<String, dynamic> params) async {
    final raw = await Supabase.instance.client
        .rpc(fn, params: params.isEmpty ? null : params);
    final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
    return map is Map ? Map<String, dynamic>.from(map) : <String, dynamic>{};
  }

  static Future<Map<String, dynamic>> home() => call('partner_home', const {});

  static Future<Map<String, dynamic>> open(String featureKey) =>
      call('partner_open', {'p_feature': featureKey});
}
