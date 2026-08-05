// Platform-conditional fullscreen image viewer.
//
// WEB renders the image as a native <img> platform view to dodge CORS on
// signed storage URLs (see fullscreen_image_web.dart). NATIVE has no CORS
// restriction, so it pushes a plain Flutter fullscreen route.
export 'fullscreen_image_stub.dart'
    if (dart.library.html) 'fullscreen_image_web.dart';
