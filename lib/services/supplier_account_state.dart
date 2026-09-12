// CHANGE #402 — the supplier account surface's one door to the backend.
//
// Three things a supplier could not do before this change: hand a login to
// their own staff, tell mediBO where to pay them, and read any of it in Hindi.
// All three are decided in Supabase — the access algebra, the approval state
// machine and the language resolution — and every one of them arrives here as
// a payload this file forwards untouched.
//
// Nothing on this class decides anything. It is the seam the screens accept so
// a test can hand them a payload instead of a network.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';

/// Signature every supplier-account screen accepts.
typedef SupplierRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

class SupplierApi {
  SupplierApi._();

  static Future<Map<String, dynamic>> call(
      String fn, Map<String, dynamic> params) async {
    final raw = await Supabase.instance.client
        .rpc(fn, params: params.isEmpty ? null : params);
    final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
    return map is Map ? Map<String, dynamic>.from(map) : <String, dynamic>{};
  }

  /// Who am I, what may I open, which language am I reading — one call, and
  /// the shell renders it.
  static Future<Map<String, dynamic>> session() =>
      call('supplier_session', const {});

  static Future<Map<String, dynamic>> staffList() =>
      call('supplier_staff_list', const {});

  static Future<Map<String, dynamic>> staffAdd(
          String identity, String name, String roleKey) =>
      call('supplier_staff_add', {
        'p_identity': identity,
        'p_name': name,
        'p_role_key': roleKey,
      });

  static Future<Map<String, dynamic>> staffSetRole(int id, String roleKey) =>
      call('supplier_staff_set_role', {'p_id': id, 'p_role_key': roleKey});

  static Future<Map<String, dynamic>> staffRemove(int id) =>
      call('supplier_staff_remove', {'p_id': id});

  static Future<Map<String, dynamic>> payoutGet() =>
      call('supplier_payout_get', const {});

  static Future<Map<String, dynamic>> payoutSubmit(Map<String, String> values) =>
      call('supplier_payout_submit', {
        'p_account_name': values['account_name'] ?? '',
        'p_account_number': values['account_number'] ?? '',
        'p_ifsc': values['ifsc'] ?? '',
        'p_bank_name': values['bank_name'] ?? '',
        'p_upi_vpa': values['upi_vpa'] ?? '',
      });

  static Future<Map<String, dynamic>> languageGet() =>
      call('ui_language_get', const {});

  static Future<Map<String, dynamic>> languageSet(String code) =>
      call('ui_language_set', {'p_lang': code});

  // ── admin side ──────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> payoutQueue() =>
      call('admin_supplier_payout_queue', const {});

  static Future<Map<String, dynamic>> payoutReview(
          int id, String decision, String note) =>
      call('admin_supplier_payout_review', {
        'p_id': id,
        'p_decision': decision,
        'p_note': note,
      });

  static Future<Map<String, dynamic>> languageReport(String lang) =>
      call('ui_language_report', {'p_lang': lang, 'p_limit': 300});

  static Future<Map<String, dynamic>> i18nSet(
          String key, String lang, String value) =>
      call('ui_i18n_set', {'p_key': key, 'p_lang': lang, 'p_value': value});
}

/// The payload names a tone; only the colour is local. An unknown tone is
/// neutral rather than a guess — the backend owns the meaning, not this file.
Color supplierTone(Object? tone) => switch ((tone ?? '').toString()) {
      'success' => Ds.c.success,
      'warning' => Ds.c.warning,
      'danger' => Ds.c.danger,
      'info' => Ds.c.info,
      _ => Ds.c.textSecondary,
    };

Color supplierToneSoft(Object? tone) => switch ((tone ?? '').toString()) {
      'success' => Ds.c.successSoft,
      'warning' => Ds.c.warningSoft,
      'danger' => Ds.c.dangerSoft,
      'info' => Ds.c.infoSoft,
      _ => Ds.c.bg,
    };

/// A read of a payload map that never throws on a shape it has not seen.
Map<String, dynamic> supplierMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

List<Map<String, dynamic>> supplierRows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

String supplierStr(Map<String, dynamic> m, String key) =>
    (m[key] ?? '').toString();
