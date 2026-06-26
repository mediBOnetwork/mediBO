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
      default:
        return 'Could not send. Please try again.';
    }
  }
}

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
      body: {'to': to, 'text': text},
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
}
