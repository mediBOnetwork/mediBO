// Platform split: web renders the medicine importer (browser file readers +
// canvas OCR pre-processing are web-only); Android gets a stub.
export 'admin_add_medicine_screen_stub.dart'
    if (dart.library.html) 'admin_add_medicine_screen_web.dart';
