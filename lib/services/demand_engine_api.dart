// CMD #427 — the demand engine's one door to the backend.
//
// Forwarding only. Every rupee, percentage, unit count, cohort line, tab label,
// month name, seasonal factor and privacy sentence on both surfaces is a
// finished string from `admin_demand_engine()` / `pharmacy_overpay_insights()`.
// Nothing here medians, ranks, formats or compares anything — the whole point
// of this command is that a cross-pharmacy number is computed in exactly one
// place, under the cohort floor, and this is not that place.

import 'package:flutter/foundation.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature both surfaces accept, so a test hands them a payload instead of a
/// network.
typedef DemandRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class DemandEngineApi {
  DemandEngineApi._();

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

  /// The admin engine. An untouched zone or month filter is an ABSENT
  /// parameter — never an empty string, never a guessed default. The backend
  /// picks the busiest zone and the current month when it hears nothing.
  static Future<Map<String, dynamic>> engine({int? zoneId, String? monthKey}) =>
      call('admin_demand_engine', {
        if (zoneId != null) 'p_zone': zoneId,
        if (monthKey != null && monthKey.isNotEmpty) 'p_month': monthKey,
      });

  static Future<Map<String, dynamic>> overpayEntry() =>
      call('pharmacy_overpay_entry', const {});

  static Future<Map<String, dynamic>> overpayInsights() =>
      call('pharmacy_overpay_insights', const {});

  static Future<Map<String, dynamic>> overpayDismiss(String id) =>
      call('pharmacy_overpay_dismiss', {'p_id': id});
}

/// Whether the price-check button exists at all, and what it says — the
/// backend's call, exactly as the vault and the exchange do it. A non-pharmacy
/// account gets `show:false` and no button, without a role test in Dart.
class OverpayEntry {
  OverpayEntry._();

  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  static bool get show => value.value['show'] == true;

  static Future<void> load({DemandRpc? rpc}) async {
    try {
      final res = await (rpc != null
          ? rpc('pharmacy_overpay_entry', const {})
          : DemandEngineApi.overpayEntry());
      value.value = res['show'] == true ? res : const {};
    } catch (_) {
      value.value = const {};
    }
  }
}
