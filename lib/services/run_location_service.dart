// lib/services/run_location_service.dart — CHANGE #700
//
// The rider half of "GPS that never dies", and the ONE place the app decides
// which transport carries a fix.
//
// Android gets a foreground service (RunLocationService.kt) that keeps its own
// location subscription and posts each fix itself, so a backgrounded app or a
// locked screen changes nothing. Everywhere else — web, iOS, a desktop debug
// build — falls back to the in-app updates that already existed, because those
// platforms have no equivalent and a half-working background story is worse
// than an honest foreground one.
//
// NOTHING HERE IS A POLICY. The interval, the distance filter, the
// battery-saver threshold and every word on the Android notification arrive
// from delivery_live_config() and are handed straight to the platform. This
// file chooses a transport; it does not choose a number or write a sentence.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../supabase_config.dart';
import '../utils/render_log.dart';

class RunLocationService {
  RunLocationService._();
  static final RunLocationService instance = RunLocationService._();

  static const MethodChannel _ch = MethodChannel('in.medibo.app/run_location');

  Map<String, dynamic> _config = const {};
  StreamSubscription<AuthState>? _authSub;
  bool _started = false;

  /// True only where a real background service exists. Web is excluded before
  /// the platform is even consulted: `defaultTargetPlatform` reports android
  /// for an Android *browser*, and a browser has no foreground service.
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The backend's own answer for this fleet. Cached for the session; the
  /// service is restarted with fresh values on the next run.
  Future<Map<String, dynamic>> config() async {
    if (_config.isNotEmpty) return _config;
    try {
      final res = await Supabase.instance.client.rpc('delivery_live_config');
      if (res is Map) _config = Map<String, dynamic>.from(res);
    } catch (_) {
      // No config -> the native side falls back to the defaults baked into the
      // service, which are the same numbers this RPC ships today.
    }
    return _config;
  }

  Future<bool> hasPermission() async {
    if (!isSupported) return false;
    try {
      return (await _ch.invokeMethod<bool>('hasPermission')) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    try {
      return (await _ch.invokeMethod<bool>('requestPermission')) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Starts the foreground service for a started run. Returns false on every
  /// platform that has none — the caller then keeps its in-app loop, which is
  /// exactly what it did before this change existed.
  Future<bool> start() async {
    if (!isSupported) return false;

    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return false;

    if (!await hasPermission()) {
      await requestPermission();
      if (!await hasPermission()) {
        RenderLog.write('c700_fgs', 'no_permission');
        return false;
      }
    }

    final c = await config();
    int i(String k, int fallback) {
      final v = c[k];
      return v is num ? v.toInt() : fallback;
    }

    String s(String k) => c[k]?.toString() ?? '';

    try {
      final ok = await _ch.invokeMethod<bool>('start', <String, dynamic>{
        'supabase_url': SupabaseConfig.url,
        'anon_key': SupabaseConfig.anonKey,
        'access_token': session.accessToken,
        'refresh_token': session.refreshToken ?? '',
        'interval_s': i('interval_s', 5),
        'min_move_m': i('min_move_m', 20),
        'battery_saver_pct': i('battery_saver_pct', 20),
        'battery_interval_s': i('battery_interval_s', 30),
        'notif_title': s('notif_title'),
        'notif_body': s('notif_body'),
        'channel_name': s('channel_name'),
      });
      _started = ok ?? false;
      if (_started) _watchSession();
      RenderLog.write('c700_fgs', _started ? 'started' : 'refused');
      return _started;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // An older APK without the native half. The in-app loop stays.
      return false;
    }
  }

  Future<void> stop() async {
    _authSub?.cancel();
    _authSub = null;
    _started = false;
    if (!isSupported) return;
    try {
      await _ch.invokeMethod<bool>('stop');
      RenderLog.write('c700_fgs', 'stopped');
    } on PlatformException {
      // Nothing to stop is not a failure.
    } on MissingPluginException {
      // Ditto.
    }
  }

  /// A run outlives an access token. Rather than let the service discover that
  /// with a 401 an hour in, every refreshed session is pushed down as it
  /// happens; the service still refreshes on its own as the backstop for a
  /// process that outlived this isolate.
  void _watchSession() {
    _authSub?.cancel();
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      final s = state.session;
      if (s == null || !_started) return;
      _ch.invokeMethod<bool>('token', <String, dynamic>{
        'access_token': s.accessToken,
        'refresh_token': s.refreshToken ?? '',
      }).catchError((_) => false);
    });
  }

}
