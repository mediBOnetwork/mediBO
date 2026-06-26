import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import '../models/wa_conversation.dart';
import '../models/wa_message.dart';

class WaSendException implements Exception {
  final String code;
  const WaSendException(this.code);

  String get humanMessage {
    switch (code) {
      case 'send_failed':
        return "Can't reply now — WhatsApp's 24-hour reply window has closed for this contact.";
      case 'not_authorized':
      case 'not_authenticated':
        return "You're not allowed to send (admin only).";
      case 'missing_to_or_text':
        return 'Message is empty.';
      case 'too_large':
        return 'File is too large to send.';
      case 'upload_failed':
        return 'Could not upload the file. Please try again.';
      case 'invalid_location':
        return 'Please enter a valid latitude and longitude.';
      case 'invalid_contact':
        return 'Please enter a contact name and phone number.';
      default:
        return 'Could not send. Please try again.';
    }
  }
}

/// Media category used for client-side size validation.
enum WaMediaCategory { image, audio, video, document }

/// WhatsApp outbound size limits (bytes).
/// image ~5 MB, audio ~16 MB, video ~16 MB, document up to ~100 MB.
const int _kImageMaxBytes = 5 * 1024 * 1024;
const int _kAudioMaxBytes = 16 * 1024 * 1024;
const int _kVideoMaxBytes = 16 * 1024 * 1024;
const int _kDocumentMaxBytes = 100 * 1024 * 1024;

class WaRepository {
  SupabaseClient get _client => Supabase.instance.client;

  Future<List<WaConversation>> listConversations(String? type) async {
    try {
      final res = await _client.rpc(
        'wa_conversations',
        params: {'p_type': type},
      );
      final List data = (res is List)
          ? res
          : (res is String ? (jsonDecode(res) as List) : const []);
      final conversations = data
          .whereType<Map>()
          .map((e) => WaConversation.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      RenderLog.write('c204_wa_conv_list', conversations.length);
      return conversations;
    } catch (e) {
      debugPrint('[WaRepository] listConversations error: $e');
      throw Exception('Could not load conversations');
    }
  }

  Future<List<WaMessage>> getThread(String phone) async {
    try {
      final res = await _client.rpc('wa_thread', params: {'p_phone': phone});
      final map = (res is String) ? jsonDecode(res) : res;
      if (map is Map && map['error'] != null) {
        throw Exception(map['error'].toString());
      }
      final List msgs = (map is Map && map['messages'] is List)
          ? map['messages'] as List
          : const [];
      final messages = msgs
          .whereType<Map>()
          .map((e) => WaMessage.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      RenderLog.write('c204_wa_thread_opened', messages.length);
      return messages;
    } catch (e) {
      debugPrint('[WaRepository] getThread error: $e');
      rethrow;
    }
  }

  Future<String> signedUrl(String bucket, String path) async {
    try {
      return await _client.storage.from(bucket).createSignedUrl(path, 3600);
    } catch (e) {
      debugPrint('[WaRepository] signedUrl error: $e');
      throw Exception('Could not load media');
    }
  }

  Future<Map<String, dynamic>> sendReply({
    required String to,
    required String text,
  }) async {
    final res = await _client.functions.invoke(
      'whatsapp-send',
      body: {'to': to, 'kind': 'text', 'text': text},
    );
    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw WaSendException(data['error'].toString());
    }
    if (data is Map && data['status'] == 'ok') {
      RenderLog.write('c204_wa_reply_sent', 1);
      return Map<String, dynamic>.from(data);
    }
    throw WaSendException('send_failed');
  }

  // ── CHANGE #205: outbound media / location / contact ──────────────────────

  /// Classify a file (by mime + extension) for size validation and WhatsApp
  /// routing. The edge function auto-detects the WhatsApp type from the mime,
  /// so we never pass `type` — we only use this to enforce size limits.
  static WaMediaCategory categorize(String mime, String ext) {
    final m = mime.toLowerCase();
    final e = ext.toLowerCase();
    if (m.startsWith('image/') ||
        ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp'].contains(e)) {
      return WaMediaCategory.image;
    }
    if (m.startsWith('audio/') ||
        ['mp3', 'ogg', 'opus', 'm4a', 'aac', 'wav', 'amr'].contains(e)) {
      return WaMediaCategory.audio;
    }
    if (m.startsWith('video/') ||
        ['mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'].contains(e)) {
      return WaMediaCategory.video;
    }
    return WaMediaCategory.document;
  }

  static int maxBytesFor(WaMediaCategory cat) {
    switch (cat) {
      case WaMediaCategory.image:
        return _kImageMaxBytes;
      case WaMediaCategory.audio:
        return _kAudioMaxBytes;
      case WaMediaCategory.video:
        return _kVideoMaxBytes;
      case WaMediaCategory.document:
        return _kDocumentMaxBytes;
    }
  }

  /// Validate size client-side. Throws [WaSendException]('too_large') if the
  /// file exceeds the per-category limit. Non-documents are capped at 16 MB;
  /// documents may be up to 100 MB.
  static void validateSize(int bytes, WaMediaCategory cat) {
    if (bytes > maxBytesFor(cat)) {
      throw const WaSendException('too_large');
    }
  }

  /// Upload bytes then send as a media message. Returns the send result and the
  /// storage path used (so the UI can render an optimistic bubble).
  Future<Map<String, dynamic>> sendMedia({
    required String to,
    required Uint8List bytes,
    required String fileName,
    required String mime,
    String caption = '',
  }) async {
    final ext = fileName.contains('.') ? fileName.split('.').last : 'bin';
    final cat = categorize(mime, ext);
    validateSize(bytes.length, cat);

    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = 'outgoing/${to}_$ts.$ext';
    const bucket = 'whatsapp-media';

    try {
      await _client.storage.from(bucket).uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: mime, upsert: true),
          );
    } catch (e) {
      debugPrint('[WaRepository] sendMedia upload error: $e');
      throw const WaSendException('upload_failed');
    }

    final res = await _client.functions.invoke(
      'whatsapp-send',
      body: {
        'to': to,
        'kind': 'media',
        'media_bucket': bucket,
        'media_path': path,
        'caption': caption,
      },
    );
    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw WaSendException(data['error'].toString());
    }
    if (data is Map && data['status'] == 'ok') {
      RenderLog.write('c205_wa_media_sent', 1);
      final out = Map<String, dynamic>.from(data);
      out['media_path'] = path;
      out['media_bucket'] = bucket;
      out['mime'] = mime;
      return out;
    }
    throw const WaSendException('send_failed');
  }

  Future<Map<String, dynamic>> sendLocation({
    required String to,
    required double latitude,
    required double longitude,
    String? name,
    String? address,
  }) async {
    final body = <String, dynamic>{
      'to': to,
      'kind': 'location',
      'latitude': latitude,
      'longitude': longitude,
    };
    if (name != null && name.trim().isNotEmpty) body['name'] = name.trim();
    if (address != null && address.trim().isNotEmpty) {
      body['address'] = address.trim();
    }
    final res = await _client.functions.invoke('whatsapp-send', body: body);
    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw WaSendException(data['error'].toString());
    }
    if (data is Map && data['status'] == 'ok') {
      RenderLog.write('c205_wa_location_sent', 1);
      return Map<String, dynamic>.from(data);
    }
    throw const WaSendException('send_failed');
  }

  Future<Map<String, dynamic>> sendContact({
    required String to,
    required String contactName,
    required String contactPhone,
  }) async {
    final digits = contactPhone.replaceAll(RegExp(r'\D'), '');
    if (contactName.trim().isEmpty || digits.isEmpty) {
      throw const WaSendException('invalid_contact');
    }
    final res = await _client.functions.invoke(
      'whatsapp-send',
      body: {
        'to': to,
        'kind': 'contact',
        'contact_name': contactName.trim(),
        'contact_phone': digits,
      },
    );
    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw WaSendException(data['error'].toString());
    }
    if (data is Map && data['status'] == 'ok') {
      RenderLog.write('c205_wa_contact_sent', 1);
      return Map<String, dynamic>.from(data);
    }
    throw const WaSendException('send_failed');
  }
}
