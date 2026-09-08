// lib/services/partner_ticket_api.dart — CHANGE #696
//
// The seam every escalation surface calls through: six RPCs, no decisions.
// Each method hands back the backend's map exactly as it arrived, so a screen
// can only render it — the category names, the SLA sentence, the status word,
// the outcome list and every refusal are already finished text in the payload.
//
// No model class on purpose. A typed model is where display strings start
// being recomputed in Dart ("if status == closed then 'Closed'"), and this
// feature has four statuses whose WORDING differs by who is reading them.
import 'package:supabase_flutter/supabase_flutter.dart';

typedef TicketRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

class PartnerTicketApi {
  PartnerTicketApi._();

  /// Test seam. Null in production -> the real RPCs.
  static TicketRpc? rpcFn;

  static Future<Map<String, dynamic>> _call(
      String fn, Map<String, dynamic> params) async {
    if (rpcFn != null) return rpcFn!(fn, params);
    final res = await Supabase.instance.client.rpc(fn, params: params);
    return res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
  }

  /// The queue. Zone scope is the BACKEND's: a partner is only ever handed
  /// their own tickets, so [partnerId] is meaningless for them and is simply
  /// ignored on that side.
  static Future<Map<String, dynamic>> list(
          {String filter = 'open', String? partnerId}) =>
      _call('partner_ticket_list', {
        'p_filter': filter,
        'p_partner_id': partnerId == null ? null : int.tryParse(partnerId),
      });

  /// The raise sheet: which categories this side may raise, the priorities,
  /// and (for the office) which partner the issue is about.
  static Future<Map<String, dynamic>> newTicket() =>
      _call('partner_ticket_new', const {});

  static Future<Map<String, dynamic>> raise({
    required String category,
    required String subject,
    required String body,
    String priority = '',
    String? partnerId,
    String linkKind = '',
    String linkRef = '',
    List<Map<String, dynamic>> attachments = const [],
  }) =>
      _call('partner_ticket_raise', {
        'p_category': category,
        'p_subject': subject,
        'p_body': body,
        'p_priority': priority,
        'p_partner_id': partnerId == null ? null : int.tryParse(partnerId),
        'p_link_kind': linkKind,
        'p_link_ref': linkRef,
        'p_attachments': attachments,
      });

  static Future<Map<String, dynamic>> get(String id) =>
      _call('partner_ticket_get', {'p_id': id});

  static Future<Map<String, dynamic>> reply(String id, String body,
          {List<Map<String, dynamic>> attachments = const []}) =>
      _call('partner_ticket_reply', {
        'p_id': id,
        'p_body': body,
        'p_attachments': attachments,
      });

  static Future<Map<String, dynamic>> close(
          String id, String outcomeCode, String note) =>
      _call('partner_ticket_close', {
        'p_id': id,
        'p_outcome_code': outcomeCode,
        'p_note': note,
      });
}

/// `rows` / `messages` / `filters` / `categories` all arrive as a JSON list of
/// maps. One helper, so eight widgets do not each write the same cast.
List<Map<String, dynamic>> ticketRows(Object? raw) => (raw is List)
    ? raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false)
    : const <Map<String, dynamic>>[];

String ticketStr(Map<String, dynamic> m, String key) => (m[key] ?? '').toString();

bool ticketBool(Map<String, dynamic> m, String key) => m[key] == true;

Map<String, dynamic> ticketMap(Map<String, dynamic> m, String key) {
  final v = m[key];
  return v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
}
