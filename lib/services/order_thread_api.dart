// lib/services/order_thread_api.dart — CHANGE #713
//
// The seam every conversation surface calls through. Five RPCs, no decisions:
// each method hands back the backend's map as it arrived, so a screen can only
// render it. The `*Fn` hooks let the protected test drive both the customer and
// the partner sides with no network.
//
// There is deliberately no model class here. A typed model is where display
// strings start being recomputed in Dart ("if status == closed then 'Closed'"),
// and every one of those words already arrives finished in the payload.
import 'package:supabase_flutter/supabase_flutter.dart';

typedef ThreadRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

class OrderThreadApi {
  OrderThreadApi._();

  /// Test seam. Null in production -> the real RPCs.
  static ThreadRpc? rpcFn;

  static Future<Map<String, dynamic>> _call(
      String fn, Map<String, dynamic> params) async {
    if (rpcFn != null) return rpcFn!(fn, params);
    final res = await Supabase.instance.client.rpc(fn, params: params);
    return res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
  }

  /// The conversation. Either handle works: an order id (the customer's door)
  /// or a thread id (the inbox's).
  static Future<Map<String, dynamic>> get({String? orderId, String? threadId}) =>
      _call('order_thread_get', {
        'p_order_id': orderId,
        'p_thread_id': threadId,
      });

  static Future<Map<String, dynamic>> post({
    String? threadId,
    String? orderId,
    required String body,
    List<Map<String, dynamic>> attachments = const [],
  }) =>
      _call('order_thread_post', {
        'p_thread_id': threadId,
        'p_order_id': orderId,
        'p_body': body,
        'p_attachments': attachments,
      });

  /// The inbox — zone-scoped for a partner, every zone for the office. Which
  /// of the two the caller gets is the BACKEND's answer, in `view`.
  static Future<Map<String, dynamic>> inbox(
          {String filter = '', String tag = ''}) =>
      _call('thread_inbox', {'p_filter': filter, 'p_tag': tag});

  static Future<Map<String, dynamic>> setStatus(String threadId, String status) =>
      _call('thread_set_status', {
        'p_thread_id': threadId,
        'p_status': status,
      });

  static Future<Map<String, dynamic>> callTasks() =>
      _call('thread_call_tasks', const {});

  static Future<Map<String, dynamic>> logCallOutcome(
          String taskId, String outcome, String note) =>
      _call('thread_call_task_log', {
        'p_task_id': int.tryParse(taskId) ?? 0,
        'p_outcome_code': outcome,
        'p_note': note,
      });
}

/// `rows`/`messages`/`filters` arrive as a JSON list of maps. One helper, so
/// six widgets do not each write the same cast.
List<Map<String, dynamic>> threadRows(Object? raw) => (raw is List)
    ? raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false)
    : const <Map<String, dynamic>>[];

String threadStr(Map<String, dynamic> m, String key) =>
    (m[key] ?? '').toString();

int threadInt(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse((v ?? '').toString()) ?? 0;
}
