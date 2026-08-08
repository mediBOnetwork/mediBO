// Realtime (Android) voice-counting types — platform-agnostic, no dart:io / grpc
// imports so this file compiles for web too (web never USES the live path, but the
// controller that references these types is imported by the shared fulfillment screen).
//
// THE APP RENDERS. IT NEVER DECIDES: every user-facing string here (ready_label,
// hint, message) originates from the backend token / RPC payloads. Nothing is
// authored in Dart.
import 'dart:typed_data';

/// One recognised word with its offsets on the CURRENT stream's clock (seconds).
class SpeechWord {
  final String word;
  final double startSec;
  final double endSec;
  const SpeechWord(this.word, this.startSec, this.endSec);
}

/// One recognition result surfaced by a [SpeechStream].
/// Interim results drive the on-screen caption only ([words] is empty and the
/// controller never forwards them to an RPC). Final results carry [words] with
/// time offsets and are the only ones accumulated.
class SpeechEvent {
  final bool isFinal;
  final String transcript;
  final List<SpeechWord> words;
  const SpeechEvent({
    required this.isFinal,
    required this.transcript,
    this.words = const [],
  });
}

/// Raised by a [SpeechStream] when the underlying gRPC stream fails.
/// [invalidArgument] → the controller retries ONCE on the token's fallback config.
/// [permissionDenied] → Speech-to-Text is not enabled (HTTP 403); surfaced, never
/// silent.
class SpeechStreamException implements Exception {
  final String message;
  final bool invalidArgument;
  final bool permissionDenied;
  SpeechStreamException(this.message,
      {this.invalidArgument = false, this.permissionDenied = false});
  @override
  String toString() => message;
}

/// A live bidirectional Speech-to-Text stream. The real implementation
/// (speech_native_io.dart) speaks gRPC to Google Speech v2; tests inject a fake.
abstract class SpeechStream {
  /// Recognition events (interim + final). Errors are surfaced as
  /// [SpeechStreamException] via this stream's error channel.
  Stream<SpeechEvent> get events;

  /// Push one PCM audio frame to the recogniser (implementation chunks to stay
  /// under Speech's per-message audio cap).
  void addAudio(List<int> frame);

  /// Half-close the request side and tear the stream down.
  Future<void> close();
}

/// Raised when the OS microphone permission is denied at start.
class MicDeniedException implements Exception {
  const MicDeniedException();
  @override
  String toString() => 'Microphone permission denied';
}

/// One render-ready view of the count, straight from a voice_live_* payload.
///
/// [authoritative] is true when it came from voice_live_commit(_pack) — the
/// numbers are then what the backend has actually PERSISTED, and that is the
/// number the screen must show. Preview snapshots carry the same shape but are
/// only a fast repaint while the operator is still speaking.
class VoiceLiveSnapshot {
  final List<Map<String, dynamic>> totals; // [{product_id,name,qty,bag_no}]
  final List<Map<String, dynamic>> overCounted; // backend-clamped rows
  final List<Map<String, dynamic>> needsBagReview; // never silently dropped

  /// Items the backend heard by name but with no number spoken after them.
  /// Surfaced so a dropped count is visible — it used to vanish in silence.
  final List<Map<String, dynamic>> unmatched;

  final String hint;

  /// Render-ready bag label from the backend, e.g. "Bag 3". Empty where the
  /// stage has no bag condition (shop, pack), so no chip is drawn there. The app
  /// never composes this text or decides which stages have bags.
  final String activeBagLabel;

  final bool authoritative;

  const VoiceLiveSnapshot({
    this.totals = const [],
    this.overCounted = const [],
    this.needsBagReview = const [],
    this.unmatched = const [],
    this.hint = '',
    this.activeBagLabel = '',
    this.authoritative = false,
  });

  /// Reads the shape both the preview and the commit RPCs return. Absent keys
  /// become empty — never a Dart-invented value.
  factory VoiceLiveSnapshot.fromMap(Map<String, dynamic> m,
      {required bool authoritative}) {
    List<Map<String, dynamic>> rows(String k) => ((m[k] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    return VoiceLiveSnapshot(
      totals: rows('totals'),
      overCounted: rows('over_counted'),
      needsBagReview: rows('needs_bag_review'),
      unmatched: rows('unmatched'),
      hint: (m['hint'] ?? '').toString(),
      activeBagLabel: (m['active_bag_label'] ?? '').toString(),
      authoritative: authoritative,
    );
  }
}

/// Continuous raw-PCM microphone source (record's stream API on Android).
abstract class MicSource {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start({required int sampleRate});
  Future<void> stop();
}

/// The voice-token edge-function payload. Memory-only — never persisted or logged.
class VoiceToken {
  final String accessToken;
  final String endpoint; // host, e.g. speech.googleapis.com
  final String recognizer; // full resource path
  final String location;
  final String languageCode;
  final String model;
  /// Wire format the backend tells us to send, e.g. LINEAR16. Decided by
  /// voice_stream_open — never chosen here.
  final String encoding;
  final int sampleRate;
  final List<Map<String, dynamic>> phrases; // [{value, boost}]
  final int reconnectAfterSec;
  final String readyLabel;
  final VoiceTokenFallback fallback;

  const VoiceToken({
    required this.accessToken,
    required this.endpoint,
    required this.recognizer,
    required this.location,
    required this.languageCode,
    required this.model,
    required this.encoding,
    required this.sampleRate,
    required this.phrases,
    required this.reconnectAfterSec,
    required this.readyLabel,
    required this.fallback,
  });

  factory VoiceToken.fromMap(Map<String, dynamic> m) {
    final fb = (m['fallback'] is Map)
        ? Map<String, dynamic>.from(m['fallback'] as Map)
        : const <String, dynamic>{};
    return VoiceToken(
      accessToken: (m['access_token'] ?? '').toString(),
      endpoint: (m['endpoint'] ?? '').toString(),
      recognizer: (m['recognizer'] ?? '').toString(),
      location: (m['location'] ?? '').toString(),
      languageCode: (m['language_code'] ?? 'en-IN').toString(),
      model: (m['model'] ?? 'long').toString(),
      // No Dart fallback for these two: the backend owns the wire format, and a
      // guessed value would mean sending bytes that do not match what we declare
      // to Speech. Absent → empty/0, and the stream opener refuses to start with
      // the backend's own message rather than counting garbage.
      encoding: (m['encoding'] ?? '').toString(),
      sampleRate: (m['sample_rate'] as num?)?.toInt() ?? 0,
      phrases: ((m['phrases'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
      reconnectAfterSec: (m['reconnect_after_sec'] as num?)?.toInt() ?? 270,
      readyLabel: (m['ready_label'] ?? '').toString(),
      fallback: VoiceTokenFallback(
        location: (fb['location'] ?? 'us-central1').toString(),
        endpoint:
            (fb['endpoint'] ?? 'us-central1-speech.googleapis.com').toString(),
        model: (fb['model'] ?? 'chirp_2').toString(),
        recognizer: (fb['recognizer'] ?? '').toString(),
      ),
    );
  }
}

class VoiceTokenFallback {
  final String location;
  final String endpoint;
  final String model;
  final String recognizer;
  const VoiceTokenFallback({
    required this.location,
    required this.endpoint,
    required this.model,
    required this.recognizer,
  });
}

/// Opens a live [SpeechStream] for [token]. When [fallback] is true the caller
/// wants the token's fallback endpoint/model/recognizer (retry after
/// INVALID_ARGUMENT).
typedef SpeechStreamOpener = Future<SpeechStream> Function(VoiceToken token,
    {bool fallback});
