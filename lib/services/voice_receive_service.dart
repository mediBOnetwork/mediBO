import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  Future<bool> hasPermission() => _rec.hasPermission();

  Future<void> start() async {
    if (!await _rec.hasPermission()) throw MicPermissionException();
    await _rec.start(
      const RecordConfig(encoder: AudioEncoder.opus),
      path: '',
    );
    _mime = 'audio/webm;codecs=opus';
    _started = true;
  }

  Future<({Uint8List bytes, String mime})?> stop() async {
    _started = false;
    final path = await _rec.stop();
    if (path == null || path.isEmpty) return null;
    try {
      final response = await http.get(Uri.parse(path));
      if (response.statusCode != 200) {
        throw VoiceReceiveException('Failed to read recorded audio (${response.statusCode})');
      }
      return (bytes: response.bodyBytes, mime: _mime);
    } catch (e) {
      if (e is VoiceReceiveException) rethrow;
      throw VoiceReceiveException('Failed to read audio blob: $e');
    }
  }

  /// [expected] = [{name, ordered_qty, unit?}] from the open order.
  /// When provided the edge function returns reconciliation-mode items with a `status` field.
  Future<({List<Map<dynamic, dynamic>> items, String transcript})> transcribe(
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
      },
    );
    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw VoiceReceiveException(data['error'].toString());
    }
    final items = (data['items'] as List?)?.cast<Map>() ?? const <Map>[];
    final transcript = (data['transcript'] ?? '').toString();
    return (items: items, transcript: transcript);
  }

  Future<void> cancel() async {
    _started = false;
    try {
      await _rec.cancel();
    } catch (_) {}
  }

  Future<void> dispose() => _rec.dispose();
}
