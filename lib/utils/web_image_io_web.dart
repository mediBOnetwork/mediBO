// Web image ops via HTML <canvas>. Verbatim behaviour lifted from the original
// inline bulk_upload code so the web build is unchanged.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

/// Decodes [bytes] into a reusable handle (html.ImageElement) or null on failure.
Future<Object?> decodeImageHandle(Uint8List bytes, String mime) async {
  try {
    final blob = html.Blob([bytes], mime);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final img = html.ImageElement()..src = url;
    await img.onLoad.first.timeout(const Duration(seconds: 15));
    html.Url.revokeObjectUrl(url);
    return img.naturalWidth > 0 ? img : null;
  } catch (_) {
    return null;
  }
}

int imgWidth(Object h) => (h as html.ImageElement).naturalWidth;
int imgHeight(Object h) => (h as html.ImageElement).naturalHeight;

/// Draws a source region [sx,sy,sw,sh] scaled into an [outW]x[outH] canvas over
/// a white fill, and returns PNG (default) or JPEG bytes.
Uint8List? drawCrop(
  Object handle, {
  required double sx,
  required double sy,
  required double sw,
  required double sh,
  required int outW,
  required int outH,
  bool jpeg = false,
  num quality = 0.92,
}) {
  try {
    final img = handle as html.ImageElement;
    final canvas = html.CanvasElement(width: outW, height: outH);
    final ctx = canvas.context2D;
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, outW.toDouble(), outH.toDouble());
    ctx.imageSmoothingEnabled = true;
    ctx.drawImageScaledFromSource(
        img, sx, sy, sw, sh, 0, 0, outW.toDouble(), outH.toDouble());
    final dataUrl =
        jpeg ? canvas.toDataUrl('image/jpeg', quality) : canvas.toDataUrl('image/png');
    return base64Decode(dataUrl.split(',').last);
  } catch (_) {
    return null;
  }
}

/// Grayscale + contrast + resize-to-[maxDim] preprocessing, returns JPEG bytes.
Future<Uint8List?> enhanceForOcrJpeg(Uint8List bytes, String mime,
    {int maxDim = 1600}) async {
  try {
    final blob = html.Blob([bytes], mime);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final img = html.ImageElement()..src = url;
    await img.onLoad.first.timeout(const Duration(seconds: 10));
    html.Url.revokeObjectUrl(url);
    final srcW = img.naturalWidth, srcH = img.naturalHeight;
    if (srcW == 0 || srcH == 0) return null;
    int dstW = srcW, dstH = srcH;
    if (srcW > maxDim || srcH > maxDim) {
      final scale = maxDim / (srcW > srcH ? srcW : srcH);
      dstW = (srcW * scale).round();
      dstH = (srcH * scale).round();
    }
    final canvas = html.CanvasElement(width: dstW, height: dstH);
    final ctx = canvas.context2D;
    ctx.filter = 'grayscale(100%) contrast(160%) brightness(108%)';
    ctx.drawImageScaled(img, 0, 0, dstW.toDouble(), dstH.toDouble());
    return base64Decode(canvas.toDataUrl('image/jpeg', 0.92).split(',').last);
  } catch (_) {
    return null;
  }
}

/// Convenience: decode just to read intrinsic dimensions.
Future<({int w, int h})?> imageDims(Uint8List bytes, String mime) async {
  final h = await decodeImageHandle(bytes, mime);
  if (h == null) return null;
  return (w: imgWidth(h), h: imgHeight(h));
}
