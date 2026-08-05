// CHANGE #476 — native <img> renderer for signed storage URLs.
//
// On WEB, Image.network fetches image bytes via XHR/fetch under CanvasKit,
// which is subject to CORS and can silently blank a signed Supabase Storage
// URL. The web implementation dodges that with a real <img> element (see
// native_signed_image_web.dart). On NATIVE there is no CORS restriction on
// image loading, so a normal cached network image works — the stub version.
export 'native_signed_image_stub.dart'
    if (dart.library.html) 'native_signed_image_web.dart';
