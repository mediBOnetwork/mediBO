// CHANGE #211 — Payment claims service (admin UPI payment verification)
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/render_log.dart';

class PaymentClaimsService {
  static SupabaseClient get _client => Supabase.instance.client;

  static Future<List<Map<String, dynamic>>> fetchClaims() async {
    final res = await _client.rpc('admin_payment_claims', params: {'p_limit': 50});
    RenderLog.write('c211_service_loaded', 1);
    if (res == null) return [];
    return List<Map<String, dynamic>>.from(res as List);
  }

  // CHANGE #213 — guard against empty ids (fix: "invalid input syntax for type uuid")
  static Future<void> verifyAndAccept(String claimId, String orderId) async {
    if (claimId.isEmpty || orderId.isEmpty) {
      RenderLog.write('c213_bad_id', 'claimId=$claimId orderId=$orderId');
      throw Exception('Empty claim_id or order_id — cannot call verify_and_accept_payment');
    }
    await _client.rpc('verify_and_accept_payment', params: {
      'p_claim_id': claimId,
      'p_order_id': orderId,
    });
  }

  static Future<void> rejectClaim(String claimId, String reason) async {
    await _client.rpc('reject_payment_claim', params: {
      'p_claim_id': claimId,
      'p_reason': reason,
    });
  }

  // CHANGE #213 — per-order payment view (nested advance/rest/other buckets)
  static Future<Map<String, dynamic>> orderPaymentView(String orderId) async {
    final res = await _client
        .rpc('admin_order_payment_view', params: {'p_order_id': orderId});
    RenderLog.write('c213_service_loaded', 1);
    if (res == null) return {};
    return Map<String, dynamic>.from(res as Map);
  }

  // CHANGE #212 — per-order payment data (legacy, kept for reference)
  static Future<Map<String, dynamic>> orderPayment(String orderId) async {
    final res = await _client
        .rpc('admin_order_payment', params: {'p_order_id': orderId});
    RenderLog.write('c212_service_loaded', 1);
    if (res == null) return {};
    return Map<String, dynamic>.from(res as Map);
  }

  // CHANGE #214 — two-step received flow (step 1: mark payment received + WhatsApp)
  static Future<Map<String, dynamic>> markPaymentReceived(
      String claimId, String orderId) async {
    if (claimId.isEmpty || orderId.isEmpty) {
      RenderLog.write('c214_bad_id', 'claimId=$claimId orderId=$orderId');
      throw Exception('Empty claim_id or order_id');
    }
    final res = await _client.rpc('mark_payment_received', params: {
      'p_claim_id': claimId,
      'p_order_id': orderId,
    });
    if (res == null) return {};
    return Map<String, dynamic>.from(res as Map);
  }

  static Future<String?> signedScreenshotUrl(String filePath) async {
    try {
      final url = await _client.storage
          .from('whatsapp-media')
          .createSignedUrl(filePath, 3600);
      RenderLog.write('c211_screenshot_signed_ok', 1);
      return url;
    } catch (_) {
      RenderLog.write('c211_screenshot_signed_err', 1);
      return null;
    }
  }
}
