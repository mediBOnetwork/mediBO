// Web / non-io fallback. The live streaming path is Android-only (gated by
// Platform.isAndroid at every call site), so these are never invoked on web —
// they exist only so speech_native.dart resolves and the web build stays free of
// grpc / dart:io.
import 'voice_live_types.dart';

Future<SpeechStream> openNativeSpeechStream(VoiceToken token,
        {bool fallback = false}) =>
    throw UnsupportedError('Live Speech-to-Text streaming is Android-only');

MicSource createNativeMic() =>
    throw UnsupportedError('Live PCM microphone is Android-only');
