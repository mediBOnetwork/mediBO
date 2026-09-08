import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../widgets/fullscreen_image.dart';
import '../../widgets/native_signed_image.dart';

/// CMD #1914 — the file that was actually uploaded, on the card.
///
/// The upload screen used to describe a document it never showed, so the only
/// way to find out which photo was on file was to upload another one. This is
/// that photo: a small square on the card, tapped to see it full.
///
/// The bucket is PRIVATE, so the URL is signed under the applicant's own
/// session — never `getPublicUrl`, which returns a link that fails no matter
/// how correct the storage policies are. WHICH object to sign, whether it is a
/// picture at all, and every word this widget can print all arrive inside the
/// `preview` object from `kyc_my_panel()`.
class KycDocThumb extends StatefulWidget {
  const KycDocThumb({super.key, required this.preview});

  /// `items[].preview` out of `kyc_my_panel()`. Null = nothing uploaded yet.
  final Map<String, dynamic>? preview;

  /// Test seam — the live signer is an authenticated Supabase Storage call.
  @visibleForTesting
  static Future<String> Function(String bucket, String path, int expiresIn)?
      signer;

  /// Test seam — what a tap on a PDF opens.
  @visibleForTesting
  static Future<bool> Function(String url)? opener;

  static Future<String> sign(String bucket, String path, int expiresIn) {
    final s = signer;
    if (s != null) return s(bucket, path, expiresIn);
    return Supabase.instance.client.storage
        .from(bucket)
        .createSignedUrl(path, expiresIn);
  }

  static Future<bool> open(String url) {
    final o = opener;
    if (o != null) return o(url);
    return launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// One hour: long enough to look at the document twice, short enough that a
  /// copied link stops working.
  static const int ttlSeconds = 3600;

  @override
  State<KycDocThumb> createState() => _KycDocThumbState();
}

class _KycDocThumbState extends State<KycDocThumb> {
  String? _url;
  bool _error = false;
  int _attempt = 0;

  String _s(String k) => (widget.preview?[k] ?? '').toString();

  bool get _isPdf => widget.preview?['is_pdf'] == true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant KycDocThumb old) {
    super.didUpdateWidget(old);
    if (old.preview?['path'] != widget.preview?['path']) _load();
  }

  Future<void> _load() async {
    final p = widget.preview;
    final bucket = (p?['bucket'] ?? '').toString();
    final path = (p?['path'] ?? '').toString();
    if (bucket.isEmpty || path.isEmpty) return;
    try {
      final url = await KycDocThumb.sign(bucket, path, KycDocThumb.ttlSeconds);
      if (!mounted) return;
      setState(() {
        _attempt++;
        _url = url;
        _error = false;
      });
      RenderLog.write('c1914_kyc_thumb', 1);
    } catch (e) {
      if (!mounted) return;
      RenderLog.write('c1914_kyc_thumb_err', 'bucket=$bucket;path=$path');
      setState(() {
        _attempt++;
        _url = null;
        _error = true;
      });
    }
  }

  /// 64: the smallest square in which a licence is still recognisable, built
  /// from the space scale so a token change moves it with everything else.
  double get _side => Ds.space.x48 + Ds.space.x16;

  Widget _shell({required Widget child, VoidCallback? onTap}) {
    final box = Container(
      width: _side,
      height: _side,
      decoration: BoxDecoration(
        color: Ds.c.bg,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
    if (onTap == null) return box;
    return GestureDetector(
        behavior: HitTestBehavior.opaque, onTap: onTap, child: box);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.preview;
    if (p == null || _s('path').isEmpty) {
      return _shell(
        child: Icon(Icons.description_outlined,
            color: Ds.c.textSecondary, size: Ds.space.x24),
      );
    }

    if (_error) {
      return _shell(
        onTap: _load,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x4),
            child: Text(_s('error_label'),
                style: Ds.t.caption, textAlign: TextAlign.center, maxLines: 3),
          ),
        ),
      );
    }

    final url = _url;
    if (url == null) {
      return _shell(
        child: Center(
          child: SizedBox(
            width: Ds.space.x16,
            height: Ds.space.x16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Ds.c.textSecondary),
          ),
        ),
      );
    }

    // A PDF has no thumbnail to paint: it opens in the viewer the device
    // already has. The word on the tile is the backend's.
    if (_isPdf) {
      return _shell(
        onTap: () => KycDocThumb.open(url),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.picture_as_pdf_outlined,
                color: Ds.c.textSecondary, size: Ds.space.x24),
            SizedBox(height: Ds.space.x4),
            Text(_s('pdf_label'), style: Ds.t.caption),
          ],
        ),
      );
    }

    return _shell(
      child: NativeSignedImage(
        key: ValueKey('${_s('bucket')}/${_s('path')}/$_attempt'),
        url: url,
        cacheKey: '${_s('bucket')}-${_s('path').hashCode}-$_attempt',
        onTap: () => openFullscreenImage(context, url),
        onError: () {
          if (!mounted || _error) return;
          RenderLog.write(
              'c1914_kyc_thumb_err', 'paint;path=${_s('path')}');
          setState(() => _error = true);
        },
      ),
    );
  }
}
