import 'ist_date.dart';
import 'render_log.dart';

bool _loggedOnce = false;

/// Canonical order id for display. Prefers the server order_code (CPO format);
/// falls back to a CPO-style string from UUID + created_at for stale in-memory rows.
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
    final s = code?.trim() ?? '';
    if (s.isNotEmpty) return s;

    // Fallback (stale in-memory rows missing order_code): CPO + DDMMYY + last4 of id hex.
    final rawId = (order is Map
            ? (order['id'] ?? order['order_id'])
            : _tryId(order))
        ?.toString() ??
        '';
    final hex = rawId.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    final last4 =
        hex.length >= 4 ? hex.substring(hex.length - 4).toUpperCase() : hex.toUpperCase();
    final ca = (order is Map ? order['created_at'] : _tryCreatedAt(order));
    final parsed = ca != null ? DateTime.tryParse(ca.toString()) : null;
    final ist = parsed != null ? toIst(parsed) : nowIst();
    final dd = ist.day.toString().padLeft(2, '0');
    final mm = ist.month.toString().padLeft(2, '0');
    final yy = (ist.year % 100).toString().padLeft(2, '0');
    return 'CPO$dd$mm$yy$last4';
  } catch (_) {
    return '';
  }
}

dynamic _tryId(dynamic o) {
  try {
    return o.id;
  } catch (_) {
    return null;
  }
}

dynamic _tryCreatedAt(dynamic o) {
  try {
    return o.createdAt ?? o.created_at;
  } catch (_) {
    return null;
  }
}
