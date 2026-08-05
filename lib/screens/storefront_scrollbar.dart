// Platform-conditional scrollbar CSS injection: web injects a <style> element
// into document.head; native is a no-op (no DOM, no custom scrollbar styling).
export 'storefront_scrollbar_stub.dart'
    if (dart.library.html) 'storefront_scrollbar_web.dart';
