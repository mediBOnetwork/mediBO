// Platform-conditional TTS-echo glue: web uses dart:js_interop SpeechSynthesis,
// native is a no-op stub. Original filename kept so callers' imports are unchanged.
export 'voice_receive_stub.dart' if (dart.library.html) 'voice_receive_web.dart';
