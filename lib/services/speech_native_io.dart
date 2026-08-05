// REAL Android implementation of the live Speech-to-Text stream + PCM mic.
// Compiled only when dart.library.io is present (Android/desktop) — never on web.
//
// Streams raw 16-bit little-endian PCM (record's stream API) straight into a
// Google Speech v2 StreamingRecognize gRPC call, authenticated with the
// short-lived bearer token minted by the voice-token edge function. No clips, no
// upload, no file.
import 'dart:async';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:record/record.dart';
import 'package:google_speech/generated/google/cloud/speech/v2/cloud_speech.pb.dart'
    as v2;
import 'package:google_speech/generated/google/cloud/speech/v2/cloud_speech.pbgrpc.dart'
    as v2g;
import 'package:google_speech/generated/google/protobuf/duration.pb.dart'
    as pbd;

import 'voice_live_types.dart';

/// Speech's per-message audio-bytes cap is 15 KB; keep frames well under it so a
/// single request (audio + framing) stays under ~25 KB.
const int _kMaxAudioChunk = 8000; // bytes, even (16-bit aligned)

MicSource createNativeMic() => _RecordMic();

Future<SpeechStream> openNativeSpeechStream(VoiceToken token,
    {bool fallback = false}) async {
  final endpoint = fallback ? token.fallback.endpoint : token.endpoint;
  final recognizer = fallback ? token.fallback.recognizer : token.recognizer;
  final model = fallback ? token.fallback.model : token.model;

  final channel = ClientChannel(
    endpoint,
    port: 443,
    options: const ChannelOptions(credentials: ChannelCredentials.secure()),
  );
  final client = v2g.SpeechClient(channel);

  final phrases = token.phrases
      .map((p) => v2.PhraseSet_Phrase(
            value: (p['value'] ?? '').toString(),
            boost: ((p['boost'] as num?) ?? 0).toDouble(),
          ))
      .where((p) => p.value.isNotEmpty)
      .toList();

  // The mic emits raw PCM16, so we declare LINEAR16 at the token's sample_rate to
  // match the actual bytes on the wire. (The token's `encoding` — WEBM_OPUS —
  // describes the web MediaRecorder clip path, which does not apply to Android's
  // raw-PCM stream.)
  final config = v2.RecognitionConfig(
    model: model,
    languageCodes: [token.languageCode],
    features: v2.RecognitionFeatures(enableWordTimeOffsets: true),
    explicitDecodingConfig: v2.ExplicitDecodingConfig(
      encoding: v2.ExplicitDecodingConfig_AudioEncoding.LINEAR16,
      sampleRateHertz: token.sampleRate,
      audioChannelCount: 1,
    ),
    adaptation: phrases.isEmpty
        ? null
        : v2.SpeechAdaptation(phraseSets: [
            v2.SpeechAdaptation_AdaptationPhraseSet(
              inlinePhraseSet: v2.PhraseSet(phrases: phrases),
            ),
          ]),
  );

  final streamingConfig = v2.StreamingRecognitionConfig(
    config: config,
    streamingFeatures: v2.StreamingRecognitionFeatures(interimResults: true),
  );

  final stream = _GrpcSpeechStream(channel, client);
  await stream._open(recognizer, streamingConfig, token.accessToken);
  return stream;
}

class _GrpcSpeechStream implements SpeechStream {
  final ClientChannel _channel;
  final v2g.SpeechClient _client;
  final StreamController<v2.StreamingRecognizeRequest> _requests =
      StreamController<v2.StreamingRecognizeRequest>();
  final StreamController<SpeechEvent> _events =
      StreamController<SpeechEvent>.broadcast();
  StreamSubscription<v2.StreamingRecognizeResponse>? _respSub;
  bool _closed = false;

  _GrpcSpeechStream(this._channel, this._client);

  @override
  Stream<SpeechEvent> get events => _events.stream;

  Future<void> _open(
    String recognizer,
    v2.StreamingRecognitionConfig streamingConfig,
    String accessToken,
  ) async {
    // First message: recognizer + streaming config, NO audio.
    _requests.add(v2.StreamingRecognizeRequest(
      recognizer: recognizer,
      streamingConfig: streamingConfig,
    ));

    final responses = _client.streamingRecognize(
      _requests.stream,
      options: CallOptions(metadata: {'authorization': 'Bearer $accessToken'}),
    );

    _respSub = responses.listen(
      (resp) {
        for (final r in resp.results) {
          if (r.alternatives.isEmpty) continue;
          final alt = r.alternatives.first;
          final words = r.isFinal
              ? alt.words
                  .map((wi) =>
                      SpeechWord(wi.word, _sec(wi.startOffset), _sec(wi.endOffset)))
                  .toList()
              : const <SpeechWord>[];
          if (!_events.isClosed) {
            _events.add(SpeechEvent(
              isFinal: r.isFinal,
              transcript: alt.transcript,
              words: words,
            ));
          }
        }
      },
      onError: (Object e, StackTrace st) {
        if (!_events.isClosed) _events.addError(_mapError(e), st);
      },
      onDone: () {
        if (!_events.isClosed) _events.close();
      },
      cancelOnError: false,
    );
  }

  static double _sec(pbd.Duration d) => d.seconds.toInt() + d.nanos / 1e9;

  static Object _mapError(Object e) {
    if (e is GrpcError) {
      return SpeechStreamException(
        e.message ?? 'stream error (${e.code})',
        invalidArgument: e.code == StatusCode.invalidArgument,
        permissionDenied: e.code == StatusCode.permissionDenied ||
            e.code == StatusCode.unauthenticated,
      );
    }
    return SpeechStreamException(e.toString());
  }

  @override
  void addAudio(List<int> frame) {
    if (_closed || _requests.isClosed || frame.isEmpty) return;
    // Re-chunk to stay under Speech's per-message audio cap; keep even (16-bit)
    // boundaries.
    if (frame.length <= _kMaxAudioChunk) {
      _requests.add(v2.StreamingRecognizeRequest(audio: frame));
      return;
    }
    var i = 0;
    while (i < frame.length) {
      final end = (i + _kMaxAudioChunk) > frame.length
          ? frame.length
          : i + _kMaxAudioChunk;
      _requests.add(v2.StreamingRecognizeRequest(
          audio: frame.sublist(i, end)));
      i = end;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      if (!_requests.isClosed) await _requests.close();
    } catch (_) {}
    try {
      await _respSub?.cancel();
    } catch (_) {}
    try {
      await _channel.shutdown();
    } catch (_) {}
    try {
      if (!_events.isClosed) await _events.close();
    } catch (_) {}
  }
}

class _RecordMic implements MicSource {
  final AudioRecorder _rec = AudioRecorder();

  @override
  Future<bool> hasPermission() => _rec.hasPermission();

  @override
  Future<Stream<Uint8List>> start({required int sampleRate}) async {
    // hasPermission() triggers the runtime RECORD_AUDIO prompt on first use.
    if (!await _rec.hasPermission()) throw const MicDeniedException();
    return _rec.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
    ));
  }

  @override
  Future<void> stop() async {
    try {
      await _rec.stop();
    } catch (_) {}
    try {
      await _rec.dispose();
    } catch (_) {}
  }
}
