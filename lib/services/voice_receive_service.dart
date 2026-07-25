import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/render_log.dart';

class MicPermissionException implements Exception {
  final String message;
  MicPermissionException([this.message = 'Microphone permission denied']);
  @override
  String toString() => message;
}

class VoiceReceiveException implements Exception {
  final String message;
  VoiceReceiveException(this.message);
  @override
  String toString() => message;
}

class VoiceReceiveService {
  final _rec = AudioRecorder();
  String _mime = 'audio/webm;codecs=opus';
  bool _started = false;

  bool get wasStarted => _started;

  // Extension matching the actual recorded format per platform.
  String get _ext => kIsWeb ? 'webm' : 'm4a';

  /// Calls hasPermission() to confirm the plugin channel is registered on this platform.
  Future<bool> probe() => _rec.hasPermission();

  Future<bool> hasPermission() => _rec.hasPermission();

  Future<void> start() async {
    if (!await _rec.hasPermission()) throw MicPermissionException();
    if (kIsWeb) {
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.opus),
        path: '',
      );
      _mime = 'audio/webm;codecs=opus';
    } else {
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: '',
      );
      _mime = 'audio/mp4';
    }
    _started = true;
  }

  Future<({Uint8List bytes, String mime, String ext})?> stop() async {
    _started = false;
    final path = await _rec.stop();
    if (path == null || path.isEmpty) return null;
    try {
      final response = await http.get(Uri.parse(path));
      if (response.statusCode != 200) {
        throw VoiceReceiveException('Failed to read recorded audio (${response.statusCode})');
      }
      return (bytes: response.bodyBytes, mime: _mime, ext: _ext);
    } catch (e) {
      if (e is VoiceReceiveException) rethrow;
      throw VoiceReceiveException('Failed to read audio blob: $e');
    }
  }

  // ── #115: Upload clip to "voice-clips" bucket ─────────────────────────────
  // Returns the storage path on success; throws on failure (caller should catch).
  Future<String> uploadClip(
    Uint8List bytes,
    String supplierName,
    int recordingSeq,
    String ext,
  ) async {
    final slug = supplierName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+$'), '');
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final path = '$today/$slug/$recordingSeq.$ext';
    final mimeForUpload = ext == 'webm' ? 'audio/webm' : 'audio/mp4';
    await Supabase.instance.client.storage.from('voice-clips').uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(contentType: mimeForUpload, upsert: true),
    );
    RenderLog.write('c115_clip_uploaded',
        'platform=${kIsWeb ? 'web' : 'native'};supplier=$supplierName;seq=$recordingSeq;path=$path;ext=$ext;mime=$mimeForUpload');
    final tail = path.length >= 8 ? path.substring(path.length - 8) : path;
    RenderLog.write('c125_clip_uploaded', 'seq=$recordingSeq;path_tail=$tail;upsert=y;http_ok=y');
    return path;
  }

  // ── #115: Insert one mention row per returned mention ─────────────────────
  // stage is required (not defaulted) — voice_clip_mentions.stage drives bag attribution
  // in voice_finalize_session, so callers must pass the actual counting stage ('shop' or
  // 'warehouse') rather than relying on the table's historical 'shop' default.
  Future<void> insertMentions({
    required List<Map<dynamic, dynamic>> mentions,
    required String supplierName,
    required String clipPath,
    required int recordingSeq,
    required List<Map<String, dynamic>> orderItems,
    required String stage,
    String? sessionKey,
  }) async {
    if (mentions.isEmpty) return;

    // fix(voice): resolve EVERY mention independently against the FULL,
    // unmodified order-item list — stateless per mention, never shrunk or
    // consumed after a match, so the same product can be matched again by a
    // later clip's repeat mention. Case-insensitive, trimmed exact match first.
    final nameToId = <String, int>{};
    for (final item in orderItems) {
      final name = item['product_name']?.toString().trim();
      final id = item['product_id'] ?? item['id'];
      if (name != null && name.isNotEmpty && id is num) {
        nameToId[name.toLowerCase()] = id.toInt();
      }
    }

    final rows = <Map<String, dynamic>>[];
    for (final m in mentions) {
      final rawName = m['matched_name']?.toString() ?? '';
      final name = rawName.trim();
      // Resolve on the raw heard name regardless of any not_on_order tag from
      // the model — that's just its own guess, not authoritative; an exact or
      // fuzzy order match here always wins.
      int? id = name.isNotEmpty ? nameToId[name.toLowerCase()] : null;
      if (id == null && name.isNotEmpty && name != 'not_on_order') {
        try {
          final matchRaw = await Supabase.instance.client.rpc('voice_match_product', params: {
            'p_supplier': supplierName,
            'p_text': name,
          });
          final matchRes = matchRaw is Map ? Map<String, dynamic>.from(matchRaw) : const {};
          if (matchRes['match'] == true) {
            id = (matchRes['product_id'] as num?)?.toInt();
          }
        } catch (_) {}
      }
      rows.add({
        'supplier_name': supplierName,
        'stage': stage,
        'recording_seq': recordingSeq,
        'clip_path': clipPath,
        'ord': (m['ord'] as num?)?.toInt() ?? 0,
        'matched_name': name,
        'qty': (m['qty'] as num?)?.toInt() ?? 0,
        't_start_sec': (m['t_start'] as num?)?.toDouble(),
        't_end_sec': (m['t_end'] as num?)?.toDouble(),
        if (id != null) 'product_id': id,
        if (sessionKey != null) 'session_key': sessionKey,
      });
    }

    try {
      await Supabase.instance.client.from('voice_clip_mentions').insert(rows);
    } on PostgrestException catch (e) {
      // 23505 = unique_violation on (supplier_name, the_date, session_key, recording_seq,
      // ord): this exact window was already inserted by an earlier attempt (retry after a
      // network blip). The whole batch is a single statement, so a conflict here means the
      // whole window already landed — safe to treat as a no-op rather than fail the session.
      if (e.code != '23505') rethrow;
      RenderLog.write('c141_mention_retry_dup',
          'supplier=$supplierName;seq=$recordingSeq;rows=${rows.length}');
      return;
    }
    final hasTStart = rows.any((r) => r['t_start_sec'] != null);
    final hasTEnd = rows.any((r) => r['t_end_sec'] != null);
    RenderLog.write('c116_mention_inserted',
        'supplier=$supplierName;rows=${rows.length};has_tstart=${hasTStart ? 'y' : 'n'};has_tend=${hasTEnd ? 'y' : 'n'}');
  }

  /// [expected] = [{name, ordered_qty, unit?}] from the open order.
  /// v5+: response also includes "mentions" list per mention with t_start, ord.
  Future<({
    List<Map<dynamic, dynamic>> items,
    String transcript,
    int droppedNoQty,
    int droppedLowConf,
    List<Map<dynamic, dynamic>> mentions,
  })> transcribe(
    Uint8List bytes,
    String mime, {
    List<Map<String, dynamic>>? expected,
    double minConfidence = 0.55,
    // Windowed-session passthrough (voice-receive v25+): when windowOffsetSec is set, the
    // edge function shifts mention t_start/t_end onto the session clock before returning
    // them, so callers never duplicate that arithmetic. Omitting these reproduces the
    // legacy single-shot behavior exactly (clip-relative timestamps).
    String? sessionKey,
    int? recordingSeq,
    double? windowOffsetSec,
    String? stage,
  }) async {
    final b64 = base64Encode(bytes);
    if (b64.length > 6 * 1024 * 1024) {
      throw VoiceReceiveException('Clip too long — speak one item at a time');
    }
    final res = await Supabase.instance.client.functions.invoke(
      'voice-receive',
      body: {
        'audio_base64': b64,
        'mime_type': mime,
        if (expected != null && expected.isNotEmpty) 'expected': expected,
        'min_confidence': minConfidence,
        if (sessionKey != null) 'session_key': sessionKey,
        if (recordingSeq != null) 'recording_seq': recordingSeq,
        if (windowOffsetSec != null) 'window_offset_sec': windowOffsetSec,
        if (stage != null) 'stage': stage,
      },
    );
    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw VoiceReceiveException(data['error'].toString());
    }
    final items = (data['items'] as List?)?.cast<Map>() ?? const <Map>[];
    final mentions = (data['mentions'] as List?)?.cast<Map>() ?? const <Map>[];
    final transcript = (data['transcript'] ?? '').toString();
    final droppedNoQty = (data['dropped_no_qty'] as num?)?.toInt() ?? 0;
    final droppedLowConf = (data['dropped_low_conf'] as num?)?.toInt() ?? 0;
    RenderLog.write('c115_mentions_received',
        'supplier=?;count=${mentions.length};any_null_tstart=${mentions.any((m) => m['t_start'] == null) ? 'y' : 'n'}');
    return (
      items: items,
      transcript: transcript,
      droppedNoQty: droppedNoQty,
      droppedLowConf: droppedLowConf,
      mentions: mentions,
    );
  }

  Future<void> cancel() async {
    _started = false;
    try {
      await _rec.cancel();
    } catch (_) {}
  }

  Future<void> dispose() => _rec.dispose();
}

/// CHANGE #454: single key-format helper — one unique session_key per recording,
/// shared by every window's insert/write, the finalize call, and the badge/popup
/// scoping (#453). [entity] is the supplier name for Shop/Warehouse, the order id
/// for Pack. Never hardcode or reuse a key across recordings/suppliers/orders.
String newVoiceSessionKey(String entity, String stage) =>
    '$entity|$stage|${DateTime.now().millisecondsSinceEpoch}';

/// §3 of the continuous-voice-counting build spec: call right after a successful
/// bag_attach to mark the session-clock moment that bag became the owning bag. Never call
/// on detach — only a successful map defines ownership.
Future<void> recordVoiceBagBoundary({
  required String sessionKey,
  required String supplierName,
  required int bagNo,
  required double mappedAtSec,
}) async {
  await Supabase.instance.client.from('voice_bag_boundaries').insert({
    'session_key': sessionKey,
    'supplier_name': supplierName,
    'bag_no': bagNo,
    'mapped_at_sec': mappedAtSec,
  });
  RenderLog.write('c142_bag_boundary_mapped',
      'supplier=$supplierName;bag=$bagNo;t=${mappedAtSec.toStringAsFixed(1)}');
}

/// §6 of the continuous-voice-counting build spec: run once on stop (safe to re-run).
/// Returns the finalize summary jsonb (persisted totals, bag_breakdown, unmatched_mentions,
/// needs_bag_review) for the caller to surface to the admin.
Future<Map<String, dynamic>> finalizeVoiceSession(String sessionKey, {String? dateYmd}) async {
  final res = await Supabase.instance.client.rpc('voice_finalize_session', params: {
    'p_session_key': sessionKey,
    if (dateYmd != null) 'p_date': dateYmd,
  });
  final data = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
  if (data['error'] != null) {
    throw VoiceReceiveException(data['error'].toString());
  }
  RenderLog.write('c143_session_finalized',
      'session=$sessionKey;persisted=${(data['persisted'] as List?)?.length ?? 0};'
      'needs_review=${(data['needs_bag_review'] as List?)?.length ?? 0};'
      'unmatched=${(data['unmatched_mentions'] as List?)?.length ?? 0}');
  return data;
}

/// One continuous counting session for one supplier at one stage (§1-§2 of the build spec).
///
/// The `record` plugin has no API to read a partial in-progress recording, so this does NOT
/// implement true overlapping capture (spec's WINDOW=30s/OVERLAP=6s two-stream design).
/// Instead it records back-to-back NON-overlapping ~[windowSec]-second clips: stop the
/// current clip and immediately start the next one, dispatching the closed clip in the
/// background. The restart happens in-process in well under a second, so from the worker's
/// perspective recording never stops — no stop-and-wait per bag, and every clip Gemini sees
/// is short. What's lost versus the spec's design is the overlap-based tolerance for an
/// utterance spoken across a window boundary; the backend's overlap-seam dedup logic is
/// still applied (harmlessly a no-op here since windows don't actually overlap).
class ContinuousVoiceSession {
  final String supplierName;
  final String stage; // 'warehouse' | 'shop'
  // 'YYYY-MM-DD' — the Fulfill date being counted (FulfillDateScope.instance.date),
  // forwarded to voice_finalize_session so counts save against the date the admin
  // is actually viewing, not the server's "today".
  final String dateYmd;
  final List<Map<String, dynamic>> Function() orderItemsProvider;
  final List<Map<String, dynamic>> Function()? expectedProvider;
  final void Function(Object error, StackTrace st)? onWindowError;
  // Fired after each window's clip is uploaded (path, actual recorded seconds for that
  // window, 0-based recording_seq) — wire this to the caller's usage-ledger/daily-cap
  // registration (e.g. _VoiceCaps.onClipSaved), since without a per-window hook a long
  // continuous session would never register against a server-side usage cap.
  final void Function(String path, int seconds, int recordingSeq)? onClipUploaded;
  static const int windowSec = 24;

  final String sessionKey;
  final VoiceReceiveService _svc = VoiceReceiveService();
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  int _nextSeq = 0;
  bool _stopping = false;
  Future<void>? _activeRotation;
  final List<Future<void>> _inFlight = [];
  // True elapsed-sec at which the CURRENT recording window began — captured from the same
  // Stopwatch that recordBagMap() reads, not derived as seq*windowSec. Each stop+restart
  // cycle costs real wall-clock time (network/plugin overhead), so an idealized seq*windowSec
  // offset would drift further from the boundaries' real timestamps as the session goes on,
  // corrupting bag attribution on long sessions. Measuring both off one clock keeps them exact.
  double _windowStartSec = 0.0;

  ContinuousVoiceSession({
    required this.supplierName,
    required this.stage,
    required this.dateYmd,
    required this.orderItemsProvider,
    this.expectedProvider,
    this.onWindowError,
    this.onClipUploaded,
  }) : sessionKey = '$supplierName|$stage|${DateTime.now().millisecondsSinceEpoch}';

  double get elapsedSec => _clock.elapsedMilliseconds / 1000.0;

  Future<void> start() async {
    await _svc.start();
    _clock.start();
    _windowStartSec = 0.0;
    _timer = Timer.periodic(const Duration(seconds: windowSec), (_) => _rotate());
  }

  Future<void> _rotate() {
    if (_stopping) return Future.value();
    final done = Completer<void>();
    _activeRotation = done.future;
    () async {
      final seq = _nextSeq++;
      final offset = _windowStartSec;
      final clip = await _svc.stop();
      final windowEndSec = elapsedSec;
      // If stopAndFinalize raced us and set _stopping while we were mid-stop, don't restart
      // the recorder — but the clip we already captured is real audio and must still be
      // dispatched; stopAndFinalize awaits _activeRotation instead of stopping again.
      if (!_stopping) {
        await _svc.start();
        _windowStartSec = elapsedSec; // true start of the NEXT window
      }
      if (clip == null) return;
      final durationSec = (windowEndSec - offset).round().clamp(1, 3600);
      final fut = _dispatch(clip.bytes, clip.mime, clip.ext, seq, offset, durationSec)
          .catchError((Object e, StackTrace st) => onWindowError?.call(e, st));
      _inFlight.add(fut);
      unawaited(fut.whenComplete(() => _inFlight.remove(fut)));
    }()
        .whenComplete(() {
      _activeRotation = null;
      done.complete();
    });
    return done.future;
  }

  Future<void> _dispatch(Uint8List bytes, String mime, String ext, int seq, double offsetSec, int durationSec) async {
    final clipPath = await _svc.uploadClip(bytes, supplierName, seq, ext);
    onClipUploaded?.call(clipPath, durationSec, seq);
    final result = await _svc.transcribe(
      bytes, mime,
      expected: expectedProvider?.call(),
      sessionKey: sessionKey,
      recordingSeq: seq,
      windowOffsetSec: offsetSec,
      stage: stage,
    );
    await _svc.insertMentions(
      mentions: result.mentions,
      supplierName: supplierName,
      clipPath: clipPath,
      recordingSeq: seq,
      orderItems: orderItemsProvider(),
      sessionKey: sessionKey,
      stage: stage,
    );
  }

  /// Marks the moment [bagNo] became the owning bag on this session's clock. Call only
  /// after a successful bag_attach — never on detach (§3 of the build spec).
  Future<void> recordBagMap(int bagNo) => recordVoiceBagBoundary(
        sessionKey: sessionKey,
        supplierName: supplierName,
        bagNo: bagNo,
        mappedAtSec: elapsedSec,
      );

  /// Stops recording, waits for every in-flight window to finish uploading/inserting, then
  /// runs voice_finalize_session and returns its summary. Safe to call once per session.
  Future<Map<String, dynamic>> stopAndFinalize() async {
    _stopping = true;
    _timer?.cancel();
    if (_activeRotation != null) {
      // A rotation was already mid-stop when we hit Stop; it will capture + dispatch the
      // final clip itself (and skip its restart, since _stopping is now true) — wait for it
      // rather than racing a second stop() call on the same recorder.
      await _activeRotation;
    } else if (_svc.wasStarted) {
      final seq = _nextSeq++;
      final offset = _windowStartSec;
      final windowEndSec = elapsedSec;
      final clip = await _svc.stop();
      if (clip != null) {
        final durationSec = (windowEndSec - offset).round().clamp(1, 3600);
        _inFlight.add(_dispatch(clip.bytes, clip.mime, clip.ext, seq, offset, durationSec)
            .catchError((Object e, StackTrace st) => onWindowError?.call(e, st)));
      }
    }
    _clock.stop();
    await Future.wait(List<Future<void>>.of(_inFlight));
    return finalizeVoiceSession(sessionKey, dateYmd: dateYmd);
  }

  /// Aborts the session without finalizing (e.g. the admin backs out mid-count). Any windows
  /// already dispatched remain in voice_clip_mentions, unattributed, for manual cleanup.
  Future<void> cancel() async {
    _stopping = true;
    _timer?.cancel();
    await _svc.cancel();
    _clock.stop();
  }
}

/// CHANGE #454: run once on Pack Stop (safe to re-run) — Pack's counterpart to
/// finalizeVoiceSession. order_id is derived server-side from the session's own
/// pack_clip_mentions rows, so only the session key is needed here.
Future<Map<String, dynamic>> finalizePackSession(String sessionKey) async {
  final res = await Supabase.instance.client.rpc('pack_finalize_session', params: {
    'p_session_key': sessionKey,
  });
  final data = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
  if (data['error'] != null) {
    throw VoiceReceiveException(data['error'].toString());
  }
  RenderLog.write('c454_pack_session_finalized',
      'session=$sessionKey;persisted=${(data['persisted'] as List?)?.length ?? 0};'
      'unmatched=${(data['unmatched_mentions'] as List?)?.length ?? 0}');
  return data;
}

/// CHANGE #454: Pack's continuous counting session — the SAME windowed-chunk
/// recording engine as ContinuousVoiceSession (record ~[windowSec]s, rotate,
/// dispatch the closed clip in the background, never stop the mic from the
/// worker's perspective), minus the bag-boundary layer (Pack has no bags) and
/// wired to Pack's own per-window write RPC (pack_write_session_mentions) +
/// finalizer (pack_finalize_session) instead of voice_clip_mentions /
/// voice_finalize_session. Does not touch ContinuousVoiceSession or any
/// Shop/Warehouse code path — a separate class so Warehouse/Shop behavior is
/// provably unchanged.
class PackVoiceSession {
  final String orderId;
  final List<Map<String, dynamic>> Function() orderItemsProvider;
  final List<Map<String, dynamic>> Function()? expectedProvider;
  // Pack's own fuzzy product-name resolver (order-scoped Levenshtein/Jaccard
  // match against orderItemsProvider()) — unchanged from the pre-#454 single-shot
  // flow; voice_match_product (Shop/Warehouse's supplier-catalog RPC fallback) is
  // deliberately not used here, matching prior Pack behavior exactly.
  final int? Function(String spoken, List<Map<String, dynamic>> items) resolveProductId;
  final String? Function(int productId, List<Map<String, dynamic>> items) resolveProductName;
  final void Function(Object error, StackTrace st)? onWindowError;
  final void Function(String path, int seconds, int recordingSeq)? onClipUploaded;
  static const int windowSec = 24;

  final String sessionKey;
  final VoiceReceiveService _svc = VoiceReceiveService();
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  int _nextSeq = 0;
  bool _stopping = false;
  Future<void>? _activeRotation;
  final List<Future<void>> _inFlight = [];
  double _windowStartSec = 0.0;

  PackVoiceSession({
    required this.orderId,
    required this.orderItemsProvider,
    required this.resolveProductId,
    required this.resolveProductName,
    this.expectedProvider,
    this.onWindowError,
    this.onClipUploaded,
  }) : sessionKey = newVoiceSessionKey(orderId, 'pack');

  double get elapsedSec => _clock.elapsedMilliseconds / 1000.0;

  Future<void> start() async {
    await _svc.start();
    _clock.start();
    _windowStartSec = 0.0;
    _timer = Timer.periodic(const Duration(seconds: windowSec), (_) => _rotate());
  }

  Future<void> _rotate() {
    if (_stopping) return Future.value();
    final done = Completer<void>();
    _activeRotation = done.future;
    () async {
      final seq = _nextSeq++;
      final offset = _windowStartSec;
      final clip = await _svc.stop();
      final windowEndSec = elapsedSec;
      // Same race guard as ContinuousVoiceSession._rotate: if stopAndFinalize raced us
      // mid-stop, don't restart the recorder, but still dispatch the clip we captured.
      if (!_stopping) {
        await _svc.start();
        _windowStartSec = elapsedSec;
      }
      if (clip == null) return;
      final durationSec = (windowEndSec - offset).round().clamp(1, 3600);
      final fut = _dispatch(clip.bytes, clip.mime, clip.ext, seq, offset, durationSec)
          .catchError((Object e, StackTrace st) => onWindowError?.call(e, st));
      _inFlight.add(fut);
      unawaited(fut.whenComplete(() => _inFlight.remove(fut)));
    }()
        .whenComplete(() {
      _activeRotation = null;
      done.complete();
    });
    return done.future;
  }

  Future<void> _dispatch(Uint8List bytes, String mime, String ext, int seq, double offsetSec, int durationSec) async {
    final clipPath = await _svc.uploadClip(bytes, orderId, seq, ext);
    onClipUploaded?.call(clipPath, durationSec, seq);
    final result = await _svc.transcribe(
      bytes, mime,
      expected: expectedProvider?.call(),
      minConfidence: 0.85, // CHANGE #304: Pack's higher confidence bar, preserved
      sessionKey: sessionKey,
      recordingSeq: seq,
      windowOffsetSec: offsetSec,
      stage: 'pack',
    );
    if (result.mentions.isEmpty) return;
    final items = orderItemsProvider();
    final mentionsPayload = <Map<String, dynamic>>[];
    for (final m in result.mentions) {
      final rawName = m['matched_name']?.toString() ?? '';
      final name = rawName.trim();
      final pid = (name.isNotEmpty && name != 'not_on_order')
          ? resolveProductId(name, items)
          : null;
      final resolvedName = pid != null ? (resolveProductName(pid, items) ?? name) : name;
      mentionsPayload.add({
        'product_id': pid,
        'matched_name': resolvedName,
        'qty': (m['qty'] as num?)?.toDouble() ?? 0.0,
        't_start': m['t_start'],
        't_end': m['t_end'],
        'ord': (m['ord'] as num?)?.toInt() ?? 0,
      });
    }
    if (mentionsPayload.isEmpty) return;
    await Supabase.instance.client.rpc('pack_write_session_mentions', params: {
      'p_order_id': orderId,
      'p_session_key': sessionKey,
      'p_recording_seq': seq,
      'p_clip_path': clipPath,
      'p_mentions': mentionsPayload,
    });
  }

  /// Stops recording, waits for every in-flight window to finish uploading/writing, then
  /// runs pack_finalize_session and returns its summary. Safe to call once per session.
  Future<Map<String, dynamic>> stopAndFinalize() async {
    _stopping = true;
    _timer?.cancel();
    if (_activeRotation != null) {
      await _activeRotation;
    } else if (_svc.wasStarted) {
      final seq = _nextSeq++;
      final offset = _windowStartSec;
      final windowEndSec = elapsedSec;
      final clip = await _svc.stop();
      if (clip != null) {
        final durationSec = (windowEndSec - offset).round().clamp(1, 3600);
        _inFlight.add(_dispatch(clip.bytes, clip.mime, clip.ext, seq, offset, durationSec)
            .catchError((Object e, StackTrace st) => onWindowError?.call(e, st)));
      }
    }
    _clock.stop();
    await Future.wait(List<Future<void>>.of(_inFlight));
    return finalizePackSession(sessionKey);
  }

  /// Aborts the session without finalizing. Any windows already dispatched remain in
  /// pack_clip_mentions, unattributed to a completed session, for manual cleanup.
  Future<void> cancel() async {
    _stopping = true;
    _timer?.cancel();
    await _svc.cancel();
    _clock.stop();
  }
}
