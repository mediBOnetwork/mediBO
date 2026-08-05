// Native has no alert-audio JS surface and no FCM service-worker bridge — all
// no-ops. No alert sound plays on native.
void audioStart() {}
void audioStop() {}
void audioMute(bool muted) {}
void orderAudioStart() {}
void orderAudioStop() {}
void orderAudioMute(bool muted) {}
void registerAlertHandler(void Function(Object? message) onMessage) {}
