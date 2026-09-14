// CMD #1989 — the one call the app makes into the browser's notification tray.
//
// Conditional export, exactly like fcm_service.dart: the web build gets the
// dart:js_interop bridge, every other build gets a no-op. Nothing here ever
// imports dart:html — this file is reachable from the widget tree, and the
// defensive-import rule exists because that combination white-screened the app.
export 'order_alert_sw_stub.dart'
    if (dart.library.js_interop) 'order_alert_sw_web.dart';
