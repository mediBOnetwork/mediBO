// Review audio for LIVE voice counting — the copy that made "why can't I listen
// to them" answerable. The live path streams PCM straight to Speech, so unless
// those same frames are teed, saved, and bound to the mentions, the review screen
// has nothing to play.
//
// Contract asserted here:
//  - The WAV header describes the bytes it actually wraps (rate, size, mono, 16-bit).
//  - Decimation to the backend's rate is exact-factor and never splits a sample
//    across frames; actualRate reports the truth rather than the wish.
//  - The bucket and the object KEY come from voice_live_clip_target — never
//    composed in Dart. ok:false surfaces the backend's own message.
//  - Windows tile the session with no gap: window N ends where N+1 starts.
//  - Attach reports the same bounds that were uploaded, so the backend can bind a
//    mention by its word offset.
//  - An upload failure never costs a count and shows the backend's failed_label
//    ONCE, not per window.
//  - No review_audio block (or an unusable one) = no recording, no RPCs at all.
//  - Cancel throws the audio away; Stop uploads it BEFORE committing, because
//    commit is what binds clips to mentions.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/voice_live_service.dart';
import 'package:pharma_b2b/services/voice_review_recorder.dart';

// ── fakes ────────────────────────────────────────────────────────────────────
class _FakeStream implements SpeechStream {
  final _c = StreamController<SpeechEvent>.broadcast();
  final List<List<int>> audio = [];
  bool closed = false;
  @override
  Stream<SpeechEvent> get events => _c.stream;
  @override
  void addAudio(List<int> f) => audio.add(f);
  @override
  Future<void> close() async => closed = true;
  void emitFinal(List<SpeechWord> w) =>
      _c.add(SpeechEvent(isFinal: true, transcript: '', words: w));
}

class _FakeMic implements MicSource {
  final _c = StreamController<Uint8List>.broadcast();
  bool stopped = false;
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<Stream<Uint8List>> start({required int sampleRate}) async => _c.stream;
  @override
  Future<void> stop() async => stopped = true;
  void push(Uint8List f) => _c.add(f);
}

class _Rpc {
  final List<MapEntry<String, Map<String, dynamic>>> calls = [];
  final Map<String, dynamic> Function(String fn, Map<String, dynamic> p) resp;
  _Rpc(this.resp);
  Future<dynamic> call(String fn, Map<String, dynamic> p) {
    calls.add(MapEntry(fn, Map<String, dynamic>.from(p)));
    return Future.value(resp(fn, p));
  }

  List<Map<String, dynamic>> named(String fn) =>
      calls.where((e) => e.key == fn).map((e) => e.value).toList();
}

class _Uploads {
  final List<Map<String, dynamic>> puts = [];
  bool fail = false;
  Future<void> call(
      String bucket, String path, Uint8List bytes, String contentType) async {
    if (fail) throw StateError('offline');
    puts.add({
      'bucket': bucket,
      'path': path,
      'bytes': bytes,
      'content_type': contentType
    });
  }
}

Map<String, dynamic> _token({Map<String, dynamic>? review}) => {
      'ok': true,
      'access_token': 'tok',
      'endpoint': 'speech.googleapis.com',
      'recognizer': 'projects/p/locations/global/recognizers/_',
      'location': 'global',
      'language_code': 'en-IN',
      'model': 'long',
      'encoding': 'LINEAR16',
      'sample_rate': 48000,
      'phrases': const [],
      'reconnect_after_sec': 270,
      'ready_label': 'Listening',
      'review_audio': ?review,
      'fallback': const {},
    };

const _reviewOn = {
  'enabled': true,
  'bucket': 'voice-clips',
  'sample_rate': 16000,
  'window_sec': 30,
  'failed_label': 'Counted, but the audio for review did not upload',
};

Map<String, dynamic> _rpcResp(String fn, Map<String, dynamic> p) {
  switch (fn) {
    case 'voice_live_clip_target':
      return {
        'ok': true,
        'bucket': 'voice-clips',
        'path': 'live/sess-1/${p['p_seq']}.wav',
        'content_type': 'audio/wav',
        'message': '',
      };
    case 'voice_live_attach_clip':
      return {'ok': true, 'seq': p['p_seq'], 'bound': 1};
    default:
      return {
        'ok': true,
        'totals': const [
          {'product_id': 1, 'name': 'Doberol Capsule', 'qty': 5}
        ],
        'hint': '',
        'message': '1 count saved',
      };
  }
}

/// A frame of [samples] 16-bit LE samples whose values ramp from [from].
Uint8List _pcm(int samples, {int from = 0}) {
  final b = Uint8List(samples * 2);
  final bd = ByteData.view(b.buffer);
  for (var i = 0; i < samples; i++) {
    bd.setInt16(i * 2, (from + i) & 0x7fff, Endian.little);
  }
  return b;
}

void main() {
  Future<void> settle([int ms = 40]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  // ── WAV container ─────────────────────────────────────────────────────────
  test('WAV header describes exactly the bytes it wraps', () {
    final pcm = _pcm(160);
    final wav = buildWavPcm16Mono(pcm, 16000);
    final bd = ByteData.view(wav.buffer);

    expect(wav.length, 44 + pcm.length);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    expect(bd.getUint32(4, Endian.little), 36 + pcm.length);
    expect(bd.getUint16(20, Endian.little), 1, reason: 'PCM');
    expect(bd.getUint16(22, Endian.little), 1, reason: 'mono');
    expect(bd.getUint32(24, Endian.little), 16000);
    expect(bd.getUint32(28, Endian.little), 16000 * 2, reason: 'byte rate');
    expect(bd.getUint16(32, Endian.little), 2, reason: 'block align');
    expect(bd.getUint16(34, Endian.little), 16, reason: 'bits per sample');
    expect(bd.getUint32(40, Endian.little), pcm.length);
    // The payload must survive byte-for-byte — a review clip that is not what was
    // said is worse than no clip.
    expect(wav.sublist(44), pcm);
  });

  // ── decimation ────────────────────────────────────────────────────────────
  test('48000 -> 16000 is an exact 3:1 drop and reports its real rate', () {
    final d = PcmDecimator(48000, 16000);
    expect(d.factor, 3);
    expect(d.actualRate, 16000);

    final out = d.add(_pcm(9)); // samples 0..8 -> keeps 0, 3, 6
    final bd = ByteData.view(out.buffer);
    expect(out.length, 3 * 2);
    expect(
        [bd.getInt16(0, Endian.little), bd.getInt16(2, Endian.little),
            bd.getInt16(4, Endian.little)],
        [0, 3, 6]);
  });

  test('phase continues across frames — the drop pattern never restarts', () {
    final d = PcmDecimator(48000, 16000);
    d.add(_pcm(2)); // samples 0,1 -> keeps 0, phase now 2
    final out = d.add(_pcm(2, from: 2)); // samples 2,3 -> keeps 3
    final bd = ByteData.view(out.buffer);
    expect(out.length, 2);
    expect(bd.getInt16(0, Endian.little), 3);
  });

  test('an odd trailing byte is carried, never splitting a sample', () {
    final d = PcmDecimator(16000, 16000); // factor 1, passthrough
    final a = d.add(Uint8List.fromList([1, 2, 3])); // 3 bytes -> 2 out, 1 held
    expect(a, [1, 2]);
    final b = d.add(Uint8List.fromList([4])); // carried 3 + 4 = one sample
    expect(b, [3, 4]);
  });

  test('a rate the source cannot divide is not faked', () {
    final d = PcmDecimator(44100, 16000);
    expect(d.factor, 3);
    expect(d.actualRate, 14700,
        reason: 'the header must state what the bytes are, not what we wanted');
  });

  // ── recorder ──────────────────────────────────────────────────────────────
  test('window bounds tile the session and the KEY comes from the backend',
      () async {
    final rpc = _Rpc(_rpcResp);
    final up = _Uploads();
    var now = 0.0;
    final rec = VoiceReviewRecorder(
      cfg: VoiceReviewAudio.fromMap(_reviewOn),
      sourceSampleRate: 48000,
      nowSec: () => now,
      resolveTarget: (seq) async =>
          Map<String, dynamic>.from(await rpc.call('voice_live_clip_target', {
        'p_session_key': 'sess-1',
        'p_seq': seq,
        'p_stage': 'shop',
      }) as Map),
      upload: up.call,
      attach: (seq, path, from, to) async => rpc.call('voice_live_attach_clip', {
        'p_session_key': 'sess-1',
        'p_seq': seq,
        'p_clip_path': path,
        'p_t_start': from,
        'p_t_end': to,
        'p_stage': 'shop',
      }),
    );

    rec.addFrame(_pcm(48000)); // 1s of audio, clock still at 0
    now = 31.0; // past window_sec — this frame closes window 0
    rec.addFrame(_pcm(48000));
    await settle();
    now = 40.0;
    rec.addFrame(_pcm(48000)); // starts window 1
    now = 45.0;
    await rec.stop();
    await settle();

    expect(up.puts.length, 2, reason: 'one upload per window');
    expect(up.puts[0]['bucket'], 'voice-clips');
    expect(up.puts[0]['path'], 'live/sess-1/0.wav',
        reason: 'the object key is the backend\'s, never composed in Dart');
    expect(up.puts[1]['path'], 'live/sess-1/1.wav');
    expect(up.puts[0]['content_type'], 'audio/wav');

    final attaches = rpc.named('voice_live_attach_clip');
    expect(attaches.length, 2);
    expect(attaches[0]['p_t_start'], 0.0);
    expect(attaches[0]['p_t_end'], 31.0);
    // No gap: a mention at t=31 belongs to window 1, not to nothing.
    expect(attaches[1]['p_t_start'], 31.0);
    expect(attaches[1]['p_t_end'], 45.0);
    expect(attaches[0]['p_clip_path'], 'live/sess-1/0.wav');
  });

  test('the uploaded WAV states the decimated rate, not the mic rate', () async {
    final up = _Uploads();
    final rec = VoiceReviewRecorder(
      cfg: VoiceReviewAudio.fromMap(_reviewOn),
      sourceSampleRate: 48000,
      nowSec: () => 0.0,
      resolveTarget: (seq) async => {
        'ok': true,
        'bucket': 'voice-clips',
        'path': 'live/s/$seq.wav',
        'content_type': 'audio/wav',
      },
      upload: up.call,
      attach: (a, b, c, d) async {},
    );
    rec.addFrame(_pcm(30));
    await rec.stop();
    await settle();

    final wav = up.puts.single['bytes'] as Uint8List;
    expect(ByteData.view(wav.buffer).getUint32(24, Endian.little), 16000);
    expect(wav.length, 44 + 10 * 2, reason: '30 samples decimated 3:1');
  });

  test('a failed upload keeps the count and shows the backend label ONCE',
      () async {
    final up = _Uploads()..fail = true;
    final problems = <String>[];
    var now = 0.0;
    final rec = VoiceReviewRecorder(
      cfg: VoiceReviewAudio.fromMap(_reviewOn),
      sourceSampleRate: 48000,
      nowSec: () => now,
      resolveTarget: (seq) async => {
        'ok': true,
        'bucket': 'voice-clips',
        'path': 'live/s/$seq.wav',
        'content_type': 'audio/wav',
      },
      upload: up.call,
      attach: (a, b, c, d) async {},
      onProblem: problems.add,
    );

    rec.addFrame(_pcm(48000));
    now = 31.0;
    rec.addFrame(_pcm(48000));
    await settle();
    now = 62.0;
    rec.addFrame(_pcm(48000));
    await settle();
    await rec.stop();
    await settle();

    expect(problems, ['Counted, but the audio for review did not upload'],
        reason: 'one warning per session, not one per window');
  });

  test('ok:false surfaces the backend message and uploads nothing', () async {
    final up = _Uploads();
    final problems = <String>[];
    final rec = VoiceReviewRecorder(
      cfg: VoiceReviewAudio.fromMap(_reviewOn),
      sourceSampleRate: 48000,
      nowSec: () => 0.0,
      resolveTarget: (seq) async =>
          {'ok': false, 'message': 'Session is not yours'},
      upload: up.call,
      attach: (a, b, c, d) async {},
      onProblem: problems.add,
    );
    rec.addFrame(_pcm(30));
    await rec.stop();
    await settle();

    expect(up.puts, isEmpty);
    expect(problems, ['Session is not yours']);
  });

  test('an unusable config records nothing at all', () async {
    final up = _Uploads();
    for (final cfg in [
      const <String, dynamic>{},
      {..._reviewOn, 'enabled': false},
      {..._reviewOn, 'bucket': ''},
      {..._reviewOn, 'sample_rate': 0},
      {..._reviewOn, 'window_sec': 0},
    ]) {
      final rec = VoiceReviewRecorder(
        cfg: VoiceReviewAudio.fromMap(Map<String, dynamic>.from(cfg)),
        sourceSampleRate: 48000,
        nowSec: () => 999.0,
        resolveTarget: (seq) async => throw StateError('must not be asked'),
        upload: up.call,
        attach: (a, b, c, d) async => throw StateError('must not attach'),
      );
      expect(rec.active, false);
      rec.addFrame(_pcm(48000));
      await rec.stop();
    }
    await settle();
    expect(up.puts, isEmpty);
  });

  // ── controller integration ────────────────────────────────────────────────
  test('Stop uploads and attaches BEFORE committing, so the commit binds it',
      () async {
    final order = <String>[];
    final up = _Uploads();
    final rpc = _Rpc((fn, p) {
      order.add(fn);
      return _rpcResp(fn, p);
    });
    final mic = _FakeMic();
    final s = _FakeStream();
    final c = VoiceLiveController(
      backend: SupplierVoiceBackend(
        supplier: 'UMA MEDICAL STORES',
        stage: 'shop',
        rpc: rpc.call,
        fn: (f, b) async => _token(review: _reviewOn),
        storage: up.call,
      ),
      sessionKey: 'sess-1',
      openStream: (t, {bool fallback = false}) async => s,
      mic: mic,
      debounce: const Duration(milliseconds: 20),
    );

    expect(await c.start(), true);
    mic.push(_pcm(4800));
    s.emitFinal([const SpeechWord('doberol', 0.0, 0.4)]);
    await settle();
    await c.stop();
    await settle(80);

    expect(up.puts.single['path'], 'live/sess-1/0.wav');
    final target = rpc.named('voice_live_clip_target').single;
    expect(target['p_session_key'], 'sess-1');
    expect(target['p_stage'], 'shop');
    expect(target['p_seq'], 0);

    final attachAt = order.indexOf('voice_live_attach_clip');
    final commitAt = order.lastIndexOf('voice_live_commit');
    expect(attachAt, greaterThanOrEqualTo(0));
    expect(attachAt, lessThan(commitAt),
        reason: 'voice_live_commit runs the bind — the clip must exist first');
  });

  test('the mic still feeds Speech while the review copy is being kept',
      () async {
    final up = _Uploads();
    final mic = _FakeMic();
    final s = _FakeStream();
    final c = VoiceLiveController(
      backend: SupplierVoiceBackend(
        supplier: 'Acme',
        stage: 'shop',
        rpc: _Rpc(_rpcResp).call,
        fn: (f, b) async => _token(review: _reviewOn),
        storage: up.call,
      ),
      sessionKey: 'sess-1',
      openStream: (t, {bool fallback = false}) async => s,
      mic: mic,
    );
    await c.start();
    mic.push(_pcm(100));
    await settle();
    expect(s.audio.length, 1, reason: 'counting must never lose a frame');
    await c.cancel();
  });

  test('a review-audio fault never stops the count', () async {
    final up = _Uploads()..fail = true;
    final errors = <String>[];
    final mic = _FakeMic();
    final s = _FakeStream();
    final rpc = _Rpc(_rpcResp);
    final c = VoiceLiveController(
      backend: SupplierVoiceBackend(
        supplier: 'Acme',
        stage: 'shop',
        rpc: rpc.call,
        fn: (f, b) async => _token(review: _reviewOn),
        storage: up.call,
      ),
      sessionKey: 'sess-1',
      openStream: (t, {bool fallback = false}) async => s,
      mic: mic,
      debounce: const Duration(milliseconds: 20),
      onError: errors.add,
    );
    await c.start();
    mic.push(_pcm(4800));
    s.emitFinal([const SpeechWord('doberol', 0.0, 0.4)]);
    await settle();
    final res = await c.stop();
    await settle(80);

    expect(res?['totals'], isNotEmpty, reason: 'the count survived');
    expect(errors, ['Counted, but the audio for review did not upload']);
  });

  test('Cancel throws the audio away instead of paying to store it', () async {
    final up = _Uploads();
    final mic = _FakeMic();
    final s = _FakeStream();
    final rpc = _Rpc(_rpcResp);
    final c = VoiceLiveController(
      backend: SupplierVoiceBackend(
        supplier: 'Acme',
        stage: 'shop',
        rpc: rpc.call,
        fn: (f, b) async => _token(review: _reviewOn),
        storage: up.call,
      ),
      sessionKey: 'sess-1',
      openStream: (t, {bool fallback = false}) async => s,
      mic: mic,
    );
    await c.start();
    mic.push(_pcm(4800));
    await settle();
    await c.cancel();
    await settle();

    expect(up.puts, isEmpty);
    expect(rpc.named('voice_live_attach_clip'), isEmpty);
  });

  test('no review_audio in the token = no recording, no clip RPCs', () async {
    final up = _Uploads();
    final rpc = _Rpc(_rpcResp);
    final mic = _FakeMic();
    final s = _FakeStream();
    final c = VoiceLiveController(
      backend: SupplierVoiceBackend(
        supplier: 'Acme',
        stage: 'shop',
        rpc: rpc.call,
        fn: (f, b) async => _token(),
        storage: up.call,
      ),
      sessionKey: 'sess-1',
      openStream: (t, {bool fallback = false}) async => s,
      mic: mic,
      debounce: const Duration(milliseconds: 20),
    );
    await c.start();
    mic.push(_pcm(48000));
    s.emitFinal([const SpeechWord('doberol', 0.0, 0.4)]);
    await settle();
    await c.stop();
    await settle(80);

    expect(up.puts, isEmpty);
    expect(rpc.named('voice_live_clip_target'), isEmpty);
    expect(rpc.named('voice_live_commit'), isNotEmpty,
        reason: 'counting is unaffected');
  });

  test('Pack sends its own stage so the backend binds pack mentions', () async {
    final up = _Uploads();
    final rpc = _Rpc((fn, p) => fn == 'voice_live_commit_pack'
        ? {'ok': true, 'totals': const [], 'hint': '', 'message': 'saved'}
        : _rpcResp(fn, p));
    final mic = _FakeMic();
    final s = _FakeStream();
    final c = VoiceLiveController(
      backend: PackVoiceBackend(
        orderId: 'ord-9',
        tokenSupplier: 'Acme',
        rpc: rpc.call,
        fn: (f, b) async => _token(review: _reviewOn),
        storage: up.call,
      ),
      sessionKey: 'sess-1',
      openStream: (t, {bool fallback = false}) async => s,
      mic: mic,
      debounce: const Duration(milliseconds: 20),
    );
    await c.start();
    mic.push(_pcm(4800));
    s.emitFinal([const SpeechWord('doberol', 0.0, 0.4)]);
    await settle();
    await c.stop();
    await settle(80);

    expect(rpc.named('voice_live_clip_target').single['p_stage'], 'pack');
    expect(rpc.named('voice_live_attach_clip').single['p_stage'], 'pack');
    expect(up.puts, isNotEmpty);
  });
}
