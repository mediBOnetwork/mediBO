// CMD #452 — the customer's own doors onto an order: cancel it (feature_gaps
// #130), send items back (#131), ask for help (#132) and see where it actually
// is (#133).
//
// This file is a transport, nothing more. Every window rule, reason list,
// status label, tone, rupee and timestamp in these payloads is decided in
// Postgres; the sheets print what comes back. Adding a cancellation reason or
// changing the cancel window is an UPDATE against `order_reason_option` /
// `app_settings.customer_cancel_policy`, never a deploy.
import 'package:supabase_flutter/supabase_flutter.dart';

class CustomerCare {
  static SupabaseClient get _db => Supabase.instance.client;

  static Future<Map<String, dynamic>> _rpc(
      String fn, Map<String, dynamic> args) async {
    final res = await _db.rpc(fn, params: args);
    if (res is Map) return Map<String, dynamic>.from(res);
    return <String, dynamic>{};
  }

  // ── #130 cancel ───────────────────────────────────────────────────────────
  /// The sheet payload: whether the window is open, the reasons a BUYER may
  /// pick, and the confirmation copy. Never inferred from `order.status`.
  static Future<Map<String, dynamic>> cancelSheet(String orderId) =>
      _rpc('my_order_cancel_sheet', {'p_order_id': orderId});

  static Future<Map<String, dynamic>> cancel(
          String orderId, String reasonCode, String note) =>
      _rpc('my_order_cancel', {
        'p_order_id': orderId,
        'p_reason_code': reasonCode,
        if (note.trim().isNotEmpty) 'p_note': note.trim(),
      });

  // ── #131 returns ──────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> returnSheet(String orderId) =>
      _rpc('my_order_return_sheet', {'p_order_id': orderId});

  /// [items] carries exactly what the buyer picked:
  /// `{order_item_id, qty, reason_code, condition_code, note}`.
  static Future<Map<String, dynamic>> requestReturn(
          String orderId, List<Map<String, dynamic>> items) =>
      _rpc('my_order_return_request',
          {'p_order_id': orderId, 'p_items': items});

  static Future<Map<String, dynamic>> returns(String orderId) =>
      _rpc('my_order_returns', {'p_order_id': orderId});

  // ── #132 support ──────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> supportTopics(String? orderId) =>
      _rpc('my_support_topics', {'p_order_id': ?orderId});

  static Future<Map<String, dynamic>> openTicket(
          {required String topicCode,
          required String message,
          String? orderId}) =>
      _rpc('support_ticket_open', {
        'p_topic_code': topicCode,
        'p_message': message,
        'p_order_id': ?orderId,
      });

  static Future<Map<String, dynamic>> myTickets() =>
      _rpc('my_support_tickets', const {});

  static Future<Map<String, dynamic>> thread(String ticketId) =>
      _rpc('support_ticket_thread', {'p_ticket_id': ticketId});

  static Future<Map<String, dynamic>> reply(String ticketId, String body) =>
      _rpc('support_ticket_reply', {'p_ticket_id': ticketId, 'p_body': body});

  static Future<Map<String, dynamic>> setStatus(
          String ticketId, String status) =>
      _rpc('support_ticket_set_status',
          {'p_ticket_id': ticketId, 'p_status': status});

  /// The other side of the same thread. Refused server-side for anyone who is
  /// not an admin — this call is not the gate.
  static Future<Map<String, dynamic>> inbox(String status) =>
      _rpc('support_inbox', {if (status.isNotEmpty) 'p_status': status});
}

/// Payload readers. `''` is the explicit absence everywhere in this layer, so a
/// missing label renders nothing rather than a Dart fallback word.
String careStr(Map<String, dynamic>? m, String key) =>
    (m?[key] ?? '').toString();

List<Map<String, dynamic>> careRows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

Map<String, dynamic> careMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
