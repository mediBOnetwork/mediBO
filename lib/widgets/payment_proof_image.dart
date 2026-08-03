import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/payment_proof.dart';
import '../utils/render_log.dart';
import 'fullscreen_image.dart';
import 'native_signed_image.dart';

/// CHANGE #643 — the ONE payment-proof image widget.
///
/// Every surface that shows a proof (customer order Payment card, admin payment
/// panel, admin claims list) renders this, so there is exactly one place that
/// can pick the wrong bucket or the wrong fetch method.
///
/// The fetch is always `createSignedUrl` under the signed-in session, because
/// both proof buckets are private. It is never `getPublicUrl`.

/// The production signer: an authenticated Supabase Storage call.
Future<String> liveProofSigner(String bucket, String path, int expiresIn) =>
    Supabase.instance.client.storage.from(bucket).createSignedUrl(path, expiresIn);

/// The production loader — live signer, RenderLog as the diagnostic sink.
final PaymentProofLoader livePaymentProofLoader = PaymentProofLoader(
  signer: liveProofSigner,
  logger: RenderLog.write,
);

class PaymentProofImage extends StatefulWidget {
  /// The `bucket` field off the payment entry, used verbatim.
  final String? bucket;
  final String path;

  /// Height behaviour: the customer card wants a large portrait preview, the
  /// admin thumbnail a small fixed box.
  final double? fixedHeight;
  final bool tapToEnlarge;

  /// Injectable so a test can drive the widget without Supabase.
  final PaymentProofLoader? loader;

  const PaymentProofImage({
    super.key,
    required this.bucket,
    required this.path,
    this.fixedHeight,
    this.tapToEnlarge = true,
    this.loader,
  });

  @override
  State<PaymentProofImage> createState() => _PaymentProofImageState();
}

class _PaymentProofImageState extends State<PaymentProofImage> {
  String? _url;
  bool _error = false;

  /// PART C — bumped on EVERY attempt, and folded into both the widget Key and
  /// the NativeSignedImage cacheKey. A failed load must not be cached: the next
  /// attempt registers a fresh view factory and re-requests the image, so a
  /// backend or permission fix takes effect on a tap rather than on a reinstall.
  int _attempt = 0;

  PaymentProofLoader get _loader => widget.loader ?? livePaymentProofLoader;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c643_proof_widget', 1);
    _load();
  }

  @override
  void didUpdateWidget(covariant PaymentProofImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.bucket != widget.bucket) _load();
  }

  Future<void> _load() async {
    final res = await _loader.load(payloadBucket: widget.bucket, path: widget.path);
    if (!mounted) return;
    setState(() {
      _attempt++;
      _url = res.url;
      _error = !res.ok;
    });
  }

  void _retry() {
    setState(() {
      _error = false;
      _url = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final box = BoxDecoration(
      color: const Color(0xFFF3F4F6),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFE5E7EB)),
    );

    if (_error) {
      return GestureDetector(
        onTap: _retry,
        child: Container(
          width: double.infinity,
          height: widget.fixedHeight ?? 120,
          decoration: box,
          child: const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.refresh, size: 20, color: Color(0xFF9CA3AF)),
              SizedBox(height: 4),
              Text("Couldn't load proof — tap to retry",
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)),
                  textAlign: TextAlign.center),
            ]),
          ),
        ),
      );
    }

    final url = _url;
    if (url == null) {
      return Container(
        width: double.infinity,
        height: widget.fixedHeight ?? 120,
        decoration: box,
        child: const Center(
            child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }

    RenderLog.write('c643_proof_painted', 1);
    final img = NativeSignedImage(
      key: ValueKey('${widget.bucket}/${widget.path}/$_attempt'),
      url: url,
      cacheKey: '${widget.bucket}-${widget.path.hashCode}-$_attempt',
      onTap: widget.tapToEnlarge ? () => openFullscreenImage(context, url) : null,
      onError: () {
        // A signed URL that still fails to paint (expired, CORS, deleted object)
        // is the same failure to the customer — show retry, and say so.
        RenderLog.write('c643_proof_img_err',
            'bucket=${widget.bucket};path=${widget.path}');
        if (mounted && !_error) setState(() => _error = true);
      },
    );

    final fixed = widget.fixedHeight;
    if (fixed != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(width: double.infinity, height: fixed, child: img),
      );
    }

    // CHANGE #480 — portrait 4:3 estimate off the available width, clamped to
    // 60% of screen height so the selfie/screenshot is clearly readable.
    return LayoutBuilder(builder: (lCtx, constraints) {
      final w = constraints.maxWidth;
      final maxH = MediaQuery.of(lCtx).size.height * 0.6;
      final h = (w * 1.33).clamp(240.0, maxH);
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(width: double.infinity, height: h, child: img),
      );
    });
  }
}
