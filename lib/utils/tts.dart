// Platform-conditional TTS glue: web uses dart:js_interop SpeechSynthesis,
// native is a no-op stub. Original filename kept so callers' imports are unchanged.
export 'tts_stub.dart' if (dart.library.html) 'tts_web.dart';
