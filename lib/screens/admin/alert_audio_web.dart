// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:js_interop';

import 'package:flutter/foundation.dart';

// ── External JS function declarations (web only) ─────────────────────────────

@JS('adminAlertStart')
external void _jsStart();

@JS('adminAlertStop')
external void _jsStop();

@JS('adminAlertMute')
external void _jsMute(bool muted);

@JS('adminAlertRegisterMessageHandler')
external void _jsRegisterHandler(JSFunction callback);

@JS('adminOrderAlertStart')
external void _jsOrderStart();

@JS('adminOrderAlertStop')
external void _jsOrderStop();

@JS('adminOrderAlertMute')
external void _jsOrderMuteJs(bool muted);

void audioStart() {
  if (!kIsWeb) return;
  try { _jsStart(); } catch (_) {}
}

void audioStop() {
  if (!kIsWeb) return;
  try { _jsStop(); } catch (_) {}
}

void audioMute(bool muted) {
  if (!kIsWeb) return;
  try { _jsMute(muted); } catch (_) {}
}

void orderAudioStart() {
  if (!kIsWeb) return;
  try { _jsOrderStart(); } catch (_) {}
}

void orderAudioStop() {
  if (!kIsWeb) return;
  try { _jsOrderStop(); } catch (_) {}
}

void orderAudioMute(bool muted) {
  if (!kIsWeb) return;
  try { _jsOrderMuteJs(muted); } catch (_) {}
}

// Registers the FCM service-worker message handler. The JS bridge (dartify +
// try/catch) lives here; the caller receives an already-Dartified message and
// keeps its own type/id decision logic.
void registerAlertHandler(void Function(Object? message) onMessage) {
  if (!kIsWeb) return;
  try {
    _jsRegisterHandler(((JSAny? rawMsg) {
      if (rawMsg == null) return;
      try {
        onMessage(rawMsg.dartify());
      } catch (_) {}
    }).toJS);
  } catch (_) {}
}
