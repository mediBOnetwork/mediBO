// CMD #420 — the pharmacy exchange's one door to the backend.
//
// Two surfaces, one movement layer: DEAD-STOCK EXCHANGE (a shop lists slow or
// near-expiry stock; a nearby shop in the same zone buys it) and EMERGENCY
// BORROW (a shop needs one item now and a neighbour has it). Both end the same
// way — a real invoice between two GSTINs, both shelves updated, a rider booked.
//
// This is pharmacy-to-pharmacy through mediBO logistics. It is NOT the supplier
// marketplace removed in #308, and nothing in this file reaches any of that.
//
// Computes nothing. Every rupee, every "75 days to expiry", every distance and
// promise sentence, and the near-expiry DISCLOSURE itself are finished strings
// from Supabase. The disclosure especially: what the buyer is told is a legal
// artifact, so it is composed in one place and recorded there too.
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef PxRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class PxApi {
  PxApi._();

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

  static Future<Map<String, dynamic>> entry() =>
      call('px_nav_entry', const {});

  static Future<Map<String, dynamic>> home() => call('px_home', const {});

  static Future<Map<String, dynamic>> browse({String? q}) => call('px_browse', {
    if (q != null && q.isNotEmpty) 'p_q': q,
  });

  static Future<Map<String, dynamic>> listStock({
    required String stockId,
    required num qty,
    required num unitPrice,
    String? note,
  }) => call('px_list_stock', {
    'p_stock_id': stockId,
    'p_qty': qty,
    'p_unit_price': unitPrice,
    if (note != null && note.isNotEmpty) 'p_note': note,
  });

  /// Buying IS accepting the disclosure — the batch and expiry were on the row
  /// that was tapped, and the backend freezes them against the deal.
  static Future<Map<String, dynamic>> acceptListing({
    required String listingId,
    required num qty,
    String? clientActionId,
  }) => call('px_accept_listing', {
    'p_listing_id': listingId,
    'p_qty': qty,
    if (clientActionId != null) 'p_client_action_id': clientActionId,
  });

  static Future<Map<String, dynamic>> borrowSearch(String q, {num qty = 1}) =>
      call('px_borrow_search', {'p_q': q, 'p_qty': qty});

  static Future<Map<String, dynamic>> borrowRequest({
    required String stockId,
    required num qty,
    String? clientActionId,
  }) => call('px_borrow_request', {
    'p_stock_id': stockId,
    'p_qty': qty,
    if (clientActionId != null) 'p_client_action_id': clientActionId,
  });

  static Future<Map<String, dynamic>> decide(String dealId, bool accept) =>
      call('px_decide', {'p_deal_id': dealId, 'p_accept': accept});

  static Future<Map<String, dynamic>> deal(String dealId) =>
      call('px_deal_detail', {'p_deal_id': dealId});

  static Future<Map<String, dynamic>> invoice(String dealId) =>
      call('px_invoice_request', {'p_deal_id': dealId});

  static Future<String> signedUrl(
    String bucket,
    String path, {
    int expiresIn = 300,
  }) async {
    if (bucket.isEmpty || path.isEmpty) return '';
    return Supabase.instance.client.storage
        .from(bucket)
        .createSignedUrl(path, expiresIn);
  }
}

/// Whether THIS account gets the exchange, and what its menu entry says.
/// Same shape as PosEntry (#411) and KhataEntry (#415): the shell holds no
/// label, no icon and no role test — `px_nav_entry()` decides all three, and a
/// pharmacy that is not approved, active and zoned gets `show:false`.
class PxEntry {
  PxEntry._();

  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  static bool get show => value.value['show'] == true;

  static Future<void> load({PxRpc? rpc}) async {
    try {
      final res = await (rpc != null
          ? rpc('px_nav_entry', const {})
          : PxApi.entry());
      value.value = res['ok'] == true ? res : const {};
    } catch (_) {
      // An entry that fails to load is simply not drawn. It must never be the
      // reason the counter fails to boot.
      value.value = const {};
    }
  }
}
