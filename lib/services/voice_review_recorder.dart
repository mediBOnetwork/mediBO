// Keeps a reviewable copy of what the operator actually said while live counting.
//
// WHY THIS EXISTS: the live path streams raw PCM straight into Speech-to-Text, so
// that stream is the ONLY copy of the audio. Live mentions were therefore saved
// with no clip_path and the review screen had nothing to play — "why can't I listen
// to them". This tees the same frames, wraps each window as a WAV and hands it to
// the uploader.
//
// THE APP RENDERS. IT NEVER DECIDES: the rate, the window length, the bucket and
// the failure wording all come from voice_stream_open via VoiceReviewAudio. The
// storage KEY comes from voice_live_clip_target. Nothing here is chosen locally
// except how to pack bytes into a WAV container, which is a wire format, not a
// decision about the business.
import 'dart:async';
import 'dart:typed_data';

import 'voice_live_types.dart';

/// Asks the backend where this window's bytes should go.
/// Returns `{ok, bucket, path, content_type, message}`.
typedef ClipTargetResolver = Future<Map<String, dynamic>> Function(int seq);

/// Puts [bytes] in [bucket] at [path]. Throws on failure.
typedef ClipUploader = Future<void> Function(
    String bucket, String path, Uint8List bytes, String contentType);

/// Tells the backend the window is uploaded, so it can bind it to the mentions
/// whose timestamps fall inside [tStart, tEnd).
typedef ClipAttacher = Future<void> Function(
    int seq, String path, double tStart, double tEnd);

/// Builds a 16-bit mono PCM WAV file. [sampleRate] must be the rate of [samples]
/// as actually produced, not the rate we wish they had.
Uint8List buildWavPcm16Mono(Uint8List pcm, int sampleRate) {
  const headerLen = 44;
  final out = Uint8List(headerLen + pcm.length);
  final bd = ByteData.view(out.buffer);
  final byteRate = sampleRate * 2; // mono, 2 bytes per sample

  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      out[at + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  bd.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little); // fmt chunk size
  bd.setUint16(20, 1, Endian.little); // PCM
  bd.setUint16(22, 1, Endian.little); // mono
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, byteRate, Endian.little);
  bd.setUint16(32, 2, Endian.little); // block align
  bd.setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  bd.setUint32(40, pcm.length, Endian.little);
  out.setRange(headerLen, headerLen + pcm.length, pcm);
  return out;
}

/// Drops every Nth 16-bit sample to reach the backend's review rate. 48000 -> 16000
/// is an exact 3:1 drop, which is why the backend asks for 16000. A non-integer
/// ratio is NOT faked: the factor is rounded and [actualRate] reports what the
/// bytes really are, so the WAV header never lies about its own contents.
class PcmDecimator {
  final int factor;
  final int actualRate;

  PcmDecimator._(this.factor, this.actualRate);

  factory PcmDecimator(int sourceRate, int targetRate) {
    if (sourceRate <= 0 || targetRate <= 0 || targetRate >= sourceRate) {
      return PcmDecimator._(1, sourceRate);
    }
    final f = (sourceRate / targetRate).round().clamp(1, 64);
    return PcmDecimator._(f, (sourceRate / f).round());
  }

  int _phase = 0;

  /// [frame] is little-endian PCM16. Odd trailing bytes are carried to the next
  /// frame so a sample is never split across windows.
  Uint8List _carry = Uint8List(0);

  Uint8List add(Uint8List frame) {
    final src = _carry.isEmpty
        ? frame
        : (Uint8List(_carry.length + frame.length)
          ..setRange(0, _carry.length, _carry)
          ..setRange(_carry.length, _carry.length + frame.length, frame));
    final whole = src.length - (src.length % 2);
    _carry = whole == src.length
        ? Uint8List(0)
        : Uint8List.sublistView(src, whole).sublist(0);

    if (factor == 1) return Uint8List.sublistView(src, 0, whole).sublist(0);

    final kept = BytesBuilder(copy: false);
    for (var i = 0; i < whole; i += 2) {
      if (_phase == 0) {
        kept.add(<int>[src[i], src[i + 1]]);
      }
      _phase = (_phase + 1) % factor;
    }
    return kept.toBytes();
  }
}

/// Accumulates the live mic stream and uploads it one window at a time.
///
/// Failure is never fatal to counting: an upload that does not land leaves the
/// count intact and surfaces the backend's own [VoiceReviewAudio.failedLabel]
/// once, rather than aborting the session.
class VoiceReviewRecorder {
  final VoiceReviewAudio cfg;
  final int sourceSampleRate;
  final ClipTargetResolver resolveTarget;
  final ClipUploader upload;
  final ClipAttacher attach;
  final void Function(String message)? onProblem;

  /// Session-clock seconds, supplied by the controller so a window's bounds sit on
  /// the SAME clock as the word offsets the backend matches against.
  final double Function() nowSec;

  VoiceReviewRecorder({
    required this.cfg,
    required this.sourceSampleRate,
    required this.resolveTarget,
    required this.upload,
    required this.attach,
    required this.nowSec,
    this.onProblem,
  }) : _dec = PcmDecimator(sourceSampleRate, cfg.sampleRate);

  final PcmDecimator _dec;
  final BytesBuilder _buf = BytesBuilder(copy: false);
  int _seq = 0;
  double _windowStart = 0;
  bool _problemShown = false;
  bool _closed = false;

  /// Windows still in flight, so [stop] can wait for them.
  final List<Future<void>> _inFlight = [];

  bool get active => cfg.usable && !_closed;

  /// Feed one raw PCM16 frame from the mic. Never throws.
  void addFrame(Uint8List frame) {
    if (!active || frame.isEmpty) return;
    try {
      _buf.add(_dec.add(frame));
      final at = nowSec();
      if (at - _windowStart >= cfg.windowSec) _flush(at);
    } catch (e) {
      _reportOnce(cfg.failedLabel);
    }
  }

  /// Uploads whatever is buffered and stops accepting frames.
  Future<void> stop() async {
    if (_closed) return;
    final at = nowSec();
    if (_buf.length > 0) _flush(at);
    _closed = true;
    if (_inFlight.isEmpty) return;
    await Future.wait(_inFlight.map((f) => f.catchError((_) {})));
  }

  void _flush(double at) {
    final pcm = _buf.takeBytes();
    if (pcm.isEmpty) return;
    final seq = _seq++;
    final from = _windowStart;
    // The next window starts where this one ended, so the bounds tile the session
    // with no gap a mention could fall into.
    _windowStart = at;

    final job = _sendWindow(seq, pcm, from, at);
    _inFlight.add(job);
    // Keep the list from growing without bound on a long session.
    job.whenComplete(() => _inFlight.remove(job));
  }

  Future<void> _sendWindow(
      int seq, Uint8List pcm, double from, double to) async {
    try {
      final target = await resolveTarget(seq);
      if (target['ok'] != true) {
        _reportOnce((target['message'] ?? cfg.failedLabel).toString());
        return;
      }
      final bucket = (target['bucket'] ?? '').toString();
      final path = (target['path'] ?? '').toString();
      if (bucket.isEmpty || path.isEmpty) {
        _reportOnce(cfg.failedLabel);
        return;
      }
      await upload(
        bucket,
        path,
        buildWavPcm16Mono(pcm, _dec.actualRate),
        (target['content_type'] ?? 'audio/wav').toString(),
      );
      await attach(seq, path, from, to);
    } catch (e) {
      _reportOnce(cfg.failedLabel);
    }
  }

  void _reportOnce(String message) {
    if (_problemShown || message.isEmpty) return;
    _problemShown = true;
    onProblem?.call(message);
  }
}
