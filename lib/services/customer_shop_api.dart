// CHANGE #536 — the My Shop tab's one door to the backend.
//
// Same contract as PosApi (#411) and RefillApi (#417): this file forwards a
// call and hands back the payload. The section names, their order, every tile
// label, every caption, the icon key and the route each tile opens all arrive
// finished from `customer_shop_home()`. Nothing here decides what a pharmacy
// may see — the RPC resolves the caller's own role and answers for itself.
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature the My Shop surface accepts, so a test hands it a payload
/// instead of a network.
typedef CustomerShopRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class CustomerShopApi {
  CustomerShopApi._();

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
      call('customer_shop_home', const {});

  static Future<Map<String, dynamic>> badge() =>
      call('customer_shop_badge', const {});
}

/// CHANGE #536 — the number on the My Shop tab icon, decided in the backend.
///
/// Om's placement rule asked for "badge counts (expiry at risk, khata due) on
/// the tab icon where meaningful". WHERE MEANINGFUL is the backend's call, not
/// the shell's: `customer_shop_badge()` answers `show` and the already-formatted
/// `count_label` (it caps itself at 99+, because a three-digit badge is
/// unreadable on a tab icon and that is a decision, not a rendering). This
/// notifier is the same shape as PosEntry (#411) and StockEntry (#412) — the
/// tab listens to it, so the shell still knows nothing about pharmacies.
class ShopBadge {
  ShopBadge._();

  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  static bool get show => value.value['show'] == true;

  static String get label => (value.value['count_label'] ?? '').toString();

  static Future<void> load({CustomerShopRpc? rpc}) async {
    try {
      final res = await (rpc != null
          ? rpc('customer_shop_badge', const {})
          : CustomerShopApi.badge());
      value.value = res['ok'] == true ? res : const {};
    } catch (_) {
      // A badge that fails to load is simply not drawn. It must never be the
      // reason the shell fails to boot.
      value.value = const {};
    }
  }
}
