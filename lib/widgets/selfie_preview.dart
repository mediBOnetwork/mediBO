// Platform-conditional selfie preview: web renders the picked image through a
// dart:ui_web platform-view <img> (tap opens the fullscreen viewer); native
// renders the picked bytes with Image.memory.
export 'selfie_preview_stub.dart'
    if (dart.library.html) 'selfie_preview_web.dart';
