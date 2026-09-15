// lib/services/resilient_http.dart — CHANGE #1149
//
// The app must never hang on a spinner because the backend blinked. Every
// runner's DDL made PostgREST reload its schema cache (~1 min of 503/PGRST002
// per reload; 4,513 of them in one ten-minute window on 3 Sep), and every
// screen that fetched during that minute sat on a spinner or threw.
//
// ONE layer fixes all of them at once: an http.Client that the Supabase SDK
// sends every request through. It remembers the last successful body of each
// REST request (GET rows, POST /rpc/*) and, when the same request answers
// 502/503/504 or times out, hands the SDK that last body back instead — with an
// `x-medibo-cached: 1` header so a caller that cares can tell — and raises the
// Reconnecting flag the banner listens to. A later 2xx clears the flag, and a
// backoff probe clears it sooner. Nothing here decides what a screen shows: the
// cached bytes are the backend's own last answer, byte for byte.
//
// What is NOT cached: auth, storage, realtime, and anything that is not a
// PostgREST read or RPC. A cached body is only ever served in place of a
// FAILURE — a healthy backend is always asked.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// The one flag every surface reads: is the backend answering right now?
class Reconnecting extends ChangeNotifier {
  Reconnecting._();
  static final Reconnecting instance = Reconnecting._();

  bool _down = false;
  String _reason = '';
  int _downCount = 0;
  int _servedFromCache = 0;

  bool get down => _down;
  String get reason => _reason;
  int get downCount => _downCount;
  int get servedFromCache => _servedFromCache;

  void markDown(String reason) {
    _downCount++;
    if (_down && _reason == reason) return;
    _down = true;
    _reason = reason;
    notifyListeners();
  }

  void markUp() {
    if (!_down) return;
    _down = false;
    _reason = '';
    notifyListeners();
  }

  void _served() => _servedFromCache++;

  @visibleForTesting
  void reset() {
    _down = false;
    _reason = '';
    _downCount = 0;
    _servedFromCache = 0;
  }
}

class _Entry {
  _Entry(this.bytes, this.headers);
  final Uint8List bytes;
  final Map<String, String> headers;
}

class ResilientClient extends http.BaseClient {
  ResilientClient(
    this._inner, {
    this.timeout = const Duration(seconds: 20),
    this.probeUri,
    this.probeHeaders = const {},
    this.maxEntries = 400,
    this.maxEntryBytes = 512 * 1024,
    this.persistBelowBytes = 64 * 1024,
    this.persist = true,
  });

  final http.Client _inner;
  final Duration timeout;

  /// A cheap endpoint the backoff probe hits to learn the backend is back.
  final Uri? probeUri;
  final Map<String, String> probeHeaders;

  final int maxEntries;
  final int maxEntryBytes;
  final int persistBelowBytes;
  final bool persist;

  final LinkedHashMap<String, _Entry> _mem = LinkedHashMap();
  Timer? _probe;
  int _backoffS = 2;

  static const _prefsPrefix = 'rc:';
  static const cachedHeader = 'x-medibo-cached';

  /// Only PostgREST reads and RPC calls are remembered.
  static bool cacheable(http.BaseRequest r) {
    final p = r.url.path;
    if (!p.contains('/rest/v1/')) return false;
    if (r.method == 'GET') return true;
    if (r.method == 'POST' && p.contains('/rest/v1/rpc/')) return true;
    return false;
  }

  static bool _isOutage(int status) =>
      status == 502 || status == 503 || status == 504;

  static String _key(http.BaseRequest r) {
    final body = r is http.Request ? r.body : '';
    // The Prefer/Range/Accept headers change the shape of a PostgREST answer;
    // the auth header changes WHOSE answer it is. Both belong in the key.
    final auth = r.headers['Authorization'] ?? r.headers['authorization'] ?? '';
    final shape = [
      r.headers['Prefer'] ?? '',
      r.headers['Range'] ?? '',
      r.headers['Accept'] ?? '',
    ].join('|');
    return '${r.method} ${r.url}#${auth.hashCode}#${shape.hashCode}#${body.hashCode}';
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!cacheable(request)) return _inner.send(request);

    final key = _key(request);
    http.StreamedResponse resp;
    try {
      resp = await _inner.send(request).timeout(timeout);
    } on TimeoutException {
      return _fallback(key, 'timeout', 504, request);
    } on SocketException catch (e) {
      return _fallback(key, 'socket: ${e.message}', 503, request);
    } on http.ClientException catch (e) {
      return _fallback(key, 'client: ${e.message}', 503, request);
    }

    if (_isOutage(resp.statusCode)) {
      // Drain so the connection is released, then answer from memory if we can.
      try { await resp.stream.drain<void>(); } catch (_) {}
      return _fallback(key, 'http ${resp.statusCode}', resp.statusCode, request);
    }

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final bytes = await resp.stream.toBytes();
      _remember(key, bytes, resp.headers);
      Reconnecting.instance.markUp();
      _stopProbe();
      return http.StreamedResponse(
        http.ByteStream.fromBytes(bytes),
        resp.statusCode,
        contentLength: bytes.length,
        request: request,
        headers: resp.headers,
        reasonPhrase: resp.reasonPhrase,
      );
    }
    // 4xx and other 5xx are the backend's own answers (RLS refusals, bad
    // input, a real function error): passed through untouched, never cached.
    return resp;
  }

  Future<http.StreamedResponse> _fallback(
      String key, String reason, int status, http.BaseRequest request) async {
    Reconnecting.instance.markDown(reason);
    _startProbe();
    final hit = _mem[key] ?? await _fromPrefs(key);
    if (hit == null) {
      return http.StreamedResponse(
        http.ByteStream.fromBytes(utf8.encode(
            '{"message":"backend unavailable","hint":"reconnecting","code":"PGRST002"}')),
        status,
        request: request,
        headers: const {'content-type': 'application/json'},
        reasonPhrase: 'unavailable',
      );
    }
    Reconnecting.instance._served();
    return http.StreamedResponse(
      http.ByteStream.fromBytes(hit.bytes),
      200,
      contentLength: hit.bytes.length,
      request: request,
      headers: {...hit.headers, cachedHeader: '1'},
      reasonPhrase: 'OK (cached)',
    );
  }

  void _remember(String key, Uint8List bytes, Map<String, String> headers) {
    if (bytes.length > maxEntryBytes) return;
    final kept = <String, String>{};
    final ct = headers['content-type'];
    if (ct != null) kept['content-type'] = ct;
    final cr = headers['content-range'];
    if (cr != null) kept['content-range'] = cr;
    _mem.remove(key);
    _mem[key] = _Entry(bytes, kept);
    while (_mem.length > maxEntries) {
      _mem.remove(_mem.keys.first);
    }
    if (persist && bytes.length <= persistBelowBytes) {
      // Fire and forget — a cold boot during an outage still has a last answer.
      _toPrefs(key, bytes, kept);
    }
  }

  Future<void> _toPrefs(String key, Uint8List bytes, Map<String, String> h) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('$_prefsPrefix$key',
          jsonEncode({'b': base64Encode(bytes), 'h': h}));
    } catch (_) {}
  }

  Future<_Entry?> _fromPrefs(String key) async {
    if (!persist) return null;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('$_prefsPrefix$key');
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map;
      final e = _Entry(base64Decode(m['b'] as String),
          Map<String, String>.from(m['h'] as Map? ?? const {}));
      _mem[key] = e;
      return e;
    } catch (_) {
      return null;
    }
  }

  void _startProbe() {
    if (_probe != null || probeUri == null) return;
    _probe = Timer(Duration(seconds: _backoffS), () async {
      _probe = null;
      _backoffS = (_backoffS * 2).clamp(2, 30);
      try {
        final r = await _inner
            .get(probeUri!, headers: probeHeaders)
            .timeout(const Duration(seconds: 8));
        if (!_isOutage(r.statusCode)) {
          Reconnecting.instance.markUp();
          _backoffS = 2;
          return;
        }
      } catch (_) {}
      if (Reconnecting.instance.down) _startProbe();
    });
  }

  void _stopProbe() {
    _probe?.cancel();
    _probe = null;
    _backoffS = 2;
  }

  @visibleForTesting
  int get memoryEntries => _mem.length;

  @override
  void close() {
    _stopProbe();
    _inner.close();
  }
}
