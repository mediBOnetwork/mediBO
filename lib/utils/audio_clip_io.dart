// Platform-conditional single-clip audio player used by the fulfillment screen
// for TTS playback and voice-clip replay.
//   Web    → bare html.AudioElement (the proven path — cross-origin signed URLs
//            actually emit sound, unlike Web-Audio-routed players).
//   Native → package:audioplayers (already a dependency).
// Same ClipPlayer API on both. play() accepts a URL or a data: URL.
export 'audio_clip_io_stub.dart' if (dart.library.html) 'audio_clip_io_web.dart';
