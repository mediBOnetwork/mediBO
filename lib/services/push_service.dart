// CHANGE #298 — PART 2 of the notification rebuild: FCM push.
//
// This file owns the whole device-token lifecycle and nothing else. It writes
// no display string, formats nothing and decides nothing about content: the
// title, body and destination of every notification are rendered by the
// backend (notif_push_send) and arrive on the message.
//
// Firebase is initialised from push_config_get(), NOT from a build-time
// google-services.json. The com.google.gms.google-services Gradle plugin
// hard-fails an Android build when that file is missing, which would block the
// release; FirebaseOptions carries exactly the same values and lets the
// backend repoint the app with no rebuild.
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

/// The route a notification wants opened, handed to the app's own navigator.
typedef PushOpen = void Function(String deepLink);

@pragma('vm:entry-point')
Future<void> mediboBackgroundHandler(RemoteMessage message) async {
  // A background isolate has no Supabase client and must not build one. The
  // system tray already drew the notification from the payload's `notification`
  // block; the inbox row was written server-side when the push was queued, so
  // there is nothing to do here beyond existing (FCM requires a handler for a
  // background message to be delivered at all).
}

class PushService {
  PushService._();
  static final PushService instance = PushService._();

  /// The backend's own config row. Null until [start] has read it.
  Map<String, dynamic>? config;

  bool get configured => (config?['enabled'] as bool?) ?? false;

  FirebaseApp? _app;
  String? _token;
  String? _boundUserId;
  bool _handlersBound = false;
  StreamSubscription<String>? _refreshSub;
  PushOpen? _onOpen;

  /// The deep link of a notification that arrived before the navigator was
  /// ready (terminated-state launch). The app drains this once it can route.
  String? pendingDeepLink;

  SupabaseClient get _db => Supabase.instance.client;

  /// Call once at boot, then again on every sign-in / account switch.
  /// Safe to call repeatedly: registration is idempotent on the token.
  Future<void> start({required PushOpen onOpen}) async {
    _onOpen = onOpen;
    try {
      config ??= await _readConfig();
      if (!configured) {
        RenderLog.write('c298_push', 'not_configured');
        return;
      }
      await _ensureApp();
      await _bindHandlers();
      await registerForCurrentUser();
    } catch (e) {
      // Push must never take the app down — BOOT RESILIENCE RULE.
      RenderLog.write('c298_push', 'start_error');
      debugPrint('[push] start failed: $e');
    }
  }

  Future<Map<String, dynamic>?> _readConfig() async {
    try {
      final res = await _db.rpc('push_config_get');
      if (res is Map) return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint('[push] config read failed: $e');
    }
    return null;
  }

  Future<void> _ensureApp() async {
    if (_app != null) return;
    final c = config!;
    final apiKey = kIsWeb
        ? (c['web_api_key'] ?? c['api_key']) as String?
        : c['api_key'] as String?;
    final appId = kIsWeb
        ? (c['web_app_id'] ?? c['app_id']) as String?
        : c['app_id'] as String?;
    final senderId = c['sender_id'] as String?;
    final projectId = c['project_id'] as String?;
    if (apiKey == null || appId == null || senderId == null || projectId == null) {
      throw StateError('push_config incomplete');
    }
    _app = Firebase.apps.isNotEmpty
        ? Firebase.apps.first
        : await Firebase.initializeApp(
            options: FirebaseOptions(
              apiKey: apiKey,
              appId: appId,
              messagingSenderId: senderId,
              projectId: projectId,
            ),
          );
  }

  Future<void> _bindHandlers() async {
    if (_handlersBound) return;
    _handlersBound = true;

    FirebaseMessaging.onBackgroundMessage(mediboBackgroundHandler);

    // FOREGROUND — the app is open. The backend already logged the event, so
    // the bell's unread count is the surface; refresh it and let any listener
    // redraw.
    FirebaseMessaging.onMessage.listen((m) {
      RenderLog.write('c298_push_fg', '1');
      onForeground?.call(m.data['deep_link'] as String? ?? '');
    });

    // BACKGROUND → tapped. The app was alive but not on screen.
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      _open(m.data['deep_link'] as String?);
    });

    // TERMINATED → tapped. The notification launched the process.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _open(initial.data['deep_link'] as String?);
  }

  /// Fired on a foreground message so the shell can refresh the bell.
  void Function(String deepLink)? onForeground;

  void _open(String? link) {
    final l = (link ?? '').trim();
    if (l.isEmpty) return;
    RenderLog.write('c298_push_open', '1');
    final cb = _onOpen;
    if (cb == null) {
      pendingDeepLink = l; // navigator not ready yet — drained at first frame
      return;
    }
    cb(l);
  }

  /// Drain a link that arrived before the navigator existed.
  void drainPending() {
    final l = pendingDeepLink;
    if (l == null) return;
    pendingDeepLink = null;
    _onOpen?.call(l);
  }

  /// Ask for permission and register this device against the signed-in user.
  /// Called on login and on every account switch.
  Future<void> registerForCurrentUser() async {
    if (!configured) return;
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;

    try {
      await _ensureApp();
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission(
        alert: true, badge: true, sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        RenderLog.write('c298_push_perm', 'denied');
        return;
      }

      final vapid = config?['vapid_key'] as String?;
      final token = kIsWeb && (vapid ?? '').isNotEmpty
          ? await messaging.getToken(vapidKey: vapid)
          : await messaging.getToken();
      if (token == null || token.isEmpty) return;

      await _save(token, uid);

      // Re-register on rotation. Bound once; the callback re-reads the CURRENT
      // user so a rotation after an account switch lands on the right row.
      _refreshSub ??= messaging.onTokenRefresh.listen((t) {
        final now = _db.auth.currentUser?.id;
        if (now != null) _save(t, now);
      });
    } catch (e) {
      debugPrint('[push] register failed: $e');
    }
  }

  Future<void> _save(String token, String uid) async {
    try {
      await _db.rpc('push_token_register', params: {
        'p_token': token,
        'p_platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
        'p_device': null,
      });
      _token = token;
      _boundUserId = uid;
      RenderLog.write('c298_push_token', '1');
    } catch (e) {
      debugPrint('[push] token save failed: $e');
    }
  }

  /// An account switch: the previous account must stop receiving on this
  /// device before the new one starts.
  Future<void> onAccountSwitched() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == _boundUserId) return;
    await clearOnLogout();
    await registerForCurrentUser();
  }

  /// Sign-out: retire this device's token so a signed-out phone is silent.
  Future<void> clearOnLogout() async {
    final t = _token;
    _boundUserId = null;
    _token = null;
    if (t == null) return;
    try {
      await _db.rpc('push_token_deactivate', params: {'p_token': t});
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('[push] logout clear failed: $e');
    }
  }
}
