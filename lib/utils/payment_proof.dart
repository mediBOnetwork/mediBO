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

/// CHANGE #644 — how big a render to ask the STORAGE layer for.
///
/// Proofs are raw phone-camera photos: the cash proofs in this project run
/// 2–5 MB (largest measured 5.03 MB). Asking for the original meant the
/// customer's browser had to pull and decode several megabytes before anything
/// appeared, which is why the card fell through to "Couldn't load proof — tap
/// to retry" on a phone while the same image rendered for admin on a desk.
///
/// [resizeContain] is not optional. Supabase's transform scales only the
/// dimension you give it and leaves the other at its original size, so a
/// 3456x4608 photo asked for `width: 480` comes back 480x4608 — an
/// aspect-ratio-broken sliver that renders as an effectively blank thumbnail.
/// bill_viewer.dart learned this the hard way in #469; the same trap applies
/// here.
class ProofTransform {
  final int width;
  final int quality;
  const ProofTransform({required this.width, required this.quality});

  /// The card preview — small enough to appear immediately on mobile data.
  static const ProofTransform preview = ProofTransform(width: 480, quality: 70);

  /// The fullscreen view — sharp, still an order of magnitude under the
  /// original.
  static const ProofTransform full = ProofTransform(width: 1600, quality: 80);

  @override
  String toString() => 'w=$width,q=$quality';
}

/// Signs one object. Implementations MUST use an authenticated storage call.
/// [transform] null means "the original bytes" — avoid it for anything a phone
/// has to render.
typedef ProofSigner = Future<String> Function(
    String bucket, String path, int expiresInSeconds, ProofTransform? transform);

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
    this.fullUrl,
  });

  /// A larger render for the fullscreen view. Null when only a preview was
  /// requested.
  final String? fullUrl;

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
    ProofTransform? transform = ProofTransform.preview,
    ProofTransform? alsoSign,
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
      // Both renders are signed in ONE round trip so tapping through to
      // fullscreen does not pay a second latency hit.
      final urls = await Future.wait([
        signer(bucket, p, kSignedUrlTtlSeconds, transform),
        if (alsoSign != null) signer(bucket, p, kSignedUrlTtlSeconds, alsoSign),
      ]).timeout(timeout);
      logger?.call('c643_proof_signed_ok',
          'bucket=$bucket;transform=${transform ?? "original"}');
      return ProofLoadResult(
          url: urls.first,
          fullUrl: urls.length > 1 ? urls[1] : null,
          bucket: bucket,
          path: p);
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
