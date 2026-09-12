// CMD #423 — the bill vault's one door to the backend.
//
// Forwarding only. Every rupee, month name, chip label, plural, tone, progress
// line, capture instruction and error sentence on the vault screen is a
// finished string from `pharmacy_vault_home()` and its siblings. Nothing in
// this file totals, formats, sorts, matches or decides anything — the vault's
// whole point is that the pharmacy's data is read and judged in one place, and
// this is not that place.
//
// The three intake doors are all the same two-step forward: the BACKEND names
// the bucket and the path (so a pharmacy can only ever write into its own
// folder), Dart uploads the bytes it was told to, and `bill-vault-ocr` reads
// them. Dart never picks a filename, never crops, and never decides that a
// photo is good enough.

import 'package:flutter/foundation.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature every vault surface accepts, so a test hands it a payload instead
/// of a network.
typedef VaultRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class PharmacyVaultApi {
  PharmacyVaultApi._();

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
      call('pharmacy_vault_entry', const {});

  /// The whole screen. `month` absent means every month — an untouched filter
  /// is an ABSENT parameter, never an empty string.
  static Future<Map<String, dynamic>> home({String? month}) =>
      call('pharmacy_vault_home', {
        if (month != null && month.isNotEmpty) 'p_month': month,
      });

  static Future<Map<String, dynamic>> review() =>
      call('pharmacy_vault_review', const {});

  static Future<Map<String, dynamic>> billGet(String billId) =>
      call('pharmacy_vault_bill_get', {'p_bill_id': billId});

  static Future<Map<String, dynamic>> billStart({
    String source = 'photo',
    String? batchId,
  }) => call('pharmacy_vault_bill_start', {
    'p_source': source,
    if (batchId != null) 'p_batch_id': batchId,
  });

  static Future<Map<String, dynamic>> batchStart({String? label}) =>
      call('pharmacy_vault_batch_start', {
        if (label != null && label.trim().isNotEmpty) 'p_label': label.trim(),
      });

  static Future<Map<String, dynamic>> batchStatus(String batchId) =>
      call('pharmacy_vault_batch_status', {'p_batch_id': batchId});

  static Future<Map<String, dynamic>> lineSet(
    String lineId,
    Map<String, dynamic> patch,
  ) => call('pharmacy_vault_line_set', {'p_line_id': lineId, 'p_patch': patch});

  static Future<Map<String, dynamic>> confirm(String billId) =>
      call('pharmacy_vault_bill_confirm', {'p_bill_id': billId});

  static Future<Map<String, dynamic>> shelfApply(String billId) =>
      call('pharmacy_vault_shelf_apply', {'p_bill_id': billId});

  static Future<Map<String, dynamic>> shotAdd({
    required String billId,
    required String bucket,
    required String path,
  }) => call('pharmacy_vault_shot_add', {
    'p_bill_id': billId,
    'p_bucket': bucket,
    'p_path': path,
  });

  static Future<Map<String, dynamic>> queue(String billId) =>
      call('pharmacy_vault_bill_queue', {'p_bill_id': billId});

  /// MULTI-SHOT UPLOAD. Each frame goes to the path the backend derived from
  /// its own prefix — `<prefix><n><suffix>` — so the shot number, the folder
  /// and the extension are all the backend's, not Dart's. The frames are
  /// registered in the order they were taken, which is the order the reader
  /// stitches them in.
  static Future<Map<String, dynamic>> uploadShots({
    required String billId,
    required String bucket,
    required String pathPrefix,
    required String pathSuffix,
    required List<Uint8List> shots,
    String contentType = 'image/jpeg',
  }) async {
    final client = Supabase.instance.client;
    for (var i = 0; i < shots.length; i++) {
      final path = '$pathPrefix${i + 1}$pathSuffix';
      await client.storage
          .from(bucket)
          .uploadBinary(
            path,
            shots[i],
            fileOptions: FileOptions(contentType: contentType, upsert: true),
          );
      await shotAdd(billId: billId, bucket: bucket, path: path);
    }
    return queue(billId);
  }
}

/// CMD #423 — "does this account have a vault, and is anything waiting in it?"
///
/// Same shape as StockEntry (#412) and PosEntry (#411), for the same reason:
/// the SHELL must not know what a pharmacy is. It asks once, parks the
/// backend's answer here, and a button draws itself only if the backend said
/// `show`. The review badge is the backend's count, printed verbatim — Dart
/// never counts anything. A failure to load is a button that is not drawn,
/// never a reason the shell fails to boot.
class VaultEntry {
  VaultEntry._();

  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  static bool get show => value.value['show'] == true;

  static Future<void> load({VaultRpc? rpc}) async {
    try {
      final res = await (rpc != null
          ? rpc('pharmacy_vault_entry', const {})
          : PharmacyVaultApi.entry());
      value.value = res['ok'] == true ? res : const {};
    } catch (_) {
      value.value = const {};
    }
  }
}
