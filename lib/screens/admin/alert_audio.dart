// Platform-conditional admin alert audio + FCM-service-worker message bridge.
//
// WEB wraps the external JS functions defined in web/index.html (alert sound
// start/stop/mute, order-alert sound start/stop/mute, and the service-worker
// message handler registration). NATIVE has no such JS surface, so every
// function is a silent no-op (no alert sound on native).
export 'alert_audio_stub.dart'
    if (dart.library.html) 'alert_audio_web.dart';
