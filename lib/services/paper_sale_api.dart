// CMD #429 — the paper sale pad's one door to the backend.
//
// Forwarding only. Every label, chip, plural, tone, quantity note, review
// reason, "already counted from an earlier photo" and the standing sentence
// that a paper sale is NOT a bill all arrive finished from `paper_sale_home()`
// and its siblings. Nothing here totals, formats, matches or decides.
//
// IN-APP UPLOAD ONLY. There is no share-sheet target, no WhatsApp intent and no
// forwarding path in this file — Om was explicit that the only door is the app.
//
// The page hash is computed here and sent up, which is what lets the BACKEND
// refuse a page it already holds (same-page dedupe). Dart does not decide that
// two photos are the same page; it only reports what it uploaded.

import 'package:flutter/foundation.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

typedef PaperRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class PaperSaleApi {
  PaperSaleApi._();

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
      call('paper_sale_entry', const {});

  static Future<Map<String, dynamic>> home({int limit = 20}) =>
      call('paper_sale_home', {'p_limit': limit});

  static Future<Map<String, dynamic>> start({
    String mode = 'page',
    String? soldOn,
  }) => call('paper_sale_start', {
    'p_mode': mode,
    if (soldOn != null && soldOn.isNotEmpty) 'p_sold_on': soldOn,
  });

  static Future<Map<String, dynamic>> sheetGet(String sheetId) =>
      call('paper_sale_sheet_get', {'p_sheet_id': sheetId});

  static Future<Map<String, dynamic>> lineSet(
    String lineId,
    Map<String, dynamic> patch,
  ) => call('paper_sale_line_set', {'p_line_id': lineId, 'p_patch': patch});

  static Future<Map<String, dynamic>> seedOpening(String lineId, {num? qty}) =>
      call('paper_sale_seed_opening', {
        'p_line_id': lineId,
        if (qty != null) 'p_qty': qty,
      });

  static Future<Map<String, dynamic>> confirm(String sheetId) =>
      call('paper_sale_confirm', {'p_sheet_id': sheetId});

  static Future<Map<String, dynamic>> closeDay(String sheetId) =>
      call('paper_sale_close_day', {'p_sheet_id': sheetId});

  static Future<Map<String, dynamic>> settingsSet(Map<String, dynamic> patch) =>
      call('paper_sale_settings_set', {'p_patch': patch});

  static Future<Map<String, dynamic>> shotAdd({
    required String sheetId,
    required String bucket,
    required String path,
    String? hash,
  }) => call('paper_sale_shot_add', {
    'p_sheet_id': sheetId,
    'p_bucket': bucket,
    'p_path': path,
    if (hash != null) 'p_hash': hash,
  });

  static Future<Map<String, dynamic>> queue(String sheetId) =>
      call('paper_sale_queue', {'p_sheet_id': sheetId});

  /// A content fingerprint for same-page dedupe. FNV-1a over the bytes, with
  /// the length mixed in — deliberately NOT a crypto hash, because the question
  /// is only "are these the identical bytes I already sent?", and pulling
  /// `crypto` in as a direct dependency for that would be a heavier change to
  /// the whole app than this feature earns. The BACKEND still owns the
  /// decision; this only reports what was uploaded.
  static String pageHash(Uint8List bytes) {
    var h = BigInt.parse('14695981039346656037');
    final prime = BigInt.parse('1099511628211');
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final b in bytes) {
      h = (h ^ BigInt.from(b)) * prime & mask;
    }
    return '${bytes.length}-${h.toRadixString(16)}';
  }

  /// Upload each page to the path the backend derived, hashing first so a
  /// re-shoot of a page already held is refused by the BACKEND. The refusal is
  /// returned as-is, message and all, so the counter reads its own words.
  static Future<Map<String, dynamic>> uploadPages({
    required String sheetId,
    required String bucket,
    required String pathPrefix,
    required String pathSuffix,
    required List<Uint8List> pages,
    String contentType = 'image/jpeg',
  }) async {
    final client = Supabase.instance.client;
    final refusals = <Map<String, dynamic>>[];
    var n = 0;
    for (final bytes in pages) {
      n++;
      final hash = pageHash(bytes);
      final path = '$pathPrefix$n$pathSuffix';
      await client.storage
          .from(bucket)
          .uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: contentType, upsert: true),
          );
      final res = await shotAdd(
        sheetId: sheetId,
        bucket: bucket,
        path: path,
        hash: hash,
      );
      if (res['ok'] != true) refusals.add(res);
    }
    final queued = await queue(sheetId);
    return {...queued, if (refusals.isNotEmpty) 'refused': refusals};
  }
}

/// "Does this account keep a counter, and is a page waiting to be checked?"
/// Same shape as StockEntry (#412) and VaultEntry (#423): the shell holds no
/// role test and no label, and a failure to load is a button that is not drawn.
class PaperSaleEntry {
  PaperSaleEntry._();

  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  static bool get show => value.value['show'] == true;

  static Future<void> load({PaperRpc? rpc}) async {
    try {
      final res = await (rpc != null
          ? rpc('paper_sale_entry', const {})
          : PaperSaleApi.entry());
      value.value = res['ok'] == true ? res : const {};
    } catch (_) {
      value.value = const {};
    }
  }
}
