// Platform split: web renders the supplier console (CSV file pickers, window.open
// mailto/wa links are web-only); Android gets a stub.
export 'admin_supplier_screen_stub.dart'
    if (dart.library.html) 'admin_supplier_screen_web.dart';
