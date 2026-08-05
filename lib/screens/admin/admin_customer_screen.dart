// Platform split: web renders the full customer console; Android gets a stub
// (its file pickers, native <img> platform views and geolocation are web-only).
export 'admin_customer_screen_stub.dart'
    if (dart.library.html) 'admin_customer_screen_web.dart';
