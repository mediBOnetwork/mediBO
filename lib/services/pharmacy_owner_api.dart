// CHANGE #419 — the owner's three night screens, one door.
//
// Four RPCs and nothing else: this file forwards calls and hands back payloads.
// It formats no money, picks no range, decides no cohort and knows nothing
// about the anonymisation floor — the backend refuses a small cohort by sending
// a state and a sentence, and the screen prints them.
import 'pos_api.dart';

class PharmacyOwnerApi {
  PharmacyOwnerApi._();

  /// The one forwarder. Every helper below goes through it, and so does the
  /// screen's production path, so a test seam and production share a door.
  static Future<Map<String, dynamic>> call(
    String fn,
    Map<String, dynamic> params,
  ) => PosApi.call(fn, params);

  /// The night dashboard. `range` is a key the BACKEND sent in `ranges[]` —
  /// never a string this app made up.
  static Future<Map<String, dynamic>> dashboard(String range) =>
      call('pharmacy_owner_dashboard', {'p_range': range});

  static Future<Map<String, dynamic>> benchmark() =>
      call('pharmacy_benchmark', const {});

  /// Opt out of (or back into) the anonymous network aggregates.
  static Future<Map<String, dynamic>> setSharing(bool sharing) =>
      call('pharmacy_insight_optout_set', {'p_out': !sharing});

  static Future<Map<String, dynamic>> radar() =>
      call('pharmacy_demand_radar', const {});

  /// One tap fills the mediBO cart. It never places an order — the toast that
  /// says so comes from the backend too.
  static Future<Map<String, dynamic>> addToCart(
    List<Map<String, dynamic>> items,
  ) => call('pharmacy_demand_add', {'p_items': items});
}
