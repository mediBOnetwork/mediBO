// CMD #416 — the pharmacy GST pack's one door to the backend.
//
// Forwarding only. The registers, the position, every rupee, every table
// column, every CSV body and the honest "we prepare, you file" sentence are all
// finished strings from `pharmacy_gst_home()`. Nothing in this file adds up a
// column, formats a rupee, or builds a line of CSV — the CSV the user copies is
// the CSV the BACKEND wrote, so what they paste into the portal is exactly what
// the register says.
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature every GST surface accepts, so a test hands it a payload instead of
/// a network.
typedef GstRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class PharmacyGstApi {
  PharmacyGstApi._();

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
      call('pharmacy_gst_entry', const {});

  /// `period` is the backend's own 'YYYY-MM-DD' string from `months[]` — the
  /// screen never builds a date.
  static Future<Map<String, dynamic>> home({String? period}) => call(
    'pharmacy_gst_home',
    period == null || period.isEmpty ? const {} : {'p_period': period},
  );

  static Future<Map<String, dynamic>> saveBill(Map<String, dynamic> body) =>
      call('pharmacy_gst_bill_save', {'p': body});

  static Future<Map<String, dynamic>> logExport(
    String period,
    String key,
    int rows,
  ) => call('pharmacy_gst_export_log', {
    'p_period': period,
    'p_key': key,
    'p_rows': rows,
  });

  static Future<Map<String, dynamic>> packRequest(String period) =>
      call('pharmacy_gst_pack_request', {'p_period': period});

  static Future<Map<String, dynamic>> packStatus(String runId) =>
      call('pharmacy_gst_pack_status', {'p_run_id': runId});

  /// The pack lives in a private bucket, so it is opened through a signed URL
  /// built from the bucket and path the BACKEND named. The screen never
  /// assembles a storage URL of its own.
  static Future<String?> signedPack(String bucket, String path) async {
    try {
      return await Supabase.instance.client.storage
          .from(bucket)
          .createSignedUrl(path, 300);
    } catch (_) {
      return null;
    }
  }
}

/// Does this account have a GST pack, and what does its entry say? Same shape
/// as PosEntry (#411) and StockEntry (#412), for the same reason: the shell
/// must not know what a pharmacy is.
class GstEntry {
  GstEntry._();

  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  static bool get show => value.value['show'] == true;

  static Future<void> load({GstRpc? rpc}) async {
    try {
      final res = await (rpc != null
          ? rpc('pharmacy_gst_entry', const {})
          : PharmacyGstApi.entry());
      value.value = res['ok'] == true ? res : const {};
    } catch (_) {
      // A tile that fails to load is simply not drawn. It must never be the
      // reason the shell fails to boot.
      value.value = const {};
    }
  }
}
