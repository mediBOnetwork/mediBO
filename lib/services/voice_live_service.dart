// Realtime voice counting (Android only) — the controller that ties the live
// Speech-to-Text stream to the stateless preview/commit RPCs. Web is untouched
// and keeps the clip flow in voice_receive_service.dart.
//
// THE APP RENDERS. IT NEVER DECIDES:
//  - No matching, number parsing or product lookup happens here — voice_live_*
//    RPCs do all of it. This controller only accumulates the words heard and
//    renders the totals/hint/message the backend returns.
//  - Every RPC name + param key is fixed by the backend contract; the tab only
//    picks WHICH backend (supplier vs pack).
//
// Everything the tests need to drive is injectable: the token/preview/commit
// callers (via the two backend classes), the Speech stream opener and the mic.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'voice_live_types.dart';
import 'voice_review_recorder.dart';
import 'speech_native.dart' as native;

export 'voice_live_types.dart';

/// The one gate: realtime streaming counting runs ONLY on Android. Everywhere
/// else (web especially) the caller keeps the existing clip flow and never calls
/// voice-token. Pass `kIsWeb` and `defaultTargetPlatform` from the call site.
bool isLiveVoicePlatform(
        {required bool isWeb, required TargetPlatform platform}) =>
    !isWeb && platform == TargetPlatform.android;

/// Low-level Supabase RPC caller — `(fn, params) => rpc`. Injectable for tests.
typedef RpcCaller = Future<dynamic> Function(
    String fn, Map<String, dynamic> params);

/// Low-level edge-function caller returning the JSON body as a map. Injectable.
typedef FnCaller = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> body);

/// Puts one review-audio window in storage. Injectable so tests never upload.
typedef StorageUploader = Future<void> Function(
    String bucket, String path, Uint8List bytes, String contentType);

Future<dynamic> _defaultRpc(String fn, Map<String, dynamic> params) =>
    Supabase.instance.client.rpc(fn, params: params);

Future<void> _defaultUpload(
    String bucket, String path, Uint8List bytes, String contentType) async {
  // upsert: a reconnect or a retry rewrites the same window key rather than
  // failing — the backend owns the key, so a repeat is the SAME window.
  await Supabase.instance.client.storage.from(bucket).uploadBinary(
        path,
        bytes,
        fileOptions: FileOptions(contentType: contentType, upsert: true),
      );
}

Future<Map<String, dynamic>> _defaultFn(
    String fn, Map<String, dynamic> body) async {
  try {
    final res = await Supabase.instance.client.functions.invoke(fn, body: body);
    final d = res.data;
    return d is Map
        ? Map<String, dynamic>.from(d)
        : <String, dynamic>{'error': 'bad_response'};
  } on FunctionException catch (e) {
    final d = e.details;
    if (d is Map) return Map<String, dynamic>.from(d);
    return <String, dynamic>{'error': 'token_error', 'message': e.toString()};
  }
}

Map<String, dynamic> _asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// One tab's backend wiring. Two concrete shapes: supplier (Shop/Warehouse) and
/// pack. The controller is identical for both — only the RPC pair and key differ.
abstract class VoiceLiveBackend {
  /// Supplier passed to voice-token (Pack passes the order's supplier).
  String get tokenSupplier;
  String get stage;

  /// True only where the stage actually has a bag condition (warehouse). Shop and
  /// pack never map bag boundaries and never show a bag chip.
  bool get supportsBags;

  Future<Map<String, dynamic>> fetchToken();
  Future<Map<String, dynamic>> preview(List<Map<String, dynamic>> words);
  Future<Map<String, dynamic>> commit(
      List<Map<String, dynamic>> words, String sessionKey);

  /// Records that everything spoken from [atSec] onwards belongs to [bagNo].
  /// No-op where [supportsBags] is false.
  Future<void> mapBagBoundary(String sessionKey, int bagNo, double atSec);

  /// Where one review-audio window's bytes belong. The backend owns the bucket
  /// AND the object key — the app never composes a storage path.
  /// Returns `{ok, bucket, path, content_type, message}`.
  Future<Map<String, dynamic>> clipTarget(String sessionKey, int seq);

  /// Uploads that window.
  Future<void> uploadClip(
      String bucket, String path, Uint8List bytes, String contentType);

  /// Tells the backend the window landed, so it binds the clip to every mention
  /// whose word offset falls inside [tStart, tEnd).
  Future<void> attachClip(
      String sessionKey, int seq, String path, double tStart, double tEnd);
}

/// The review-audio half of the contract — identical for supplier and pack, so it
/// lives once. Only [stage] differs, and the backend reads that.
mixin VoiceClipStorage {
  RpcCaller get rpc;
  StorageUploader get storage;
  String get stage;

  Future<Map<String, dynamic>> clipTarget(String sessionKey, int seq) async =>
      _asMap(await rpc('voice_live_clip_target', {
        'p_session_key': sessionKey,
        'p_seq': seq,
        'p_stage': stage,
      }));

  Future<void> uploadClip(String bucket, String path, Uint8List bytes,
          String contentType) =>
      storage(bucket, path, bytes, contentType);

  Future<void> attachClip(String sessionKey, int seq, String path,
      double tStart, double tEnd) async {
    await rpc('voice_live_attach_clip', {
      'p_session_key': sessionKey,
      'p_seq': seq,
      'p_clip_path': path,
      'p_t_start': tStart,
      'p_t_end': tEnd,
      'p_stage': stage,
    });
  }
}

/// Shop / Warehouse: count against a SUPPLIER's open items.
class SupplierVoiceBackend with VoiceClipStorage implements VoiceLiveBackend {
  @override
  final String tokenSupplier;
  @override
  final String stage; // 'shop' | 'warehouse'
  final String? date; // 'YYYY-MM-DD' — the admin's active date
  @override
  final RpcCaller rpc;
  final FnCaller fn;
  @override
  final StorageUploader storage;

  SupplierVoiceBackend({
    required String supplier,
    required this.stage,
    this.date,
    RpcCaller? rpc,
    FnCaller? fn,
    StorageUploader? storage,
  })  : tokenSupplier = supplier,
        rpc = rpc ?? _defaultRpc,
        fn = fn ?? _defaultFn,
        storage = storage ?? _defaultUpload;

  /// Only the warehouse packs into bags; the shop counts loose stock.
  @override
  bool get supportsBags => stage == 'warehouse';

  @override
  Future<Map<String, dynamic>> fetchToken() =>
      fn('voice-token', {'supplier_name': tokenSupplier, 'stage': stage});

  @override
  Future<void> mapBagBoundary(
      String sessionKey, int bagNo, double atSec) async {
    if (!supportsBags) return;
    await rpc('voice_map_bag_boundary', {
      'p_session_key': sessionKey,
      'p_supplier_name': tokenSupplier,
      'p_bag_no': bagNo,
      'p_mapped_at_sec': atSec,
    });
  }

  @override
  Future<Map<String, dynamic>> preview(List<Map<String, dynamic>> words) async =>
      _asMap(await rpc('voice_live_preview',
          {'p_supplier': tokenSupplier, 'p_words': words}));

  @override
  Future<Map<String, dynamic>> commit(
          List<Map<String, dynamic>> words, String sessionKey) async =>
      _asMap(await rpc('voice_live_commit', {
        'p_supplier': tokenSupplier,
        'p_words': words,
        'p_session_key': sessionKey,
        'p_stage': stage,
        if (date != null) 'p_date': date,
      }));
}

/// Pack: count against ONE CUSTOMER ORDER. Writes through pack_set_counted.
class PackVoiceBackend with VoiceClipStorage implements VoiceLiveBackend {
  final String orderId;
  @override
  final String tokenSupplier;
  @override
  final RpcCaller rpc;
  final FnCaller fn;
  @override
  final StorageUploader storage;

  PackVoiceBackend({
    required this.orderId,
    required this.tokenSupplier,
    RpcCaller? rpc,
    FnCaller? fn,
    StorageUploader? storage,
  })  : rpc = rpc ?? _defaultRpc,
        fn = fn ?? _defaultFn,
        storage = storage ?? _defaultUpload;

  @override
  String get stage => 'pack';

  /// Packing a customer order has no bag condition.
  @override
  bool get supportsBags => false;

  @override
  Future<void> mapBagBoundary(String sessionKey, int bagNo, double atSec) async {}

  @override
  Future<Map<String, dynamic>> fetchToken() =>
      fn('voice-token', {'supplier_name': tokenSupplier, 'stage': 'pack'});

  @override
  Future<Map<String, dynamic>> preview(List<Map<String, dynamic>> words) async =>
      _asMap(await rpc(
          'voice_live_preview_pack', {'p_order_id': orderId, 'p_words': words}));

  @override
  Future<Map<String, dynamic>> commit(
          List<Map<String, dynamic>> words, String sessionKey) async =>
      _asMap(await rpc('voice_live_commit_pack', {
        'p_order_id': orderId,
        'p_words': words,
        'p_session_key': sessionKey,
      }));
}

/// Drives one continuous live-counting session on Android.
///
/// Lifecycle: start() → words accumulate → every FINAL result repaints from
/// voice_live_preview and schedules a COMMIT → reconnect at reconnect_after_sec
/// → stop() commits one last time. Every user-facing string comes from the
/// backend (ready label, hint, commit message).
///
/// Two rules make the count trustworthy:
///  - The word list is ONE growing list per session. It is never cleared and
///    every call sends the WHOLE list with the SAME session key, so a lost or
///    reordered request can never lose a count.
///  - The number on screen comes from the COMMIT response, which is what the
///    backend persisted. There is no locally incremented tally to drift.
///
/// Committing mid-session is safe because voice_live_commit is idempotent: it
/// deletes the session's live rows and re-inserts from the full word list, so
/// N commits of the same words produce the same ledger as one.
class VoiceLiveController {
  final VoiceLiveBackend backend;
  final String sessionKey;
  final SpeechStreamOpener openStream;
  final MicSource mic;

  /// Quiet-time before a commit fires (restarted by every final result).
  final Duration debounce;

  /// Hard ceiling: a continuous talker never resets the debounce, so this
  /// guarantees the on-screen count still moves at least this often.
  final Duration commitCeiling;

  /// Test-only override for the reconnect interval. In production the token's
  /// reconnect_after_sec is used (Google closes a stream at 5 minutes).
  final Duration? reconnectAfter;

  /// ready_label from the token (shown when the stream is live).
  final void Function(String label)? onReady;

  /// Interim caption — the words currently being spoken (never committed).
  final void Function(String caption)? onCaption;

  /// Running totals + hint. Fires for BOTH the fast preview repaint and the
  /// authoritative commit — see [onSnapshot] to tell them apart.
  final void Function(List<Map<String, dynamic>> totals, String hint)? onTotals;

  /// Every render-ready payload, preview or commit. Snapshots with
  /// [VoiceLiveSnapshot.authoritative] true are the persisted count and must win
  /// on screen.
  final void Function(VoiceLiveSnapshot snap)? onSnapshot;

  /// The commit message from voice_live_commit(_pack) on Stop.
  final void Function(String message)? onMessage;

  /// A backend-owned error string (token error, stream 403, window failure).
  final void Function(String message)? onError;

  /// Fired at most ONCE, when the live stream cannot be used at all (failed to
  /// open, or dropped twice) and the caller should switch to the clip recorder.
  final void Function(String message)? onFallback;

  VoiceLiveController({
    required this.backend,
    required this.sessionKey,
    SpeechStreamOpener? openStream,
    MicSource? mic,
    this.debounce = const Duration(milliseconds: 700),
    this.commitCeiling = const Duration(seconds: 5),
    this.reconnectAfter,
    this.onReady,
    this.onCaption,
    this.onTotals,
    this.onSnapshot,
    this.onMessage,
    this.onError,
    this.onFallback,
  })  : openStream = openStream ?? native.openNativeSpeechStream,
        mic = mic ?? native.createNativeMic();

  final List<Map<String, dynamic>> _words = <Map<String, dynamic>>[];
  int _counter = 0;
  double _streamBase = 0.0; // sec offset added to a fresh stream's word clock
  double _maxEndSec = 0.0;

  VoiceToken? _token;
  SpeechStream? _stream;

  /// Keeps a playable copy of the session for the review screen. Built from the
  /// token's review_audio block, so the backend decides whether it runs at all.
  VoiceReviewRecorder? _review;
  StreamSubscription<SpeechEvent>? _eventSub;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _commitTimer;
  Timer? _ceilingTimer;
  Timer? _reconnectTimer;

  bool _started = false;
  bool _stopped = false;
  bool _retriedFallback = false;

  // Commit bookkeeping. Commits never overlap: a request arriving while one is
  // in flight sets _commitAgain instead, so the ledger is only ever rewritten by
  // one call at a time.
  bool _commitInFlight = false;
  bool _commitAgain = false;
  bool _dirty = false;
  Map<String, dynamic>? _lastCommit;

  // Preview responses can land out of order; only the newest may repaint.
  int _previewSeq = 0;

  // Clip-fallback bookkeeping.
  int _drops = 0;
  bool _fellBack = false;

  /// Wall-clock seconds since the first stream opened — the same clock Speech
  /// stamps its word offsets on, and therefore the clock a bag boundary must be
  /// recorded against.
  final Stopwatch _sessionClock = Stopwatch();

  bool get isStreaming => _started && !_stopped;

  double get elapsedSec {
    final byClock = _sessionClock.elapsedMilliseconds / 1000.0;
    return byClock > _maxEndSec ? byClock : _maxEndSec;
  }

  /// The most recent commit payload (null until the first commit lands).
  Map<String, dynamic>? get lastCommit => _lastCommit;

  /// Fetches the token, then opens the mic + Speech stream. Returns true if the
  /// session actually started; false (with onError already fired) on a token
  /// error — in which case NO stream is opened.
  Future<bool> start() async {
    if (_started || _stopped) return _started;
    final Map<String, dynamic> tok;
    try {
      tok = await backend.fetchToken();
    } catch (e) {
      onError?.call(e.toString());
      return false;
    }
    if (tok['ok'] != true || tok['error'] != null) {
      onError?.call((tok['message'] ?? tok['error'] ?? 'token_error').toString());
      return false;
    }
    final token = VoiceToken.fromMap(tok);
    _token = token;
    _started = true;
    if (token.readyLabel.isNotEmpty) onReady?.call(token.readyLabel);

    // The live path streams PCM straight to Speech, so the mic frames are the
    // ONLY copy of the audio. Tee them into the review recorder or there is
    // nothing to play back afterwards.
    if (token.reviewAudio.usable) {
      _review = VoiceReviewRecorder(
        cfg: token.reviewAudio,
        sourceSampleRate: token.sampleRate,
        nowSec: () => elapsedSec,
        resolveTarget: (seq) => backend.clipTarget(sessionKey, seq),
        upload: backend.uploadClip,
        attach: (seq, path, from, to) =>
            backend.attachClip(sessionKey, seq, path, from, to),
        onProblem: (m) => onError?.call(m),
      );
    }

    try {
      // Mic first — a denied permission must not leave a dangling stream. A mic
      // failure is NOT a streaming problem: the clip recorder needs the very same
      // permission, so it is surfaced to the caller rather than falled back on.
      final micStream = await mic.start(sampleRate: token.sampleRate);
      _micSub = micStream.listen(
        (frame) {
          _stream?.addAudio(frame);
          // Counting comes first; a review-audio fault never costs a count.
          _review?.addFrame(frame);
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (e) {
      _started = false;
      await cancel();
      rethrow;
    }

    try {
      await _openStream(fallback: false);
    } catch (e) {
      // gRPC never came up. The clip path does not need gRPC, so hand this
      // session over to it instead of leaving the operator with a dead mic.
      _started = false;
      await cancel();
      _announceFallback(e is SpeechStreamException ? e.message : e.toString());
      return false;
    }
    return true;
  }

  /// Tells the caller ONCE that live streaming is unavailable for this session.
  void _announceFallback(String why) {
    if (_fellBack) return;
    _fellBack = true;
    onFallback?.call(why);
  }

  Future<void> _openStream({required bool fallback}) async {
    final token = _token;
    if (token == null || _stopped) return;
    final s = await openStream(token, fallback: fallback);
    _stream = s;
    if (!_sessionClock.isRunning) _sessionClock.start();
    _streamBase = _maxEndSec; // keep session-clock seconds monotonic
    _eventSub = s.events.listen(
      _onEvent,
      onError: _onStreamError,
      onDone: _onStreamDone,
      cancelOnError: false,
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
        reconnectAfter ?? Duration(seconds: token.reconnectAfterSec),
        _doReconnect);
  }

  void _onEvent(SpeechEvent e) {
    if (_stopped) return;
    if (!e.isFinal) {
      onCaption?.call(e.transcript);
      return;
    }
    var appended = false;
    if (e.words.isNotEmpty) {
      for (final w in e.words) {
        final s = _streamBase + w.startSec;
        final en = _streamBase + w.endSec;
        if (en > _maxEndSec) _maxEndSec = en;
        _words.add({
          'i': ++_counter,
          'w': w.word.toLowerCase(),
          's': s,
          'e': en,
        });
        appended = true;
      }
    } else if (e.transcript.trim().isNotEmpty) {
      // Final result without word offsets — keep the words, stamp monotonic
      // seconds so ordering survives.
      for (final tok in e.transcript.trim().split(RegExp(r'\s+'))) {
        _maxEndSec += 0.001;
        _words.add({'i': ++_counter, 'w': tok.toLowerCase(), 's': _maxEndSec, 'e': _maxEndSec});
        appended = true;
      }
    }
    if (appended) {
      // Repaint immediately from the preview so the number moves while the
      // operator is still talking, and schedule the commit that will replace it
      // with the persisted truth.
      _runPreview();
      _scheduleCommit();
    }
  }

  /// Fires on EVERY final result — not debounced, because this is the "instant"
  /// half of the count. Read-only and best-effort: a failed preview never breaks
  /// counting, since the commit re-sends the whole word list anyway.
  void _runPreview() async {
    final seq = ++_previewSeq;
    final snapshot = List<Map<String, dynamic>>.from(_words);
    try {
      final r = await backend.preview(snapshot);
      // A slower earlier request must never overwrite a newer repaint, and a
      // preview must never overwrite the persisted count after Stop.
      if (_stopped || seq != _previewSeq) return;
      if (r['error'] != null) {
        onError?.call((r['message'] ?? r['error']).toString());
        return;
      }
      final snap = VoiceLiveSnapshot.fromMap(r, authoritative: false);
      onTotals?.call(snap.totals, snap.hint);
      onSnapshot?.call(snap);
    } catch (_) {
      // Best-effort: Stop still commits the full word list.
    }
  }

  void _scheduleCommit() {
    _dirty = true;
    _commitTimer?.cancel();
    _commitTimer = Timer(debounce, _flushCommit);
    // The ceiling is deliberately NOT reset by later words — otherwise someone
    // reading out a long list would never see the count persist until they
    // paused. `??=` keeps the first pending word's deadline.
    _ceilingTimer ??= Timer(commitCeiling, _flushCommit);
  }

  /// Sends the ENTIRE word list under the SAME session key and renders what came
  /// back. Safe to call repeatedly: voice_live_commit replaces the session's live
  /// rows rather than adding to them.
  Future<void> _flushCommit({bool isStop = false}) async {
    _commitTimer?.cancel();
    _commitTimer = null;
    _ceilingTimer?.cancel();
    _ceilingTimer = null;
    if (!_started) return;
    if (_stopped && !isStop) return;
    if (!_dirty && !isStop) return;
    if (_commitInFlight) {
      // Never let two commits rewrite the same session concurrently.
      _commitAgain = true;
      return;
    }
    _commitInFlight = true;
    _dirty = false;
    final snapshot = List<Map<String, dynamic>>.from(_words);
    try {
      final r = await backend.commit(snapshot, sessionKey);
      _lastCommit = r;
      if (r['error'] != null) {
        onError?.call((r['message'] ?? r['error']).toString());
      } else {
        final snap = VoiceLiveSnapshot.fromMap(r, authoritative: true);
        onTotals?.call(snap.totals, snap.hint);
        onSnapshot?.call(snap);
        // The "N count(s) saved" line is for Stop only — showing it every few
        // seconds mid-count would be noise.
        final msg = (r['message'] ?? '').toString();
        if (isStop && msg.isNotEmpty) onMessage?.call(msg);
      }
    } catch (e) {
      // A dropped mid-session commit loses nothing: every word is still held and
      // the next commit sends the whole list again.
      _dirty = true;
      if (isStop) rethrow;
    } finally {
      _commitInFlight = false;
      if (_commitAgain) {
        _commitAgain = false;
        if (!_stopped) _scheduleCommit();
      }
    }
  }

  /// Warehouse only. Marks the moment [bagNo] became the current bag, so the
  /// backend can attribute words either side of it to the right bag. Recorded
  /// BEFORE the next commit fires, then commits immediately so the operator sees
  /// the new bag take effect.
  Future<void> mapBagBoundary(int bagNo) async {
    if (!backend.supportsBags || !_started || _stopped) return;
    _commitTimer?.cancel();
    _commitTimer = null;
    try {
      await backend.mapBagBoundary(sessionKey, bagNo, elapsedSec);
    } catch (e) {
      onError?.call(e.toString());
      return;
    }
    _dirty = true;
    await _flushCommit();
  }

  void _onStreamError(Object err, StackTrace st) async {
    if (_stopped) return;
    // INVALID_ARGUMENT (config refused) → retry ONCE on the token's fallback,
    // keeping every word already collected.
    if (err is SpeechStreamException &&
        err.invalidArgument &&
        !_retriedFallback) {
      _retriedFallback = true;
      await _eventSub?.cancel();
      try {
        await _stream?.close();
      } catch (_) {}
      _stream = null;
      await _openStream(fallback: true);
      return;
    }
    // 403 (not enabled) or any other stream error: surface the message, stop the
    // stream, but KEEP the words so Stop can still commit them.
    final msg = err is SpeechStreamException ? err.message : err.toString();
    onError?.call(msg);
    _reconnectTimer?.cancel();
    await _eventSub?.cancel();
    _eventSub = null;
    _stream = null;
    // One drop can be a flaky moment on warehouse wifi; two means the live path
    // is not going to hold for this session, so move to the clip recorder.
    _drops++;
    if (_drops >= 2) _announceFallback(msg);
  }

  void _onStreamDone() {
    // Server closed the stream (5-minute cap or network) before our proactive
    // reconnect fired — reopen and keep counting, unless we're stopping.
    if (_stopped || _stream == null) return;
    _doReconnect();
  }

  Future<void> _doReconnect() async {
    if (_stopped) return;
    final old = _stream;
    await _eventSub?.cancel();
    _eventSub = null;
    await _openStream(fallback: _retriedFallback);
    try {
      await old?.close();
    } catch (_) {}
  }

  /// Stops the stream + mic and commits the session ONCE via the tab's commit
  /// RPC. Idempotent: a second Stop is a no-op (never double-commits). Returns
  /// the commit payload (or null if nothing was ever started / already stopped).
  Future<Map<String, dynamic>?> stop() async {
    if (_stopped) return null;
    _stopped = true;
    _commitTimer?.cancel();
    _ceilingTimer?.cancel();
    _reconnectTimer?.cancel();
    await _micSub?.cancel();
    _micSub = null;
    try {
      await mic.stop();
    } catch (_) {}
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await _stream?.close();
    } catch (_) {}
    _stream = null;

    // Flush the last review window BEFORE the final commit: commit runs
    // voice_live_bind_clips, so a clip attached first is bound to the mentions
    // the very same call creates.
    try {
      await _review?.stop();
    } catch (_) {}
    _review = null;

    if (!_started) return null;
    // Always commit on Stop, even if a debounced commit already sent the same
    // words: the RPC replaces the session's rows, so a repeat cannot double the
    // ledger, and this closes the window where the last words were still pending.
    await _flushCommit(isStop: true);
    return _lastCommit;
  }

  /// Aborts without committing (operator backs out). Safe to call anytime.
  Future<void> cancel() async {
    if (_stopped) return;
    _stopped = true;
    // Nothing is committed, so nothing needs the audio — drop it without
    // uploading rather than paying for bytes no mention will ever point at.
    _review = null;
    _commitTimer?.cancel();
    _ceilingTimer?.cancel();
    _reconnectTimer?.cancel();
    await _micSub?.cancel();
    _micSub = null;
    try {
      await mic.stop();
    } catch (_) {}
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await _stream?.close();
    } catch (_) {}
    _stream = null;
  }
}
