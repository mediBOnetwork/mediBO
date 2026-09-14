// CMD #1989 — tells the service worker that this order is open, so the
// lock-screen / tray card for it closes on its own.
//
// The JS side is `window.mediboAlertSeen(orderId)` in web/index.html, which
// posts the message to the registered service worker. dart:js_interop only —
// never dart:html (defensive-import rule).
import 'dart:js_interop';

@JS('mediboAlertSeen')
external JSFunction? get _mediboAlertSeen;

void webClearOrderNotification(String orderId) {
  try {
    _mediboAlertSeen?.callAsFunction(null, orderId.toJS);
  } catch (_) {
    // A browser without the bridge (or an older cached index.html) is not an
    // error: the notification simply falls back to its own timeout.
  }
}
