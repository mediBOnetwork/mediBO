// Realtime (Android) voice-counting controller — fully mocked, no network, no
// home_shell import. Drives VoiceLiveController with a fake Speech stream, a fake
// mic and fake token/preview/commit callers, and asserts the spec contract:
//  - Start calls voice-token and opens a stream with the returned recognizer,
//    model and phrases.
//  - Final words accumulate with 1-based indexes and increasing seconds; interim
//    words are never sent.
//  - Preview is debounced to one call per burst.
//  - Shop AND Warehouse call voice_live_preview with p_supplier; Pack calls
//    voice_live_preview_pack with p_order_id.
//  - Totals render from the response.
//  - Reaching reconnect_after_sec opens a new stream and keeps the word list.
//  - Stop commits once via the correct RPC and shows message; a second Stop does
//    not commit again.
//  - An INVALID_ARGUMENT stream error retries once on fallback.
//  - A token error shows message and opens no stream.
//  - On web the old clip path is used and voice-token is never called.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/voice_live_service.dart';
import 'package:pharma_b2b/services/voice_live_types.dart';

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
  Future<void> close() async {
    closed = true;
  }

  void emitFinal(List<SpeechWord> w, {String transcript = ''}) =>
      _c.add(SpeechEvent(isFinal: true, transcript: transcript, words: w));
  void emitInterim(String t) =>
      _c.add(SpeechEvent(isFinal: false, transcript: t));
  void fail(Object e) => _c.addError(e);
}

class _FakeMic implements MicSource {
  final _c = StreamController<Uint8List>.broadcast();
  bool started = false;
  bool stopped = false;
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<Stream<Uint8List>> start({required int sampleRate}) async {
    started = true;
    return _c.stream;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

class _Opener {
  final List<VoiceToken> tokens = [];
  final List<bool> fallbacks = [];
  final List<_FakeStream> streams;
  int _i = 0;
  _Opener(this.streams);
  Future<SpeechStream> call(VoiceToken t, {bool fallback = false}) async {
    tokens.add(t);
    fallbacks.add(fallback);
    final s = streams[_i < streams.length ? _i : streams.length - 1];
    _i++;
    return s;
  }
}

class _Rpc {
  final List<MapEntry<String, Map<String, dynamic>>> calls = [];
  final Map<String, dynamic> Function(String fn, Map<String, dynamic> p)
      responder;
  _Rpc(this.responder);
  Future<dynamic> call(String fn, Map<String, dynamic> p) {
    calls.add(MapEntry(fn, Map<String, dynamic>.from(p)));
    return Future.value(responder(fn, p));
  }

  List<MapEntry<String, Map<String, dynamic>>> named(String fn) =>
      calls.where((e) => e.key == fn).toList();
}

class _Fn {
  final List<MapEntry<String, Map<String, dynamic>>> calls = [];
  final Map<String, dynamic> Function(String fn, Map<String, dynamic> b)
      responder;
  _Fn(this.responder);
  Future<Map<String, dynamic>> call(String fn, Map<String, dynamic> b) {
    calls.add(MapEntry(fn, Map<String, dynamic>.from(b)));
    return Future.value(responder(fn, b));
  }
}

Map<String, dynamic> _tokenOk({int reconnect = 270}) => {
      'ok': true,
      'access_token': 'tok',
      'endpoint': 'speech.googleapis.com',
      'recognizer': 'projects/p/locations/global/recognizers/_',
      'location': 'global',
      'language_code': 'en-IN',
      'model': 'long',
      'encoding': 'WEBM_OPUS',
      'sample_rate': 48000,
      'phrases': [
        {'value': 'Winbp', 'boost': 18}
      ],
      'reconnect_after_sec': reconnect,
      'ready_label': 'Listening',
      'fallback': {
        'location': 'us-central1',
        'endpoint': 'us-central1-speech.googleapis.com',
        'model': 'chirp_2',
        'recognizer': 'projects/p/locations/us-central1/recognizers/_',
      },
    };

Map<String, dynamic> _previewResp(String fn, Map<String, dynamic> p) => {
      'ok': true,
      'totals': [
        {'product_id': 1, 'name': 'Winbp', 'qty': 20}
      ],
      'hint': '',
      'found': 1,
      'words': (p['p_words'] as List?)?.length ?? 0,
    };

void main() {
  const dbg = Duration(milliseconds: 20);
  Future<void> settle([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test('Start calls voice-token and opens a stream with recognizer/model/phrases',
      () async {
    final fn = _Fn((f, b) => _tokenOk());
    final rpc = _Rpc(_previewResp);
    final opener = _Opener([_FakeStream()]);
    final c = VoiceLiveController(
      backend:
          SupplierVoiceBackend(supplier: 'Acme', stage: 'shop', rpc: rpc.call, fn: fn.call),
      sessionKey: 'k',
      openStream: opener.call,
      mic: _FakeMic(),
      debounce: dbg,
    );

    final ok = await c.start();
    expect(ok, true);
    expect(fn.calls.single.key, 'voice-token');
    expect(fn.calls.single.value['supplier_name'], 'Acme');
    expect(fn.calls.single.value['stage'], 'shop');
    expect(opener.tokens.length, 1);
    expect(opener.tokens.single.recognizer,
        'projects/p/locations/global/recognizers/_');
    expect(opener.tokens.single.model, 'long');
    expect(opener.tokens.single.phrases.single['value'], 'Winbp');
    await c.cancel();
  });

  test('final words accumulate 1-based with increasing seconds; interim not sent; every final previews the WHOLE list',
      () async {
    final fn = _Fn((f, b) => _tokenOk());
    final rpc = _Rpc(_previewResp);
    final s = _FakeStream();
    final c = VoiceLiveController(
      backend:
          SupplierVoiceBackend(supplier: 'Acme', stage: 'shop', rpc: rpc.call, fn: fn.call),
      sessionKey: 'k',
      openStream: _Opener([s]).call,
      mic: _FakeMic(),
      debounce: dbg,
    );
    await c.start();

    s.emitInterim('winbp twenty'); // caption only — must never reach an RPC
    s.emitFinal([
      const SpeechWord('Winbp', 0.0, 0.4),
      const SpeechWord('Twenty', 0.5, 0.9),
    ]);
    s.emitFinal([const SpeechWord('Paracip', 1.0, 1.4)]); // same burst
    await settle();

    // Preview is the "instant" half of the count, so it fires on EVERY final
    // result rather than waiting out a debounce — one per final, not one
    // per burst.
    final previews = rpc.named('voice_live_preview');
    expect(previews.length, 2, reason: 'one preview per final result');

    // Every call carries the ENTIRE word list, never just the new words.
    final words = (previews.last.value['p_words'] as List)
        .cast<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    expect(words.map((w) => w['i']).toList(), [1, 2, 3]);
    expect(words.map((w) => w['w']).toList(), ['winbp', 'twenty', 'paracip']);
    for (var i = 1; i < words.length; i++) {
      expect((words[i]['s'] as num) >= (words[i - 1]['s'] as num), true);
    }
    expect(previews.last.value['p_supplier'], 'Acme');
    await c.cancel();
  });

  test('a commit fires mid-session without stopping, and totals come from it',
      () async {
    final fn = _Fn((f, b) => _tokenOk());
    final rpc = _Rpc(_previewResp);
    final s = _FakeStream();
    final snaps = <VoiceLiveSnapshot>[];
    final c = VoiceLiveController(
      backend: SupplierVoiceBackend(
          supplier: 'Acme', stage: 'shop', rpc: rpc.call, fn: fn.call),
      sessionKey: 'k',
      openStream: _Opener([s]).call,
      mic: _FakeMic(),
      debounce: dbg,
      onSnapshot: snaps.add,
    );
    await c.start();
    s.emitFinal([const SpeechWord('Winbp', 0.0, 0.4)]);
    await settle();

    // The operator never pressed Stop, yet the count is already persisted.
    final commits = rpc.named('voice_live_commit');
    expect(commits.length, 1, reason: 'debounced commit fires while listening');
    expect(commits.single.value['p_session_key'], 'k');
    expect(snaps.any((s) => s.authoritative), true,
        reason: 'the on-screen count comes from the commit, not a local tally');
    await c.cancel();
  });

  test('re-committing the same words does not double — the whole list is resent under one key',
      () async {
    final fn = _Fn((f, b) => _tokenOk());
    final rpc = _Rpc(_previewResp);
    final s = _FakeStream();
    final c = VoiceLiveController(
      backend: SupplierVoiceBackend(
          supplier: 'Acme', stage: 'shop', rpc: rpc.call, fn: fn.call),
      sessionKey: 'k',
      openStream: _Opener([s]).call,
      mic: _FakeMic(),
      debounce: dbg,
    );
    await c.start();
    s.emitFinal([const SpeechWord('Winbp', 0.0, 0.4)]);
    await settle();
    s.emitFinal([const SpeechWord('Winbp', 1.0, 1.4)]); // same item said again
    await settle();
    await c.stop();

    final commits = rpc.named('voice_live_commit');
    // Every commit sends the FULL list under the SAME session key, so the
    // backend replaces rather than accumulates — saying an item twice counts
    // twice, but committing twice does not.
    expect(commits.length >= 2, true);
    for (final call in commits) {
      expect(call.value['p_session_key'], 'k');
    }
    final last = (commits.last.value['p_words'] as List)
        .cast<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    expect(last.map((w) => w['w']).toList(), ['winbp', 'winbp'],
        reason: 'both utterances survive in the one growing list');
  });

  test('warehouse maps a bag boundary before the next commit; shop never does',
      () async {
    for (final stage in ['warehouse', 'shop']) {
      final fn = _Fn((f, b) => _tokenOk());
      final rpc = _Rpc(_previewResp);
      final s = _FakeStream();
      final c = VoiceLiveController(
        backend: SupplierVoiceBackend(
            supplier: 'Acme', stage: stage, rpc: rpc.call, fn: fn.call),
        sessionKey: 'k',
        openStream: _Opener([s]).call,
        mic: _FakeMic(),
        debounce: dbg,
      );
      await c.start();
      s.emitFinal([const SpeechWord('Winbp', 0.0, 0.4)]);
      await settle();
      await c.mapBagBoundary(2);
      await settle();

      final bags = rpc.named('voice_map_bag_boundary');
      if (stage == 'warehouse') {
        expect(bags.length, 1, reason: 'warehouse has a bag condition');
        expect(bags.single.value['p_bag_no'], 2);
        expect(bags.single.value['p_session_key'], 'k');
        expect((bags.single.value['p_mapped_at_sec'] as num) >= 0, true);
        // The boundary must already be stored when the words either side of it
        // are re-parsed, so a commit follows it.
        expect(rpc.named('voice_live_commit').isNotEmpty, true);
      } else {
        expect(bags, isEmpty, reason: 'shop has no bag condition');
      }
      await c.cancel();
    }
  });

  test('a stream that fails to open hands the session to the clip path, once',
      () async {
    final fn = _Fn((f, b) => _tokenOk());
    final rpc = _Rpc(_previewResp);
    final fallbacks = <String>[];
    final c = VoiceLiveController(
      backend: SupplierVoiceBackend(
          supplier: 'Acme', stage: 'shop', rpc: rpc.call, fn: fn.call),
      sessionKey: 'k',
      openStream: (t, {bool fallback = false}) async =>
          throw SpeechStreamException('no grpc'),
      mic: _FakeMic(),
      debounce: dbg,
      onFallback: fallbacks.add,
    );

    final ok = await c.start();
    expect(ok, false);
    expect(fallbacks, ['no grpc'], reason: 'told exactly once');
  });

  test('totals render from the response', () async {
    final fn = _Fn((f, b) => _tokenOk());
    final rpc = _Rpc(_previewResp);
    final s = _FakeStream();
    List<Map<String, dynamic>>? seen;
    final c = VoiceLiveController(
      backend:
          SupplierVoiceBackend(supplier: 'Acme', stage: 'shop', rpc: rpc.call, fn: fn.call),
      sessionKey: 'k',
      openStream: _Opener([s]).call,
      mic: _FakeMic(),
      debounce: dbg,
      onTotals: (t, h) => seen = t,
    );
    await c.start();
    s.emitFinal([const SpeechWord('Winbp', 0.0, 0.4)]);
    await settle();
    expect(seen, isNotNull);
    expect(seen!.single['name'], 'Winbp');
    expect(seen!.single['qty'], 20);
    await c.cancel();
  });

  test('Warehouse also calls voice_live_preview with p_supplier', () async {
    final fn = _Fn((f, b) => _tokenOk());
    final rpc = _Rpc(_previewResp);
    final s = _FakeStream();
    final c = VoiceLiveController(
      backend: SupplierVoiceBackend(
          supplier: 'Acme', stage: 'warehouse', rpc: rpc.call, fn: fn.call),
      sessionKey: 'k',
      openStream: _Opener([s]).call,
      mic: _FakeMic(),
      debounce: dbg,
    );
    await c.start();
    expect(fn.calls.single.value['stage'], 'warehouse');
    s.emitFinal([const SpeechWord('Winbp', 0.0, 0.4)]);
    await settle();
    final previews = rpc.named('voice_live_preview');
    expect(previews.single.value['p_supplier'], 'Acme');
    await c.cancel();
  });

  test('Pack calls voice_live_preview_pack with p_order_id', () async {
    final fn = _Fn((f, b) => _tokenOk());
    final rpc = _Rpc((f, p) =>
        f.contains('commit') ? {'ok': true, 'saved': 1} : _previewResp(f, p));
    final s = _FakeStream();
    final c = VoiceLiveController(
      backend: PackVoiceBackend(
          orderId: 'ord-1', tokenSupplier: 'Acme', rpc: rpc.call, fn: fn.call),
      sessionKey: 'sk',
      openStream: _Opener([s]).call,
      mic: _FakeMic(),
      debounce: dbg,
    );
    await c.start();
    expect(fn.calls.single.value['stage'], 'pack');
    s.emitFinal([const SpeechWord('Winbp', 0.0, 0.4)]);
    await settle();
    final previews = rpc.named('voice_live_preview_pack');
    expect(previews.length, 1);
    expect(previews.single.value['p_order_id'], 'ord-1');
    expect(rpc.named('voice_live_preview'), isEmpty);
    await c.cancel();
  });

  test('reaching reconnect_after_sec opens a new stream and keeps the word list',
      () async {
    final fn = _Fn((f, b) => _tokenOk());
    final rpc = _Rpc(_previewResp);
    final s1 = _FakeStream();
    final s2 = _FakeStream();
    final opener = _Opener([s1, s2]);
    final c = VoiceLiveController(
      backend:
          SupplierVoiceBackend(supplier: 'Acme', stage: 'shop', rpc: rpc.call, fn: fn.call),
      sessionKey: 'k',
      openStream: opener.call,
      mic: _FakeMic(),
      debounce: dbg,
      reconnectAfter: const Duration(milliseconds: 40),
    );
    await c.start();
    s1.emitFinal([const SpeechWord('Winbp', 0.0, 0.4)]);
    await settle(90); // reconnect fires at 40ms
    expect(opener.tokens.length, greaterThanOrEqualTo(2));
    expect(opener.fallbacks[1], false);
    expect(s1.closed, true);

    // The word list survives the reconnect: a new word continues the indexes.
    s2.emitFinal([const SpeechWord('Paracip', 0.0, 0.4)]);
    await settle();
    final lastPreview = rpc.named('voice_live_preview').last;
    final words = (lastPreview.value['p_words'] as List).cast<Map>();
    expect(words.map((w) => w['w']).toList(), ['winbp', 'paracip']);
    expect(words.map((w) => w['i']).toList(), [1, 2]);
    await c.cancel();
  });

  test('Stop commits the whole list via commit RPC and shows message; second Stop is a no-op',
      () async {
    final fn = _Fn((f, b) => _tokenOk());
    final rpc = _Rpc((f, p) => f.contains('commit')
        ? {'ok': true, 'saved': 1, 'message': 'Counted 1 product.'}
        : _previewResp(f, p));
    final s = _FakeStream();
    String? msg;
    final c = VoiceLiveController(
      backend:
          SupplierVoiceBackend(supplier: 'Acme', stage: 'shop', rpc: rpc.call, fn: fn.call),
      sessionKey: 'sk',
      openStream: _Opener([s]).call,
      mic: _FakeMic(),
      debounce: dbg,
      onMessage: (m) => msg = m,
    );
    await c.start();
    s.emitFinal([const SpeechWord('Winbp', 0.0, 0.4)]);
    await settle();

    // The debounce has already committed once mid-session — that is the point of
    // this change. Stop commits again rather than assuming the pending words are
    // already saved; the RPC replaces the session's rows, so a repeat cannot
    // double the ledger.
    final before = rpc.named('voice_live_commit').length;
    expect(before, 1, reason: 'debounced commit landed while still speaking');

    final r = await c.stop();
    expect(r, isNotNull);
    final commits = rpc.named('voice_live_commit');
    expect(commits.length, before + 1, reason: 'Stop always commits');
    // EVERY commit carries the same session key and the WHOLE word list, so the
    // backend can replace rather than append.
    for (final call in commits) {
      expect(call.value['p_supplier'], 'Acme');
      expect(call.value['p_stage'], 'shop');
      expect(call.value['p_session_key'], 'sk');
      expect((call.value['p_words'] as List).single['w'], 'winbp');
    }
    expect(msg, 'Counted 1 product.');

    final r2 = await c.stop();
    expect(r2, isNull);
    expect(rpc.named('voice_live_commit').length, before + 1,
        reason: 'a second Stop commits nothing');
  });

  test('INVALID_ARGUMENT stream error retries once on fallback', () async {
    final fn = _Fn((f, b) => _tokenOk());
    final rpc = _Rpc(_previewResp);
    final s1 = _FakeStream();
    final s2 = _FakeStream();
    final opener = _Opener([s1, s2]);
    final c = VoiceLiveController(
      backend:
          SupplierVoiceBackend(supplier: 'Acme', stage: 'shop', rpc: rpc.call, fn: fn.call),
      sessionKey: 'k',
      openStream: opener.call,
      mic: _FakeMic(),
      debounce: dbg,
      reconnectAfter: const Duration(seconds: 60),
    );
    await c.start();
    s1.fail(SpeechStreamException('bad config', invalidArgument: true));
    await settle();
    expect(opener.tokens.length, 2);
    expect(opener.fallbacks[1], true, reason: 'retry uses the fallback config');
    await c.cancel();
  });

  test('token error shows message and opens no stream', () async {
    final fn =
        _Fn((f, b) => {'error': 'nothing_open', 'message': 'no open items'});
    final rpc = _Rpc(_previewResp);
    final opener = _Opener([_FakeStream()]);
    String? err;
    final c = VoiceLiveController(
      backend:
          SupplierVoiceBackend(supplier: 'X', stage: 'shop', rpc: rpc.call, fn: fn.call),
      sessionKey: 'k',
      openStream: opener.call,
      mic: _FakeMic(),
      onError: (m) => err = m,
    );
    final ok = await c.start();
    expect(ok, false);
    expect(err, 'no open items');
    expect(opener.tokens, isEmpty, reason: 'no stream opened on token error');
    await c.cancel();
  });

  test('web uses the clip path — the live gate is false on web (no voice-token)',
      () {
    // The Android live path is the ONLY caller of voice-token. On web the gate is
    // false, so the caller keeps the existing clip flow and never mints a token.
    expect(
        isLiveVoicePlatform(isWeb: true, platform: TargetPlatform.android), false);
    expect(
        isLiveVoicePlatform(isWeb: false, platform: TargetPlatform.android), true);
    expect(
        isLiveVoicePlatform(isWeb: false, platform: TargetPlatform.iOS), false);
  });

  // CHANGE #670 REGRESSION GUARD. The previous attempt shipped a complete,
  // fully-tested VoiceLiveController into a screen file that NOTHING imported,
  // so on the device the Shop/Warehouse/Pack mics still ran the old clip path
  // and nothing about the count changed. Unit-testing the controller could not
  // catch that — only its reachability can. This asserts the real counting
  // screen actually constructs it, for all three stages.
  test('the real fulfillment screen wires the live controller (not dead code)',
      () {
    final src =
        File('lib/screens/admin/admin_fulfillment_screen_web.dart').readAsStringSync();
    expect(src.contains("services/voice_live_service.dart"), true,
        reason: 'the counting screen must import the live service');
    expect(src.contains('isLiveVoicePlatform('), true,
        reason: 'the live path must be gated on the platform, not assumed');
    expect(src.contains('SupplierVoiceBackend('), true,
        reason: 'Shop + Warehouse must count through the supplier backend');
    expect(src.contains('PackVoiceBackend('), true,
        reason: 'Pack must count through the order backend');
    expect('VoiceLiveController('.allMatches(src).length >= 2, true,
        reason: 'one controller for Shop/Warehouse and one for Pack');
    // Bags exist only in the warehouse; Pack must never send a boundary.
    expect(src.contains('mapBagBoundary('), true,
        reason: 'warehouse bag mapping must survive the live path');
  });

  test('an item heard without a number is surfaced, never dropped', () {
    // The backend returns `unmatched` for "heard the name but no number".
    // The snapshot must carry it verbatim so the screen can say it out loud —
    // silently dropping the row is what made a miscount invisible.
    final snap = VoiceLiveSnapshot.fromMap(const {
      'totals': [
        {'product_id': 1, 'name': 'Monticope Tablet', 'qty': 2}
      ],
      'unmatched': [
        {
          'product_id': 2,
          'matched_name': 'Monticope Suspension',
          'heard': 'monticope suspension',
          'message': 'Monticope Suspension: heard the name but no number'
        }
      ],
      'hint': 'Monticope Suspension: heard the name but no number',
    }, authoritative: true);

    expect(snap.unmatched.length, 1);
    expect(snap.unmatched.first['message'],
        'Monticope Suspension: heard the name but no number');
    expect(snap.hint, 'Monticope Suspension: heard the name but no number',
        reason: 'the wording is the backend\'s, never composed in Dart');
    // Absent key stays empty rather than becoming a Dart-invented fallback.
    expect(VoiceLiveSnapshot.fromMap(const {}, authoritative: false).unmatched,
        isEmpty);
  });

  test('both live surfaces show the unmatched rows', () {
    final src =
        File('lib/screens/admin/admin_fulfillment_screen_web.dart').readAsStringSync();
    expect('snap.unmatched'.allMatches(src).length >= 2, true,
        reason: 'Shop/Warehouse AND Pack must both surface unmatched items');
  });
}
