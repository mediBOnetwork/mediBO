// CMD #418 — the prescription scanner's one door to the backend.
//
// It forwards calls and hands back payloads. It decides nothing: not what a
// line matched, not which batch to use, not whether a line belongs on the bill,
// not what any of it costs. The photo goes to the bucket and the path the
// BACKEND minted (`rx_scan_new`), so a client cannot write into another shop's
// folder even if it tried.
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Test seam. Null in production → the real RPCs.
typedef RxRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class RxScanApi {
  RxScanApi._();

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
      call('rx_scan_entry', const {});

  static Future<Map<String, dynamic>> recent({int limit = 20}) =>
      call('rx_scan_recent', {'p_limit': limit});

  /// Step 1 — the backend mints the scan and the storage path.
  static Future<Map<String, dynamic>> start() => call('rx_scan_new', const {});

  /// Step 2 — the photo itself, to the bucket and path we were handed.
  static Future<void> upload(
    String bucket,
    String path,
    Uint8List bytes,
    String mime,
  ) => Supabase.instance.client.storage
      .from(bucket)
      .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mime));

  static Future<Map<String, dynamic>> uploaded(
    String scanId,
    String path,
    String mime,
    int bytes,
  ) => call('rx_scan_uploaded', {
    'p_scan_id': scanId,
    'p_path': path,
    'p_mime': mime,
    'p_bytes': bytes,
  });

  /// Step 3 — ask the reader to read it. The edge function reports back to the
  /// backend on its own; this call is fire-and-poll, so a slow model never
  /// blocks the counter.
  static Future<void> read(String scanId) async {
    await Supabase.instance.client.functions.invoke(
      'rx-ocr',
      body: {'scan_id': scanId},
    );
  }

  static Future<Map<String, dynamic>> detail(String scanId) =>
      call('rx_scan_detail', {'p_scan_id': scanId});

  /// The human's confirmation, carrying the lines as they were LEFT on screen.
  /// pos_commit_sale prices them — nothing here adds up.
  static Future<Map<String, dynamic>> confirm(
    String scanId,
    String clientActionId,
    List<Map<String, dynamic>> lines, {
    String paymentMode = 'cash',
    Map<String, dynamic> patient = const {},
  }) => call('rx_scan_confirm', {
    'p_scan_id': scanId,
    'p_client_action_id': clientActionId,
    'p_lines': lines,
    'p_payment_mode': paymentMode,
    'p_patient': patient,
  });

  static Future<Map<String, dynamic>> discard(String scanId) =>
      call('rx_scan_discard', {'p_scan_id': scanId});

  /// A short-lived link to the private Rx image. The screen never builds a URL
  /// — it is given the bucket and path and asks storage for the link.
  static Future<String?> imageUrl(String bucket, String path) async {
    try {
      return await Supabase.instance.client.storage
          .from(bucket)
          .createSignedUrl(path, 600);
    } catch (_) {
      return null;
    }
  }
}
