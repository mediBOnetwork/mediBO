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
    return path;
  }

  // ── #115: Insert one mention row per returned mention ─────────────────────
  Future<void> insertMentions({
    required List<Map<dynamic, dynamic>> mentions,
    required String supplierName,
    required String clipPath,
    required int recordingSeq,
    required List<Map<String, dynamic>> orderItems,
  }) async {
    if (mentions.isEmpty) return;

    // Build product_name → product_id lookup from current order
    final nameToId = <String, int>{};
    for (final item in orderItems) {
      final name = item['product_name']?.toString();
      final id = item['product_id'] ?? item['id'];
      if (name != null && id != null) {
        nameToId[name.toLowerCase()] = (id as num).toInt();
      }
    }

    final rows = mentions.map((m) {
      final name = m['matched_name']?.toString() ?? '';
      final id = nameToId[name.toLowerCase()];
      return {
        'supplier_name': supplierName,
        'recording_seq': recordingSeq,
        'clip_path': clipPath,
        'ord': (m['ord'] as num?)?.toInt() ?? 0,
        'matched_name': name,
        'qty': (m['qty'] as num?)?.toInt() ?? 0,
        't_start_sec': (m['t_start'] as num?)?.toDouble(),
        't_end_sec': (m['t_end'] as num?)?.toDouble(),
        if (id != null) 'product_id': id,
      };
    }).toList();

    await Supabase.instance.client.from('voice_clip_mentions').insert(rows);
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
        'min_confidence': 0.55,
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
