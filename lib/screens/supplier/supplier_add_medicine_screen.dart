// Platform split: web renders the supplier add-medicine OCR flow (browser file
// picker is web-only); Android gets a stub.
export 'supplier_add_medicine_screen_stub.dart'
    if (dart.library.html) 'supplier_add_medicine_screen_web.dart';
