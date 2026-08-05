// Native (non-web) fallback for the web TTS-echo helper.
// Public API matches voice_receive_web.dart: only speakText is public.

/// Native no-op: no browser SpeechSynthesis to echo through.
void speakText(String text) {}
