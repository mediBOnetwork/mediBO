// Native (non-web) fallback for the web FCM push-token service.
// Firebase web messaging has no native counterpart here, so both entry points
// are no-op Futures. Public API matches fcm_service_web.dart exactly.

class FcmService {
  /// Native no-op: no web FCM bridge, so there is no token to register.
  static Future<void> init(String adminId) async {}

  /// Native no-op: nothing was registered, so there is nothing to remove.
  static Future<void> removeToken() async {}
}
