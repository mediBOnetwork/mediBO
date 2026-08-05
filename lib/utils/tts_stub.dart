// Native (non-web) fallback for the web SpeechSynthesis TTS helper.
// Public API matches tts_web.dart exactly so callers type-check identically.
import 'dart:async';

/// Native no-op: completes immediately (on-screen caption is the fallback).
Future<void> speakAsync(String text) => Future<void>.value();
