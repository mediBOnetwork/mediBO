// CHANGE #536 — the My Shop tab's one door to the backend.
//
// Same contract as PosApi (#411) and RefillApi (#417): this file forwards a
// call and hands back the payload. The section names, their order, every tile
// label, every caption, the icon key and the route each tile opens all arrive
// finished from `customer_shop_home()`. Nothing here decides what a pharmacy
// may see — the RPC resolves the caller's own role and answers for itself.
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
}
