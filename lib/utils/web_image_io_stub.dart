// Native (Android) image ops via package:image — mirrors web_image_io_web.dart.
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Decodes [bytes] into a reusable handle (img.Image) or null on failure.
Future<Object?> decodeImageHandle(Uint8List bytes, String mime) async {
  try {
    return img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
}

int imgWidth(Object h) => (h as img.Image).width;
int imgHeight(Object h) => (h as img.Image).height;

/// Crops source region [sx,sy,sw,sh], scales to [outW]x[outH] over a white
/// background, returns PNG (default) or JPEG bytes.
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
    final src = handle as img.Image;
    final x = sx.round().clamp(0, src.width - 1);
    final y = sy.round().clamp(0, src.height - 1);
    final w = sw.round().clamp(1, src.width - x);
    final h = sh.round().clamp(1, src.height - y);
    final cropped = img.copyCrop(src, x: x, y: y, width: w, height: h);
    final resized = img.copyResize(cropped, width: outW, height: outH);
    // White fill, then composite — matches the web canvas white-fill behaviour.
    final canvas = img.Image(width: outW, height: outH)
      ..clear(img.ColorRgb8(255, 255, 255));
    img.compositeImage(canvas, resized);
    return jpeg
        ? Uint8List.fromList(img.encodeJpg(canvas, quality: (quality * 100).round()))
        : Uint8List.fromList(img.encodePng(canvas));
  } catch (_) {
    return null;
  }
}

/// Grayscale + contrast + resize-to-[maxDim] preprocessing, returns JPEG bytes.
Future<Uint8List?> enhanceForOcrJpeg(Uint8List bytes, String mime,
    {int maxDim = 1600}) async {
  try {
    var im = img.decodeImage(bytes);
    if (im == null) return null;
    if (im.width > maxDim || im.height > maxDim) {
      im = im.width >= im.height
          ? img.copyResize(im, width: maxDim)
          : img.copyResize(im, height: maxDim);
    }
    im = img.grayscale(im);
    im = img.adjustColor(im, contrast: 1.6, brightness: 1.08);
    return Uint8List.fromList(img.encodeJpg(im, quality: 92));
  } catch (_) {
    return null;
  }
}

/// Convenience: decode just to read intrinsic dimensions.
Future<({int w, int h})?> imageDims(Uint8List bytes, String mime) async {
  final im = img.decodeImage(bytes);
  if (im == null) return null;
  return (w: im.width, h: im.height);
}
