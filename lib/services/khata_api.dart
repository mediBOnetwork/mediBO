// CMD #415 — the khata book's one door to the backend.
//
// The pharmacy's patient/doctor credit ledger: the paper diary by the till,
// with the two things paper cannot do — it knows how old every balance is, and
// it can ask for the money by itself.
//
// Same contract as PosApi (#411), for the same reason: this file forwards calls
// and hands back payloads. Every rupee, every age sentence ("20 days old"),
// every reminder word and every tone arrives finished from Supabase. There is
// no arithmetic in this file and there is none in the screen that reads it — a
// balance is `balance_display`, never a number Dart formatted.
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature every khata surface accepts, so a test hands it a payload instead
/// of a network.
typedef KhataRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class KhataApi {
  KhataApi._();

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
      call('khata_nav_entry', const {});

  static Future<Map<String, dynamic>> home({String? q, String? filter}) => call('khata_home', {
    if (q != null && q.isNotEmpty) 'p_q': q,
    if (filter != null && filter.isNotEmpty) 'p_filter': filter,
  });

  static Future<Map<String, dynamic>> account(
    String accountId, {
    int limit = 100,
    int offset = 0,
  }) => call('khata_account_detail', {
    'p_account_id': accountId,
    'p_limit': limit,
    'p_offset': offset,
  });

  static Future<Map<String, dynamic>> saveAccount({
    String? id,
    String? name,
    String? phone,
    String kind = 'patient',
    num? limitAmount,
    String? note,
    bool? isActive,
  }) => call('khata_account_upsert', {
    if (id != null) 'p_id': id,
    if (name != null) 'p_name': name,
    if (phone != null) 'p_phone': phone,
    'p_kind': kind,
    if (limitAmount != null) 'p_limit': limitAmount,
    if (note != null) 'p_note': note,
    if (isActive != null) 'p_is_active': isActive,
  });

  /// A payment, or a manual correction. `clientActionId` is minted before the
  /// call so a tapped-twice Save resolves to the one entry the first attempt
  /// wrote — the backend holds a UNIQUE constraint on it.
  static Future<Map<String, dynamic>> addEntry({
    required String accountId,
    required String type,
    required num amount,
    String? method,
    String? note,
    String? clientActionId,
  }) => call('khata_entry_add', {
    'p_account_id': accountId,
    'p_type': type,
    'p_amount': amount,
    if (method != null) 'p_method': method,
    if (note != null) 'p_note': note,
    if (clientActionId != null) 'p_client_action_id': clientActionId,
  });

  static Future<Map<String, dynamic>> saveSettings(Map<String, dynamic> patch) =>
      call('khata_settings_save', {'p_patch': patch});

  static Future<Map<String, dynamic>> saveUpi(String vpa, {String? name}) =>
      call('khata_upi_save', {'p_vpa': vpa, if (name != null) 'p_name': name});

  static Future<Map<String, dynamic>> confirmUpi(String vpa) =>
      call('khata_upi_confirm', {'p_vpa': vpa});

  /// Exactly what a reminder would say, composed by the backend. The screen
  /// shows this verbatim before sending, so what Om reads is what goes out.
  static Future<Map<String, dynamic>> composeReminder(
    String accountId, {
    int? stage,
  }) => call('khata_reminder_compose', {
    'p_account_id': accountId,
    if (stage != null) 'p_stage': stage,
  });

  static Future<Map<String, dynamic>> remindNow(String accountId) =>
      call('khata_remind_now', {'p_account_id': accountId});

  static Future<Map<String, dynamic>> saveTemplate(int stage, String body) =>
      call('khata_template_save', {'p_stage': stage, 'p_body': body});

  static Future<Map<String, dynamic>> statementRequest(String accountId) =>
      call('khata_statement_request', {'p_account_id': accountId});

  static Future<Map<String, dynamic>> statementStatus(String statementId) =>
      call('khata_statement_status', {'p_statement_id': statementId});

  static Future<Map<String, dynamic>> statementWhatsApp(
    String statementId, {
    String? phone,
  }) => call('khata_statement_wa', {
    'p_statement_id': statementId,
    if (phone != null) 'p_phone': phone,
  });

  /// The backend names the bucket and the path; this signs it. An empty pair is
  /// an empty URL, never a guessed one.
  static Future<String> signedUrl(
    String bucket,
    String path, {
    int expiresIn = 300,
  }) async {
    if (bucket.isEmpty || path.isEmpty) return '';
    return Supabase.instance.client.storage
        .from(bucket)
        .createSignedUrl(path, expiresIn);
  }
}

/// Whether THIS account gets a khata book, and what its menu entry says.
///
/// Loaded once at boot and parked in a notifier, exactly like [PosEntry]: the
/// shell holds no label, no icon and no role test — `khata_nav_entry()` decides
/// all three, and an account that is not a pharmacy gets `show:false` so no
/// entry is drawn at all.
class KhataEntry {
  KhataEntry._();

  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  static bool get show => value.value['show'] == true;

  static Future<void> load({KhataRpc? rpc}) async {
    try {
      final res = await (rpc != null
          ? rpc('khata_nav_entry', const {})
          : KhataApi.entry());
      value.value = res['ok'] == true ? res : const {};
    } catch (_) {
      // A book entry that fails to load is simply not drawn. It must never be
      // the reason the shell fails to boot.
      value.value = const {};
    }
  }
}
