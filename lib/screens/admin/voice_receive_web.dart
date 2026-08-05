// ignore_for_file: avoid_web_libraries_in_flutter
//
// FULFILL360 pass 3 (CHANGE #531): this file previously carried a full
// CLIENT-SIDE product-matching engine — parseUtterance / matchToBox /
// _matchScore (weights 0.45/0.3/0.15/0.2/0.1) / _levenshtein, plus hardcoded
// confidence thresholds (0.35, 0.12, 0.6, 0.8), number-word tables and
// unit/filler/command dictionaries. Every one of those symbols had ZERO
// references across lib/, test/ and scripts/ (the live continuous-voice path
// resolves products server-side and reads get_voice_clip_mentions, which
// already returns status_label / status_tone / status_colors / is_complete).
// ~380 lines deleted so nobody revives a client-side matcher.
//
// Only the TTS echo survives — audio output, explicitly permitted.

import 'dart:js_interop';

/// Speak a short string via SpeechSynthesis (optional TTS echo).
/// Exposed by web/index.html.
@JS('mediboVoiceSpeak')
external void _jsVoiceSpeak(JSString text);

void speakText(String text) {
  try { _jsVoiceSpeak(text.toJS); } catch (_) {}
}
