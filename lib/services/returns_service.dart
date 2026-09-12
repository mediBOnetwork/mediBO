// CHANGE #395 — Returns, refunds and cancellation.
//
// Every string, amount, chip, tone and enabled/disabled flag in this feature is
// composed by Supabase and rendered verbatim. This file therefore holds no
// display text and does no arithmetic: it is a typed door onto six RPCs plus
// the one edge function that actually moves money.
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

class ReturnsService {
  static SupabaseClient get _c => Supabase.instance.client;

  static Map<String, dynamic> _map(Object? res) =>
      res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};

  /// The screen's entry list: recent orders with their return/refund chips.
  static Future<Map<String, dynamic>> ordersList({String? q, int limit = 40}) async {
    final res = await _c.rpc('returns_orders_list',
        params: {'p_q': (q ?? '').trim().isEmpty ? null : q!.trim(), 'p_limit': limit});
    final m = _map(res);
    RenderLog.write('c395_orders_list', (m['rows'] as List?)?.length ?? 0);
    return m;
  }

  /// ONE payload for the whole order: reasons, billed lines, returns, refunds,
  /// the cancellation and the money. The screen renders it and decides nothing.
  static Future<Map<String, dynamic>> panel(String orderId) async {
    final res = await _c.rpc('order_returns_panel', params: {'p_order_id': orderId});
    final m = _map(res);
    RenderLog.write('c395_panel_loaded', 1);
    RenderLog.write('c395_panel_returns', (m['returns'] as List?)?.length ?? 0);
    RenderLog.write('c395_panel_refunds', (m['refunds'] as List?)?.length ?? 0);
    return m;
  }

  static Future<Map<String, dynamic>> addReturn({
    required String orderId,
    required String orderItemId,
    required num qty,
    String? reasonCode,
    String? conditionCode,
    String? note,
    String? photoPath,
  }) async {
    final res = await _c.rpc('order_return_add', params: {
      'p_order_id': orderId,
      'p_order_item_id': orderItemId,
      'p_qty': qty,
      'p_reason_code': reasonCode,
      'p_condition_code': conditionCode,
      'p_note': note,
      'p_photo_path': photoPath,
    });
    return _map(res);
  }

  static Future<Map<String, dynamic>> approveReturn(String returnId) async =>
      _map(await _c.rpc('order_return_approve', params: {'p_return_id': returnId}));

  static Future<Map<String, dynamic>> rejectReturn(String returnId, String? reason) async =>
      _map(await _c.rpc('order_return_reject',
          params: {'p_return_id': returnId, 'p_reason': reason}));

  /// CHANGE #472 — `clientActionId` is the caller's ONE key for this refund.
  /// refund_request answers a repeat with the first refund instead of minting
  /// a second one, so a retry after a timeout must pass the SAME key. A caller
  /// that omits it gets the old behaviour and no protection.
  static Future<Map<String, dynamic>> requestRefund({
    required String orderId,
    required num amount,
    String? reasonCode,
    String? method,
    String? note,
    String? clientActionId,
  }) async =>
      _map(await _c.rpc('refund_request', params: {
        'p_order_id': orderId,
        'p_amount': amount,
        'p_reason_code': reasonCode,
        'p_method': method,
        'p_note': note,
        'p_client_action_id': clientActionId,
      }));

  /// Razorpay leg. The edge function re-derives the amount server-side and caps
  /// it at what was collected, so nothing here is trusted with money.
  static Future<Map<String, dynamic>> sendRefundToRazorpay(String refundId) async {
    final res = await _c.functions.invoke('razorpay-refund-create',
        body: {'refund_id': refundId});
    return _map(res.data);
  }

  static Future<Map<String, dynamic>> markRefundManual(String refundId, String? utr) async =>
      _map(await _c.rpc('refund_mark_manual',
          params: {'p_refund_id': refundId, 'p_utr': utr}));

  static Future<Map<String, dynamic>> cancelRefund(String refundId, String? reason) async =>
      _map(await _c.rpc('refund_cancel',
          params: {'p_refund_id': refundId, 'p_reason': reason}));

  static Future<Map<String, dynamic>> cancelOrder({
    required String orderId,
    required String reasonCode,
    String? note,
  }) async =>
      _map(await _c.rpc('order_cancel', params: {
        'p_order_id': orderId,
        'p_reason_code': reasonCode,
        'p_note': note,
      }));
}
