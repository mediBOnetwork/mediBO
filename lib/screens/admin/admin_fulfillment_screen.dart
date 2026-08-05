// Platform split: web renders shop/warehouse/pack fulfillment (barcode scan,
// browser audio, CustomEvent selftest hooks are web-only); Android gets a stub.
export 'admin_fulfillment_screen_stub.dart'
    if (dart.library.html) 'admin_fulfillment_screen_web.dart';
