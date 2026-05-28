import 'dart:async';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:js' as js;

class PaymentService {
  /// Opens the Razorpay checkout modal via JS interop.
  /// Returns a map with keys: status, payment_id, description.
  /// status values: 'success' | 'failed' | 'dismissed'
  static Future<Map<String, String>> initiatePayment({
    required double amount,
    String name = '',
    String email = '',
    String phone = '',
  }) {
    final completer = Completer<Map<String, String>>();

    // ignore: deprecated_member_use
    final callback = js.allowInterop(
        (String status, String p1, String p2, String p3) {
      if (!completer.isCompleted) {
        completer.complete({
          'status': status,
          'payment_id': p1,
          'description': p2,
        });
      }
    });

    js.context.callMethod('openRazorpay', [
      (amount * 100).toInt(),
      name,
      email,
      phone,
      callback,
    ]);

    return completer.future;
  }
}
