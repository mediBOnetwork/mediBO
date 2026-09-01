// CMD #417 — the refill engine's one door to the backend.
//
// Same contract as PosApi (#411) and KhataApi (#415): this file forwards calls
// and hands back payloads. Every rupee, every "runs out Thursday", every
// reminder sentence, every plural and every tone arrives finished from
// Supabase. There is no arithmetic here, and none in the screens that read it.
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature every refill surface accepts, so a test hands it a payload
/// instead of a network.
typedef RefillRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class RefillApi {
  RefillApi._();

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
      call('refill_nav_entry', const {});

  static Future<Map<String, dynamic>> home({String? q}) =>
      call('refill_home', {if (q != null && q.isNotEmpty) 'p_q': q});

  static Future<Map<String, dynamic>> saveSettings(
    Map<String, dynamic> patch,
  ) => call('refill_settings_save', {'p_patch': patch});

  static Future<Map<String, dynamic>> optIn(String patientId, bool on) =>
      call('refill_patient_optin', {'p_patient_id': patientId, 'p_on': on});

  static Future<Map<String, dynamic>> setSchedule(
    String id,
    Map<String, dynamic> patch,
  ) => call('refill_schedule_set', {'p_id': id, 'p_patch': patch});

  static Future<Map<String, dynamic>> nudge(String scheduleId) =>
      call('refill_nudge_now', {'p_schedule_id': scheduleId});

  static Future<Map<String, dynamic>> scan() =>
      call('refill_scan', {'p_days': 180});

  static Future<Map<String, dynamic>> saveStorefront(
    Map<String, dynamic> patch,
  ) => call('storefront_save', {'p_patch': patch});

  static Future<Map<String, dynamic>> reservations({String status = 'open'}) =>
      call('pos_reservations', {'p_status': status});

  static Future<Map<String, dynamic>> closeReservation(
    String id,
    String status,
  ) => call('pos_reservation_close', {'p_id': id, 'p_status': status});

  /// The PUBLIC storefront a patient opens from the shared link. Anonymous by
  /// design — the token in the URL is the authorisation, exactly the way
  /// `/stock-update/<token>` works.
  static Future<Map<String, dynamic>> storefrontPage(
    String token, {
    String? q,
    int limit = 40,
    int offset = 0,
  }) => call('wa_storefront_page', {
    'p_token': token,
    if (q != null && q.isNotEmpty) 'p_q': q,
    'p_limit': limit,
    'p_offset': offset,
  });

  static Future<Map<String, dynamic>> storefrontSubmit({
    required String token,
    required String name,
    required String phone,
    required List<Map<String, dynamic>> items,
    String? note,
  }) => call('storefront_request_submit', {
    'p_token': token,
    'p_name': name,
    'p_phone': phone,
    'p_items': items,
    if (note != null && note.isNotEmpty) 'p_note': note,
  });
}

/// Whether THIS account gets the refill console, and what its entry says.
///
/// Loaded at boot and parked in a notifier, exactly like [KhataEntry]: the
/// shell holds no label, no icon and no role test — `refill_nav_entry()`
/// decides all three, and an account that is not a pharmacy gets `show:false`
/// so no entry is drawn at all.
class RefillEntry {
  RefillEntry._();

  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  static bool get show => value.value['show'] == true;

  static Future<void> load({RefillRpc? rpc}) async {
    try {
      final res = await (rpc != null
          ? rpc('refill_nav_entry', const {})
          : RefillApi.entry());
      value.value = res['ok'] == true ? res : const {};
    } catch (_) {
      // An entry that fails to load is simply not drawn. It must never be the
      // reason the shell fails to boot.
      value.value = const {};
    }
  }
}
