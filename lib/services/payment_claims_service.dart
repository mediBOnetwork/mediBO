// CHANGE #211 — Payment claims service (admin UPI payment verification)
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/payment_proof_image.dart' show livePaymentProofLoader;
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

  // CHANGE #267 — 3-arg form stamps order_id on the rejected claim
  static Future<void> rejectClaim(String claimId, String reason, {String? orderId}) async {
    if (claimId.isEmpty) {
      RenderLog.write('c267_bad_id', 'claimId empty');
      throw Exception('Empty claim_id — cannot reject');
    }
    await _client.rpc('reject_payment_claim', params: {
      'p_claim_id': claimId,
      'p_order_id': orderId?.isEmpty == true ? null : orderId,
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

  // CHANGE #221 — record cash payment collected in person
  static Future<Map<String, dynamic>> adminRecordCashPayment({
    required String orderId,
    required double amount,
    required String collectedBy,
    required String filePath,
    double? lat,
    double? lng,
  }) async {
    final res = await _client.rpc('admin_record_cash_payment', params: {
      'p_order_id':    orderId,
      'p_amount':      amount,
      'p_collected_by': collectedBy,
      'p_file_path':   filePath,
      'p_lat':         lat,
      'p_lng':         lng,
    });
    if (res == null) return {};
    return Map<String, dynamic>.from(res as Map);
  }

  // CHANGE #643 — one loader for every proof in the app. `bucket` is the
  // payload's own field and is used verbatim; #474's derive-from-path-prefix
  // guess is gone now that admin_payment_claims and admin_order_payment_view
  // both return it. A missing bucket is reported, never guessed.
  static Future<String?> signedScreenshotUrl(String filePath, {String? bucket}) async {
    final res = await livePaymentProofLoader.load(
        payloadBucket: bucket, path: filePath);
    RenderLog.write(
        res.ok ? 'c211_screenshot_signed_ok' : 'c211_screenshot_signed_err', 1);
    return res.url;
  }
}
