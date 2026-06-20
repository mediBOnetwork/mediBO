// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:js_interop';

@JS('mediboVoiceSpeakAsync')
external void _jsSpeakAsync(JSString text, JSFunction onDone);

/// Speak [text] via browser SpeechSynthesis.
/// Resolves when the utterance ends, on error, or after an 8-second safety timeout.
/// If SpeechSynthesis is unavailable, resolves immediately (on-screen caption is fallback).
Future<void> speakAsync(String text) {
  final c = Completer<void>();
  try {
    _jsSpeakAsync(text.toJS, (() {
      if (!c.isCompleted) c.complete();
    }).toJS);
  } catch (_) {
    c.complete();
  }
  return c.future;
}
