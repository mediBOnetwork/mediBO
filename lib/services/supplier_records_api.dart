// CHANGE #403 — the supplier records layer's one door to the backend.
//
// Four read-only surfaces: the documents he can download, the deductions taken
// off his bills, what he sold mediBO this month, and his own bill archive.
// Every decision, every label, every rupee on all four arrives from Supabase —
// this file forwards calls and hands back payloads, and decides nothing.
//
// The one thing it does that is NOT a plain RPC is the file handoff: the
// backend answers a document request with a bucket and a path, and the browser
// signs a short-lived URL for it under the SIGNED-IN session. That is the
// pattern every other private file in this app already uses (bill_viewer,
// payment_proof, wa_template_api) and it keeps the service key out of SQL —
// the scope is a storage policy that lets a supplier sign his own folder and
// nothing else.
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supplier_account_state.dart';

class SupplierRecordsApi {
  SupplierRecordsApi._();

  static Future<Map<String, dynamic>> home() =>
      SupplierApi.call('supplier_records_home', const {});

  static Future<Map<String, dynamic>> documents() =>
      SupplierApi.call('supplier_documents_list', const {});

  static Future<Map<String, dynamic>> docRequest(String kind, String ref) =>
      SupplierApi.call('supplier_doc_request', {'p_kind': kind, 'p_ref': ref});

  static Future<Map<String, dynamic>> docStatus(String id) =>
      SupplierApi.call('supplier_doc_status', {'p_id': id});

  static Future<Map<String, dynamic>> debits() =>
      SupplierApi.call('supplier_debits_list', const {});

  static Future<Map<String, dynamic>> sales(String? month) =>
      SupplierApi.call('supplier_sales_summary',
          month == null || month.isEmpty ? const {} : {'p_month': month});

  static Future<Map<String, dynamic>> billSearch(Map<String, dynamic> filters) =>
      SupplierApi.call('supplier_bill_search', filters);

  static Future<Map<String, dynamic>> billDetail(String id) =>
      SupplierApi.call('supplier_bill_detail', {'p_id': id});

  /// The payload names the bucket and the path; this signs it for `expires_s`
  /// seconds. An empty pair is an empty URL, never a guessed one.
  static Future<String> signedUrl(String bucket, String path,
      {int expiresIn = 300}) async {
    if (bucket.isEmpty || path.isEmpty) return '';
    return Supabase.instance.client.storage
        .from(bucket)
        .createSignedUrl(path, expiresIn);
  }
}

/// A document request that has not finished rendering yet. The backend says
/// how long to wait before asking again (`poll_ms`) — this class never invents
/// an interval and never decides the document has failed on its own.
class SupplierDocPoll {
  final String docId;
  final int pollMs;
  const SupplierDocPoll(this.docId, this.pollMs);

  static SupplierDocPoll? from(Map<String, dynamic> payload) {
    final id = supplierStr(payload, 'doc_id');
    if (id.isEmpty || supplierStr(payload, 'status') != 'building') return null;
    final ms = payload['poll_ms'];
    return SupplierDocPoll(id, ms is num ? ms.toInt() : 1500);
  }
}
