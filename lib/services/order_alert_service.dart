// CHANGE #306 — the app's side of the unpaid-order alert.
//
// This file holds no wording, no thresholds and no arithmetic. It fetches
// order_alert_feed() / order_alert_card(), hands the payload to whoever draws
// it, sends the admin's decision back with order_alert_action(), and mirrors
// the BACKEND'S OWN count and sentence into Android's sticky tray line.
//
// The realtime subscription is on `orders` (an admin with the app open sees the
// popup with no push round trip, spec item 4) and on `order_alert` (so a
// decision taken on another device, or a payment landing, closes the popup
// here too).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/order_alert_fsi.dart';
import '../utils/render_log.dart';

class OrderAlertService extends ChangeNotifier {
  OrderAlertService._();
  static final OrderAlertService instance = OrderAlertService._();

  static const MethodChannel _native = MethodChannel('medibo/order_alert');

  /// The last order_alert_feed() payload, verbatim. Null until the first read.
  Map<String, dynamic>? feed;

  RealtimeChannel? _alertChannel;
  Timer? _poll;
  bool _started = false;

  SupabaseClient get _db => Supabase.instance.client;

  /// Backend's count. Zero when it has not answered yet — never a guess.
  int get count => (feed?['count'] as num?)?.toInt() ?? 0;

  /// Backend's badge string. Empty is an absence, and draws nothing.
  String get badgeLabel => (feed?['badge_label'] as String?) ?? '';

  List<Map<String, dynamic>> get items {
    final raw = feed?['items'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  bool get _nativeAlerts =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Called once the signed-in user is known to be an admin.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await refresh();
    _subscribe();
    // A backstop only: realtime is the live path, this catches a dropped
    // socket. The interval is the backend's own poll_s.
    final secs = (feed?['poll_s'] as num?)?.toInt() ?? 20;
    _poll?.cancel();
    _poll = Timer.periodic(Duration(seconds: secs.clamp(10, 120)), (_) => refresh());
  }

  void _subscribe() {
    if (_alertChannel != null) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    _alertChannel = _db
        .channel('admin_order_alert_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_alert',
          callback: (_) => refresh(),
        )
        .subscribe();
  }

  Future<void> refresh() async {
    try {
      final raw = await _db.rpc('order_alert_feed');
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (m is Map) {
        feed = Map<String, dynamic>.from(m);
        RenderLog.write('c306_alert_feed', '$count');
        await _syncOngoing();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[order_alert] feed failed: $e');
    }
  }

  /// One order's card, as the popup draws it.
  Future<Map<String, dynamic>?> card(String orderId) async {
    try {
      final raw = await _db.rpc('order_alert_card', params: {'p_order_id': orderId});
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (m is Map) return Map<String, dynamic>.from(m);
    } catch (e) {
      debugPrint('[order_alert] card failed: $e');
    }
    return null;
  }

  /// Accept / reject. The reply's `message` is the backend's own words —
  /// including a refusal, which is the credit block speaking.
  Future<Map<String, dynamic>> act(String orderId, String action,
      {String? reason}) async {
    try {
      final raw = await _db.rpc('order_alert_action', params: {
        'p_order_id': orderId,
        'p_action': action,
        'p_reason': reason,
      });
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      final out = m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{};
      final f = out['feed'];
      if (f is Map) {
        feed = Map<String, dynamic>.from(f);
        await _syncOngoing();
        notifyListeners();
      } else {
        await refresh();
      }
      await stopRinging();
      return out;
    } catch (e) {
      debugPrint('[order_alert] action failed: $e');
      return {'ok': false, 'error': 'network'};
    }
  }

  /// The sticky "N orders awaiting" line — the backend's count and sentence,
  /// passed straight through. Android only; the web has the in-app badge.
  Future<void> _syncOngoing() async {
    if (!_nativeAlerts) return;
    try {
      await _native.invokeMethod('ongoing', {
        'count': count,
        'title': (feed?['ongoing_title'] as String?) ?? '',
        'body': (feed?['ongoing_body'] as String?) ?? '',
      });
    } catch (_) {
      // A device without the channel is not an error — it just has no tray.
    }
  }

  /// CHANGE #307 — what Android says about the full-screen-intent grant on
  /// THIS device. No wording is decided here: the caller pairs this fact with
  /// order_alert_fsi()'s sentences. A device without the channel is not an
  /// error — it simply has no lock screen to take over.
  Future<FsiDeviceState> fullScreenState() async {
    if (!_nativeAlerts) return FsiDeviceState.notAndroid;
    try {
      final raw = await _native.invokeMethod('fullScreenState');
      if (raw is Map) return FsiDeviceState.fromChannel(raw);
    } catch (e) {
      debugPrint('[order_alert] fullScreenState failed: $e');
    }
    return FsiDeviceState.unknown;
  }

  /// Opens Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT — the only place
  /// the grant can be given. Returns false when no settings screen took it.
  Future<bool> openFullScreenSettings() async {
    if (!_nativeAlerts) return false;
    try {
      return await _native.invokeMethod('openFullScreenSettings') == true;
    } catch (e) {
      debugPrint('[order_alert] openFullScreenSettings failed: $e');
      return false;
    }
  }

  Future<void> stopRinging() async {
    if (!_nativeAlerts) return;
    try {
      await _native.invokeMethod('stopRinging');
    } catch (_) {}
  }

  /// Silence and clear one alert's notification once it is handled in-app.
  Future<void> clearNotification(int alertId) async {
    if (!_nativeAlerts) return;
    try {
      await _native.invokeMethod('clear', {'alert_id': alertId});
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    _alertChannel?.unsubscribe();
    super.dispose();
  }
}
