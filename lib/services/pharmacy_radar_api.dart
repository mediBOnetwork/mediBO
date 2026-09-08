// CMD #425 — the one door to the expiry radar.
//
// The radar ranks by EXPECTED LOSS, and every rupee of that number is computed
// in Supabase: this file forwards a call and hands back a map. It formats
// nothing, ranks nothing and decides nothing — including which quick-reply
// numbers a correction offers, which arrive as `options` on the ask itself so
// the WhatsApp buttons and the in-app chips are literally the same list.
import 'package:supabase_flutter/supabase_flutter.dart';

import 'pharmacy_shield_api.dart' show ShieldRpc;

class PharmacyRadarApi {
  PharmacyRadarApi._();

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

  /// The whole screen in one payload: headline, ranked items, open asks, the
  /// month card, the WhatsApp opt-in and the bill-intake card.
  static Future<Map<String, dynamic>> home() =>
      call('pharmacy_radar_home', const {});

  /// An absent bucket is an ABSENT parameter, never an empty string — the
  /// backend reads null as "every bucket".
  static Future<Map<String, dynamic>> items(
    String? bucketKey, {
    int limit = 50,
    int offset = 0,
  }) => call('pharmacy_radar_items', {
    if (bucketKey != null && bucketKey.isNotEmpty) 'p_bucket': bucketKey,
    'p_limit': limit,
    'p_offset': offset,
  });

  /// Raise the same question the WhatsApp alert asks, for a lot the owner
  /// tapped in the app. The question text and the option list come back from
  /// the backend — this call sends only the lot.
  static Future<Map<String, dynamic>> askOpen(String stockId) =>
      call('pharmacy_radar_ask_open', {'p_stock_id': stockId});

  /// The truth loop: an answer corrects the lot and recalibrates velocity.
  static Future<Map<String, dynamic>> answer(String askId, num qty) =>
      call('pharmacy_radar_answer', {'p_ask_id': askId, 'p_qty': qty});

  static Future<Map<String, dynamic>> configSet(Map<String, dynamic> patch) =>
      call('pharmacy_radar_config_set', {'p_patch': patch});

  /// The way in, drawn from the backend: label, sub-label and the rupee badge.
  static Future<Map<String, dynamic>> entry() =>
      call('pharmacy_radar_entry', const {});
}

/// Re-exported so a radar surface takes the same test seam as every other
/// pharmacy screen.
typedef RadarRpc = ShieldRpc;
