import 'render_log.dart';

bool _loggedOnce = false;

/// Canonical order id for display — the server's order_code, verbatim.
///
/// CHANGE #548: the old client-side fallback (which rebuilt a CPO code from
/// created_at using DDMMYY date math in Dart) is DELETED. Order codes are
/// backend-owned; a row without one renders empty rather than having the
/// client invent a date-derived id that could disagree with the server's.
String orderDisplayId(dynamic order) {
  if (!_loggedOnce) {
    _loggedOnce = true;
    RenderLog.write('c245_ordercode_helper', 'first_call');
  }
  try {
    String? code;
    if (order is Map) {
      code = (order['order_code'] ?? order['order_no'] ?? order['po'])?.toString();
    } else {
      try {
        code = (order.orderCode ?? order.orderNo ?? order.po)?.toString();
      } catch (_) {}
    }
    return code?.trim() ?? '';
  } catch (_) {
    return '';
  }
}
