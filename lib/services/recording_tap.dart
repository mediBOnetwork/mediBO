import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'session_recorder.dart';
import 'test_session.dart';

/// CMD #1851 — THE RECORDING TAP.
///
/// `test_recording` and `test_recording_step` existed from #638 and never held
/// a row, because the only things ever observed were route names. A route name
/// cannot be replayed: Flutter draws to canvas and no browser tool can read a
/// pixel of it. The thing that CAN be replayed is the conversation with the
/// backend — the function the screen called, the arguments it sent, and the
/// answer it got — so that is what this records.
///
/// It is one layer in the http client chain every Supabase call already goes
/// through, so it sees all 896 `.rpc(` call sites without touching one of them.
///
/// §6, THE REAL PATH. Recording exists only inside a live test session. With no
/// session [RecordingCapture.active] is false, [send] is a single boolean test
/// followed by the untouched inner call, nothing is buffered, and no request is
/// ever made. The backend agrees independently: `recording_capture` refuses,
/// with no write at all, when this install has no session (`recording_live_id`).
///
/// THE APP DECIDES NOTHING. Whether a recording is live, how often to flush,
/// how large a batch may be, how much of a body to keep and which functions are
/// never worth recording all arrive in `recording_state()` — carried on the test
/// mode banner the whole app already polls. Retuning any of them is an UPDATE.
class RecordingTap extends http.BaseClient {
  RecordingTap(this._inner);

  final http.Client _inner;

  /// Wraps [inner] so the chain reads the same way in main.dart whether or not
  /// this layer is present.
  static http.Client wrap(http.Client inner) => RecordingTap(inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final cap = RecordingCapture.instance;
    // §6 — the no-session path, in full. One field read, then the real client.
    if (!cap.active) return _inner.send(request);
    return cap.observe(request, _inner);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

/// One observed step, before the backend has been told about it.
@immutable
class RecordedEvent {
  const RecordedEvent({
    required this.kind,
    required this.screen,
    required this.action,
    required this.ok,
    this.detail = const <String, dynamic>{},
  });

  final String kind;
  final String screen;
  final String action;
  final bool ok;
  final Map<String, dynamic> detail;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'screen': screen,
        'action': action,
        'ok': ok,
        'detail': detail,
      };
}

/// The buffer and the flush. Holds no opinion about what a step means.
class RecordingCapture {
  RecordingCapture._();

  static final RecordingCapture instance = RecordingCapture._();

  // ── what the backend last said ────────────────────────────────────────────
  int? _recordingId;
  int _flushMs = 1500;
  int _maxBatch = 25;
  int _maxBody = 16384;
  List<String> _skipFns = const <String>[];

  /// The backend's own step count, verbatim. -1 until a reply has landed.
  final ValueNotifier<Map<String, dynamic>> state =
      ValueNotifier<Map<String, dynamic>>(const <String, dynamic>{'on': false});

  final List<RecordedEvent> _queue = <RecordedEvent>[];
  Timer? _flushTimer;
  bool _flushing = false;

  /// Everything the tap needs to reach PostgREST, learned from the last request
  /// that went through it. Never assembled from config: whatever the Supabase
  /// client is sending today (apikey, Authorization, the test-session header)
  /// is what the flush sends too.
  Uri? _rpcBase;
  Map<String, String> _headers = const <String, String>{};

  bool get active => _recordingId != null;
  int? get recordingId => _recordingId;
  int get pending => _queue.length;

  /// Listens to the banner every screen already polls. Called once, from
  /// main.dart, after Supabase is up.
  void bind() {
    TestSessionState.instance.banner.addListener(_onBanner);
    _onBanner();
  }

  void _onBanner() {
    final raw = TestSessionState.instance.banner.value['recording'];
    applyState(raw is Map ? Map<String, dynamic>.from(raw) : const {'on': false});
  }

  /// Absorbs `recording_state()` verbatim. This is the only thing that turns
  /// the tap on or off — the app never decides it has finished recording.
  @visibleForTesting
  void applyState(Map<String, dynamic> payload) {
    final wasOn = active;
    final on = payload['on'] == true;
    final id = payload['recording_id'];
    _recordingId = on && id is int ? id : (on && id is num ? id.toInt() : null);
    final cap = payload['capture'];
    if (cap is Map) {
      _flushMs = _int(cap['flush_ms'], _flushMs);
      _maxBatch = _int(cap['max_batch'], _maxBatch);
      _maxBody = _int(cap['max_body'], _maxBody);
      final skip = cap['skip_fns'];
      if (skip is List) {
        _skipFns = skip.map((e) => '$e').toList(growable: false);
      }
    }
    state.value = payload;
    if (!active) {
      _queue.clear();
      _flushTimer?.cancel();
      _flushTimer = null;
      if (wasOn) SessionRecorder.instance.stop();
      return;
    }
    if (!wasOn) {
      // The route pushes and the RenderLog writes the app already announces
      // become steps in the same stream, through the observer main.dart has
      // registered since #638.
      SessionRecorder.instance.start(_recordingId!, _fromRecorder);
    }
  }

  Future<void> _fromRecorder({
    required String kind,
    required String screen,
    required String action,
    required bool ok,
  }) async {
    note(kind: kind, screen: screen, action: action, ok: ok);
  }

  /// One observed step. Never throws: a recorder that can break the screen it
  /// is watching is worse than no recorder.
  void note({
    required String kind,
    required String screen,
    required String action,
    bool ok = true,
    Map<String, dynamic> detail = const <String, dynamic>{},
  }) {
    if (!active) return;
    _queue.add(RecordedEvent(
        kind: kind, screen: screen, action: action, ok: ok, detail: detail));
    if (_queue.length >= _maxBatch) {
      unawaited(flush());
    } else {
      _flushTimer ??= Timer(Duration(milliseconds: _flushMs), () {
        _flushTimer = null;
        unawaited(flush());
      });
    }
  }

  /// PURE. The function name in a PostgREST rpc URL, or '' when the request is
  /// not an rpc call at all.
  @visibleForTesting
  static String rpcName(Uri url) {
    final segs = url.pathSegments;
    final i = segs.indexOf('rpc');
    if (i < 0 || i + 1 >= segs.length) return '';
    return segs[i + 1];
  }

  /// PURE. Whether this function is one the backend said never to record.
  @visibleForTesting
  bool skips(String fn) => fn.isEmpty || _skipFns.contains(fn);

  /// PURE. The body kept for a step: the parsed JSON when it fits inside the
  /// backend's cap, and its size when it does not. Never a partial parse.
  @visibleForTesting
  dynamic keptBody(String body) {
    if (body.isEmpty) return null;
    if (body.length > _maxBody) {
      return <String, dynamic>{'oversize_bytes': body.length};
    }
    try {
      return jsonDecode(body);
    } catch (_) {
      return body;
    }
  }

  /// Runs the real request, keeps what it answered, and hands the caller a
  /// response that reads exactly as it would have.
  Future<http.StreamedResponse> observe(
      http.BaseRequest request, http.Client inner) async {
    _remember(request);
    final fn = rpcName(request.url);
    if (skips(fn) || request.method != 'POST') return inner.send(request);

    String args = '';
    if (request is http.Request) args = request.body;

    final started = DateTime.now();
    final res = await inner.send(request);
    final bytes = await res.stream.toBytes();
    final replay = http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      res.statusCode,
      contentLength: res.contentLength,
      request: res.request,
      headers: res.headers,
      isRedirect: res.isRedirect,
      persistentConnection: res.persistentConnection,
      reasonPhrase: res.reasonPhrase,
    );
    try {
      note(
        kind: 'rpc',
        screen: fn,
        action: 'called $fn',
        ok: res.statusCode >= 200 && res.statusCode < 300,
        detail: <String, dynamic>{
          'fn': fn,
          'args': keptBody(args) ?? const <String, dynamic>{},
          'payload': keptBody(utf8.decode(bytes, allowMalformed: true)),
          'status': res.statusCode,
          'ms': DateTime.now().difference(started).inMilliseconds,
        },
      );
    } catch (_) {
      // A dropped step is never worth breaking the walkthrough over.
    }
    return replay;
  }

  void _remember(http.BaseRequest request) {
    final segs = request.url.pathSegments;
    final i = segs.indexOf('rpc');
    if (i < 1) return;
    _rpcBase = request.url.replace(
      pathSegments: segs.sublist(0, i + 1),
      queryParameters: const <String, String>{},
    );
    final h = Map<String, String>.from(request.headers);
    h['Content-Type'] = 'application/json';
    h.remove('content-length');
    h.remove('Content-Length');
    _headers = h;
  }

  /// Hands the buffer to the backend in one call. Uses the INNER client, so a
  /// flush can never observe itself.
  Future<void> flush({http.Client? using}) async {
    if (_flushing || _queue.isEmpty) return;
    final base = _rpcBase;
    final id = _recordingId;
    if (base == null || id == null) return;
    _flushing = true;
    final batch = _queue.take(_maxBatch).toList(growable: false);
    try {
      final client = using ?? _flushClient;
      if (client == null) return;
      final res = await client.post(
        base.replace(pathSegments: [...base.pathSegments, 'recording_capture']),
        headers: _headers,
        body: jsonEncode(<String, dynamic>{
          'p_events': batch.map((e) => e.toJson()).toList(),
          'p_recording': id,
        }),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        _queue.removeRange(0, batch.length);
        final body = jsonDecode(res.body);
        if (body is Map && body['recording'] == false) {
          // The backend says this install is no longer recording. It is the
          // only thing allowed to say so.
          _recordingId = null;
          _queue.clear();
          SessionRecorder.instance.stop();
        }
      }
    } catch (_) {
      // Keep the batch; the next flush carries it.
    } finally {
      _flushing = false;
      if (_queue.isNotEmpty && active) {
        _flushTimer ??= Timer(Duration(milliseconds: _flushMs), () {
          _flushTimer = null;
          unawaited(flush());
        });
      }
    }
  }

  http.Client? _flushClient;

  /// main.dart hands over the client BELOW the tap, so the flush bypasses it.
  void useFlushClient(http.Client client) => _flushClient = client;

  static int _int(dynamic v, int fallback) =>
      v is num ? v.toInt() : (int.tryParse('$v') ?? fallback);

  @visibleForTesting
  void debugReset() {
    _recordingId = null;
    _queue.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    _skipFns = const <String>[];
    state.value = const <String, dynamic>{'on': false};
  }

  @visibleForTesting
  List<RecordedEvent> get debugQueue => List<RecordedEvent>.unmodifiable(_queue);
}
