// CMD #412 — the shelf-stock screen's one door to the backend.
//
// Forwarding only. Every rupee, badge, plural, tone, empty state and toast on
// the stock screen is a finished string from `pharmacy_stock_home()` and its
// siblings; nothing in this file totals, formats, sorts or decides anything.
//
// The photo import is the only two-step call in here, and even that is a
// forward: the backend picks the bucket and the path (so a pharmacy can only
// write into its own folder), Dart uploads the bytes it was told to, and the
// `stock-ocr` edge function reads the page and fills the DRAFT rows a human
// then confirms.

import 'package:flutter/foundation.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature every shelf-stock surface accepts, so a test hands it a payload
/// instead of a network.
typedef StockRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class PharmacyStockApi {
  PharmacyStockApi._();

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

  /// Is this account a pharmacy, and what does its menu entry say? The shell
  /// holds no label and makes no role test — this answers both.
  static Future<Map<String, dynamic>> entry() =>
      call('pharmacy_stock_entry', const {});

  static Future<Map<String, dynamic>> home({
    String? q,
    String filter = 'all',
    int limit = 40,
    int offset = 0,
  }) => call('pharmacy_stock_home', {
    // An untouched search box is an ABSENT parameter, never an empty string.
    if (q != null && q.trim().isNotEmpty) 'p_q': q.trim(),
    'p_filter': filter,
    'p_limit': limit,
    'p_offset': offset,
  });

  static Future<Map<String, dynamic>> moves(String stockId, {int limit = 40}) =>
      call('pharmacy_stock_moves', {'p_stock_id': stockId, 'p_limit': limit});

  static Future<Map<String, dynamic>> productSearch(String q, {int limit = 20}) =>
      call('pharmacy_stock_product_search', {'p_q': q, 'p_limit': limit});

  static Future<Map<String, dynamic>> addPurchase(Map<String, dynamic> body) =>
      call('pharmacy_stock_add_purchase', {'p': body});

  static Future<Map<String, dynamic>> adjust({
    required String stockId,
    required num newQty,
    required String reason,
    String? note,
  }) => call('pharmacy_stock_adjust', {
    'p_stock_id': stockId,
    'p_new_qty': newQty,
    'p_reason': reason,
    if (note != null && note.trim().isNotEmpty) 'p_note': note.trim(),
  });

  static Future<Map<String, dynamic>> importStart(String kind) =>
      call('pharmacy_stock_import_start', {'p_kind': kind});

  /// The whole CSV goes to the backend as TEXT. Dart does not split a line,
  /// map a header or read a number out of it — that parse lives in SQL, where
  /// it can be changed without a deploy.
  static Future<Map<String, dynamic>> importCsv(String importId, String text) =>
      call('pharmacy_stock_import_csv', {
        'p_import_id': importId,
        'p_text': text,
      });

  static Future<Map<String, dynamic>> importPreview(String importId) =>
      call('pharmacy_stock_import_preview', {'p_import_id': importId});

  static Future<Map<String, dynamic>> importRowSet(
    String rowId,
    Map<String, dynamic> patch,
  ) => call('pharmacy_stock_import_row_set', {
    'p_row_id': rowId,
    'p_patch': patch,
  });

  static Future<Map<String, dynamic>> importApply(String importId) =>
      call('pharmacy_stock_import_apply', {'p_import_id': importId});

  /// Upload the register photo where the backend said to, then ask `stock-ocr`
  /// to read it. Returns the refreshed preview so the caller renders the
  /// backend's own status line — including its failure copy.
  static Future<Map<String, dynamic>> scanPhoto({
    required String importId,
    required String bucket,
    required String path,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
  }) async {
    final client = Supabase.instance.client;
    await client.storage
        .from(bucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: true),
        );
    await client.functions.invoke('stock-ocr', body: {'import_id': importId});
    return importPreview(importId);
  }
}

/// CMD #412 — "does this account have a shelf, and what does its entry say?"
///
/// Same shape as PosEntry (#411) and for the same reason: the SHELL must not
/// know what a pharmacy is. It asks once at boot, parks the backend's answer
/// here, and the tile draws itself only if the backend said `show`. A failure
/// to load is simply a tile that is not drawn — never a reason the shell fails
/// to boot.
class StockEntry {
  StockEntry._();

  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  static bool get show => value.value['show'] == true;

  static Future<void> load({StockRpc? rpc}) async {
    try {
      final res = await (rpc != null
          ? rpc('pharmacy_stock_entry', const {})
          : PharmacyStockApi.entry());
      value.value = res['ok'] == true ? res : const {};
    } catch (_) {
      value.value = const {};
    }
  }
}
