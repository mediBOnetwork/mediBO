// CMD #430 — the one door to the stock audit.
//
// The interesting thing about this file is what is NOT in it. There is no
// "expected quantity" anywhere, because while a count is open the backend does
// not send one: blindness is a property of the payload, not a widget that hides
// a field it was given. There is also no variance arithmetic, no tolerance
// rule, and no decision about who may confirm a count — the second-counter rule
// is enforced in SQL, and this layer only carries the refusal back.
import 'package:supabase_flutter/supabase_flutter.dart';

import 'pharmacy_shield_api.dart' show ShieldRpc;

class PharmacyAuditApi {
  PharmacyAuditApi._();

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

  static Future<Map<String, dynamic>> home() =>
      call('pharmacy_audit_home', const {});

  static Future<Map<String, dynamic>> entry() =>
      call('pharmacy_audit_entry', const {});

  /// Starting an audit is what freezes the checklist, so the kind and the scope
  /// are the backend's own keys from `home().kinds` — never strings typed here.
  static Future<Map<String, dynamic>> start(
    String kind,
    String scopeKind, {
    String? scopeValue,
  }) => call('pharmacy_audit_start', {
    'p_kind': kind,
    'p_scope_kind': scopeKind,
    if (scopeValue != null && scopeValue.isNotEmpty) 'p_scope_value': scopeValue,
  });

  static Future<Map<String, dynamic>> sheet(
    String sessionId, {
    String? q,
    int limit = 100,
    int offset = 0,
  }) => call('pharmacy_audit_sheet', {
    'p_session_id': sessionId,
    if (q != null && q.isNotEmpty) 'p_q': q,
    'p_limit': limit,
    'p_offset': offset,
  });

  /// One door for all four inputs — voice, scan, shelf photo and typing differ
  /// only in the `method` recorded against the number.
  static Future<Map<String, dynamic>> count(
    String sessionId,
    List<Map<String, dynamic>> lines,
  ) => call('pharmacy_audit_count', {
    'p_session_id': sessionId,
    'p_lines': lines,
  });

  static Future<Map<String, dynamic>> close(String sessionId) =>
      call('pharmacy_audit_close', {'p_session_id': sessionId});

  static Future<Map<String, dynamic>> variance(String sessionId) =>
      call('pharmacy_audit_variance', {'p_session_id': sessionId});

  static Future<Map<String, dynamic>> recountSheet(String sessionId) =>
      call('pharmacy_audit_recount_sheet', {'p_session_id': sessionId});

  static Future<Map<String, dynamic>> recount(
    String roundId,
    num qty, {
    String method = 'type',
  }) => call('pharmacy_audit_recount', {
    'p_round_id': roundId,
    'p_qty': qty,
    'p_method': method,
  });

  static Future<Map<String, dynamic>> resolve(String lineId, num qty) =>
      call('pharmacy_audit_resolve', {'p_line_id': lineId, 'p_qty': qty});

  static Future<Map<String, dynamic>> accept(String sessionId) =>
      call('pharmacy_audit_accept', {'p_session_id': sessionId});

  static Future<Map<String, dynamic>> actions(String sessionId) =>
      call('pharmacy_audit_actions', {'p_session_id': sessionId});

  static Future<Map<String, dynamic>> certificate(String sessionId) =>
      call('pharmacy_audit_certificate', {'p_session_id': sessionId});

  static Future<Map<String, dynamic>> verify() =>
      call('pharmacy_audit_verify', const {});
}

typedef AuditRpc = ShieldRpc;
