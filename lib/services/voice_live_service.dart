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

Future<dynamic> _defaultRpc(String fn, Map<String, dynamic> params) =>
    Supabase.instance.client.rpc(fn, params: params);

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

  Future<Map<String, dynamic>> fetchToken();
  Future<Map<String, dynamic>> preview(List<Map<String, dynamic>> words);
  Future<Map<String, dynamic>> commit(
      List<Map<String, dynamic>> words, String sessionKey);
}

/// Shop / Warehouse: count against a SUPPLIER's open items.
class SupplierVoiceBackend implements VoiceLiveBackend {
  @override
  final String tokenSupplier;
  @override
  final String stage; // 'shop' | 'warehouse'
  final String? date; // 'YYYY-MM-DD' — the admin's active date
  final RpcCaller rpc;
  final FnCaller fn;

  SupplierVoiceBackend({
    required String supplier,
    required this.stage,
    this.date,
    RpcCaller? rpc,
    FnCaller? fn,
  })  : tokenSupplier = supplier,
        rpc = rpc ?? _defaultRpc,
        fn = fn ?? _defaultFn;

  @override
  Future<Map<String, dynamic>> fetchToken() =>
      fn('voice-token', {'supplier_name': tokenSupplier, 'stage': stage});

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
class PackVoiceBackend implements VoiceLiveBackend {
  final String orderId;
  @override
  final String tokenSupplier;
  final RpcCaller rpc;
  final FnCaller fn;

  PackVoiceBackend({
    required this.orderId,
    required this.tokenSupplier,
    RpcCaller? rpc,
    FnCaller? fn,
  })  : rpc = rpc ?? _defaultRpc,
        fn = fn ?? _defaultFn;

  @override
  String get stage => 'pack';

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
/// Lifecycle: start() → (stream words → debounced preview) → reconnect at
/// reconnect_after_sec → stop() commits ONCE. Every user-facing string comes
/// from the backend (ready label, hint, commit message).
class VoiceLiveController {
  final VoiceLiveBackend backend;
  final String sessionKey;
  final SpeechStreamOpener openStream;
  final MicSource mic;
  final Duration debounce;

  /// Test-only override for the reconnect interval. In production the token's
  /// reconnect_after_sec is used (Google closes a stream at 5 minutes).
  final Duration? reconnectAfter;

  /// ready_label from the token (shown when the stream is live).
  final void Function(String label)? onReady;

  /// Interim caption — the words currently being spoken (never committed).
  final void Function(String caption)? onCaption;

  /// Running totals + hint from voice_live_preview(_pack).
  final void Function(List<Map<String, dynamic>> totals, String hint)? onTotals;

  /// The commit message from voice_live_commit(_pack) on Stop.
  final void Function(String message)? onMessage;

  /// A backend-owned error string (token error, stream 403, window failure).
  final void Function(String message)? onError;

  VoiceLiveController({
    required this.backend,
    required this.sessionKey,
    SpeechStreamOpener? openStream,
    MicSource? mic,
    this.debounce = const Duration(milliseconds: 700),
    this.reconnectAfter,
    this.onReady,
    this.onCaption,
    this.onTotals,
    this.onMessage,
    this.onError,
  })  : openStream = openStream ?? native.openNativeSpeechStream,
        mic = mic ?? native.createNativeMic();

  final List<Map<String, dynamic>> _words = <Map<String, dynamic>>[];
  int _counter = 0;
  double _streamBase = 0.0; // sec offset added to a fresh stream's word clock
  double _maxEndSec = 0.0;

  VoiceToken? _token;
  SpeechStream? _stream;
  StreamSubscription<SpeechEvent>? _eventSub;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _debounceTimer;
  Timer? _reconnectTimer;

  bool _started = false;
  bool _stopped = false;
  bool _committed = false;
  bool _retriedFallback = false;

  bool get isStreaming => _started && !_stopped;

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

    try {
      // Mic first — a denied permission must not leave a dangling stream.
      final micStream = await mic.start(sampleRate: token.sampleRate);
      _micSub = micStream.listen(
        (frame) => _stream?.addAudio(frame),
        onError: (_) {},
        cancelOnError: false,
      );
      await _openStream(fallback: false);
    } catch (e) {
      // Mic permission / first-connect failure: tear everything down and let the
      // caller surface it. Nothing was committed and no stream leaks.
      _started = false;
      await cancel();
      rethrow;
    }
    return true;
  }

  Future<void> _openStream({required bool fallback}) async {
    final token = _token;
    if (token == null || _stopped) return;
    final s = await openStream(token, fallback: fallback);
    _stream = s;
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
    if (appended) _schedulePreview();
  }

  void _schedulePreview() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () async {
      if (_stopped) return;
      final snapshot = List<Map<String, dynamic>>.from(_words);
      try {
        final r = await backend.preview(snapshot);
        if (_stopped) return;
        if (r['error'] != null) {
          onError?.call((r['message'] ?? r['error']).toString());
          return;
        }
        final totals = ((r['totals'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        onTotals?.call(totals, (r['hint'] ?? '').toString());
      } catch (_) {
        // Live preview is best-effort — a failed refresh never breaks counting;
        // Stop still commits the full word list.
      }
    });
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
    _debounceTimer?.cancel();
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

    if (!_started || _committed) return null;
    _committed = true;
    final snapshot = List<Map<String, dynamic>>.from(_words);
    final r = await backend.commit(snapshot, sessionKey);
    final msg = (r['message'] ?? '').toString();
    if (r['error'] != null) {
      onError?.call(msg.isNotEmpty ? msg : r['error'].toString());
    } else if (msg.isNotEmpty) {
      onMessage?.call(msg);
    }
    return r;
  }

  /// Aborts without committing (operator backs out). Safe to call anytime.
  Future<void> cancel() async {
    if (_stopped) return;
    _stopped = true;
    _debounceTimer?.cancel();
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
