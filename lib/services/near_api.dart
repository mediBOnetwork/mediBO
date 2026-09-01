// CMD #426 — the /near door to the backend.
//
// Two audiences through one file. The CONSUMER side is anonymous: no login, no
// session, no app store — a stranger opens medibo.in/near on a phone and asks
// whether anyone nearby is likely to have a medicine. The PHARMACY side is the
// owner deciding whether to be listed at all.
//
// Computes nothing, and in this file that rule carries unusual weight. The
// honesty sentence on every card ("Likely available — call to confirm") is a
// CLAIM about someone else's shelf, made from inferred stock. It is composed
// in SQL, tiered by confidence in SQL, and printed here verbatim. Dart never
// sees the confidence number and could not soften or sharpen the wording if it
// wanted to.
import 'package:supabase_flutter/supabase_flutter.dart';

typedef NearRpc =
    Future<Map<String, dynamic>> Function(String fn, Map<String, dynamic> params);

class NearApi {
  NearApi._();

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

  // ── consumer (anon) ──────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> boot() => call('near_boot', const {});

  /// One search. An absent origin is an ABSENT parameter, never a zero — the
  /// backend answers `need_origin` and the page asks for a pincode, which is a
  /// different screen from "nothing found near you".
  static Future<Map<String, dynamic>> search(
    String q, {
    double? lat,
    double? lng,
    String? pincode,
  }) => call('near_search', {
    'p_q': q,
    if (lat != null) 'p_lat': lat,
    if (lng != null) 'p_lng': lng,
    if (pincode != null && pincode.isNotEmpty) 'p_pincode': pincode,
  });

  static Future<Map<String, dynamic>> pharmacy(String token) =>
      call('near_pharmacy', {'p_token': token});

  // ── the pharmacy's own listing ───────────────────────────────────────────

  static Future<Map<String, dynamic>> listingGet() =>
      call('near_listing_get', const {});

  static Future<Map<String, dynamic>> listingSet({
    bool? optIn,
    bool? showPhone,
    String? displayName,
  }) => call('near_listing_set', {
    if (optIn != null) 'p_opt_in': optIn,
    if (showPhone != null) 'p_show_phone': showPhone,
    if (displayName != null) 'p_display_name': displayName,
  });

  static Future<Map<String, dynamic>> markUnavailable(int medicineId,
          {int hours = 24}) =>
      call('near_mark_unavailable',
          {'p_medicine_id': medicineId, 'p_hours': hours});

  static Future<Map<String, dynamic>> markAvailable(int medicineId) =>
      call('near_mark_available', {'p_medicine_id': medicineId});

  static Future<Map<String, dynamic>> posterRequest() =>
      call('near_poster_request', const {});

  /// Kicks the renderer. The screen then polls `near_listing_get` on the
  /// backend's own `poll_ms` — it never invents a timeout of its own.
  static Future<void> posterRender(String token) async {
    await Supabase.instance.client.functions
        .invoke('near-poster', body: {'token': token});
  }

  static Future<String?> posterUrl(String bucket, String path) async {
    try {
      return await Supabase.instance.client.storage
          .from(bucket)
          .createSignedUrl(path, 600);
    } catch (_) {
      return null;
    }
  }
}
