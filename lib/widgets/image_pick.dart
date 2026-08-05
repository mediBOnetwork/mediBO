// Platform-conditional image picker: web uses a dart:html file input +
// FileReader; native uses image_picker (camera, the natural selfie source).
export 'image_pick_stub.dart'
    if (dart.library.html) 'image_pick_web.dart';
