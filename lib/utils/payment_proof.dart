// CHANGE #643 — ONE loader for every payment-proof image in the app.
//
// Proofs live in one of two PRIVATE buckets: WhatsApp/cash proofs land in
// 'whatsapp-media', customer-app uploads in 'payment-proofs'. Because both are
// private, a proof can only be fetched with an AUTHENTICATED call —
// `createSignedUrl` under the signed-in user's session. `getPublicUrl` (and any
// hand-built .../object/public/... URL) returns a link that fails no matter how
// correct the storage policies are.
//
// WHICH bucket is not the app's decision. Every payload that carries a proof
// now names its bucket:
//   customer_order_payment_panel().payments[].bucket
//   admin_order_payment_view().*.bucket        (added in #643)
//   admin_payment_claims().*.bucket            (added in #643)
//
// So #474's guess-from-path-prefix resolver is GONE. If a payload ever arrives
// without a bucket the loader refuses to invent one and reports it — a loud
// failure beats a silent wrong bucket, which is how the customer-side breakage
// stayed invisible until someone opened a live DB session.
//
// This file imports no dart:html and no Supabase, so the whole decision path is
// reachable from a plain VM test. The live Supabase call is injected.

/// Signs one object. Implementations MUST use an authenticated storage call.
typedef ProofSigner = Future<String> Function(
    String bucket, String path, int expiresInSeconds);

/// Diagnostic sink — RenderLog in production, a list in tests.
typedef ProofLogger = void Function(String key, String value);

/// What a load attempt produced. `url == null` means the caller shows its retry
/// affordance; [error] says why, for the log rather than the screen.
class ProofLoadResult {
  final String? url;
  final String bucket;
  final String path;
  final String? error;

  const ProofLoadResult({
    this.url,
    required this.bucket,
    required this.path,
    this.error,
  });

  bool get ok => url != null;
}

class PaymentProofLoader {
  final ProofSigner signer;
  final ProofLogger? logger;
  final Duration timeout;

  const PaymentProofLoader({
    required this.signer,
    this.logger,
    this.timeout = const Duration(seconds: 8),
  });

  /// Signed URLs last an hour — long enough to view and re-open the card, short
  /// enough that a leaked link expires.
  static const int kSignedUrlTtlSeconds = 3600;

  /// Loads one proof.
  ///
  /// [payloadBucket] is the `bucket` field off the payment entry, used VERBATIM.
  /// Nothing here inspects the path to choose a bucket.
  ///
  /// Never throws: a failure is a [ProofLoadResult] with `url == null` and the
  /// storage error preserved in [ProofLoadResult.error], plus a log line
  /// carrying the bucket, the path and the message.
  Future<ProofLoadResult> load({
    required String? payloadBucket,
    required String path,
  }) async {
    final bucket = (payloadBucket ?? '').trim();
    final p = path.trim();

    if (p.isEmpty) {
      return _fail(bucket, p, 'empty path', 'c643_proof_no_path');
    }
    if (bucket.isEmpty) {
      // The app does NOT guess. See the header note.
      return _fail(bucket, p, 'payload carried no bucket', 'c643_proof_no_bucket');
    }

    try {
      final url = await signer(bucket, p, kSignedUrlTtlSeconds).timeout(timeout);
      logger?.call('c643_proof_signed_ok', 'bucket=$bucket');
      return ProofLoadResult(url: url, bucket: bucket, path: p);
    } catch (e) {
      // PART B — the message, the bucket and the path, every time. This failure
      // used to be silent on screen AND in the logs.
      return _fail(bucket, p, e.toString(), 'c643_proof_sign_err');
    }
  }

  ProofLoadResult _fail(String bucket, String path, String err, String key) {
    logger?.call(
        key, 'bucket=${bucket.isEmpty ? "(none)" : bucket};path=$path;err=$err');
    return ProofLoadResult(bucket: bucket, path: path, error: err);
  }
}
