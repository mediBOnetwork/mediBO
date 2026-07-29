// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Requests notification permission + retrieves the FCM token via the JS
/// bridge defined in index.html, then upserts it to admin_push_tokens.
///
/// The JS side (index.html) exposes:
///   window.fcmGetToken(callback)  — calls callback(token: string|null)
///
/// REQUIRES Firebase credentials to be filled in index.html and
/// firebase-messaging-sw.js before tokens are actually issued.

@JS('fcmGetToken')
external void _jsFcmGetToken(JSFunction callback);

class FcmService {
  static bool _initialised = false;

  static Future<void> init(String adminId) async {
    if (!kIsWeb || _initialised) return;
    _initialised = true;
    try {
      // Request permission + get FCM token from JS bridge
      final tokenFuture = Completer<String?>();
      _jsFcmGetToken(((JSAny? token) {
        final dartToken = token?.dartify() as String?;
        tokenFuture.complete(dartToken?.isEmpty == true ? null : dartToken);
      }).toJS);
      final token = await tokenFuture.future
          .timeout(const Duration(seconds: 15), onTimeout: () => null);

      if (token == null || token.isEmpty) return;
      await _storeToken(adminId, token);
    } catch (e) {
      // Firebase not configured yet — log and continue; app still works
      debugPrint('[FcmService] init failed (Firebase not configured?): $e');
    }
  }

  // CHANGE #581 — the client passed its own admin_id and a DEVICE-clock
  // updated_at. The server knows who is calling; adminId is no longer sent.
  static Future<void> _storeToken(String adminId, String token) async {
    try {
      await Supabase.instance.client.rpc('save_my_push_token',
          params: {'p_token': token, 'p_platform': 'web'});
    } catch (e) {
      debugPrint('[FcmService] token store failed: $e');
    }
  }

  /// Removes the current FCM token on sign-out.
  static Future<void> removeToken() async {
    if (!kIsWeb) return;
    try {
      final tokenFuture = Completer<String?>();
      _jsFcmGetToken(((JSAny? token) {
        final dartToken = token?.dartify() as String?;
        tokenFuture.complete(dartToken?.isEmpty == true ? null : dartToken);
      }).toJS);
      final token = await tokenFuture.future
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      if (token == null || token.isEmpty) return;
      await Supabase.instance.client
          .rpc('remove_my_push_token', params: {'p_token': token});
    } catch (_) {}
  }
}
