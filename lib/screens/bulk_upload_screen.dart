// Platform split: web renders the bulk / WhatsApp-photo upload tool (camera
// <input>, FileReader and canvas OCR pre-processing are web-only); Android gets
// a stub that preserves the static hooks other screens reference.
export 'bulk_upload_screen_stub.dart'
    if (dart.library.html) 'bulk_upload_screen_web.dart';
