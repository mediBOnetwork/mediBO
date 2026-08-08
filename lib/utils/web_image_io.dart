// Platform-conditional image decode / crop / OCR-enhance.
//   Web    → HTML <canvas> (byte-identical to the original inline code).
//   Native → package:image (pure Dart, already a dependency).
// The public API is identical on both so bulk_upload_screen.dart carries no
// dart:html and compiles for Android unchanged.
//
// A decoded image is an opaque `Object` handle (html.ImageElement on web,
// img.Image on native) so it can be decoded once and reused across many crops.
export 'web_image_io_stub.dart' if (dart.library.html) 'web_image_io_web.dart';
