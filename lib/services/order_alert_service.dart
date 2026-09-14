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

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/order_alert_fsi.dart';
import 'order_alert_sw.dart';
import '../utils/render_log.dart';

class OrderAlertService extends ChangeNotifier with WidgetsBindingObserver {
  OrderAlertService._();
  static final OrderAlertService instance = OrderAlertService._();

  static const MethodChannel _native = MethodChannel('medibo/order_alert');

  /// The last order_alert_feed() payload, verbatim. Null until the first read.
  Map<String, dynamic>? feed;

  /// CMD #1988 — the last order_alert_strip() payload, verbatim. This is the
  /// ONE in-app surface an unactioned order gets: a slim tappable strip. The
  /// centre dialog that used to fight the lock-screen alert is gone, so this
  /// object decides everything the strip shows — its two sentences, its tone,
  /// its action word, and whether the web sound rings at all.
  Map<String, dynamic>? strip;

  bool get stripShow => strip?['show'] == true;
  bool get stripRing => strip?['ring'] == true;
  String get stripOrderId => (strip?['order_id'] as String?) ?? '';

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

  /// CMD #2015 — the last order_alert_reconcile() answer, verbatim.
  Map<String, dynamic>? reconcileState;

  /// Called once the signed-in user is known to be an admin.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    // CMD #2015 item 1 — BEFORE anything else. A phone that came back holding
    // a notification the server does not list (the synthetic alert that could
    // not be dismissed, an alert actioned on another device, an old build's
    // alarm channel) is cleared here, on every cold start.
    WidgetsBinding.instance.addObserver(this);
    await reconcile();
    await refresh();
    // A backstop only: realtime is the live path, this catches a dropped
    // socket. The interval is the backend's own poll_s.
    final secs = (feed?['poll_s'] as num?)?.toInt() ?? 20;
    _poll?.cancel();
    _poll = Timer.periodic(Duration(seconds: secs.clamp(10, 120)), (_) => refresh());
  }

  // CHANGE #643: `order_alert` is not in the supabase_realtime publication and
  // never was, so this channel delivered nothing from the day it was written —
  // it only held a binding open. The alert feed was already refreshed on the
  // backend's own poll_s interval (see _startPolling above), which is what has
  // actually been driving this surface all along.

  /// CMD #2015 item 1 — every foreground asks the server what still exists.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      reconcile();
      refresh();
    }
  }

  /// The ONE question this app asks about which alerts exist: the server's
  /// list. Nothing here decides anything — the ids, the mute switch and the
  /// cap all arrive in the payload, and Android is told to match it exactly.
  /// An empty list means: cancel everything, stop every sound.
  Future<void> reconcile() async {
    try {
      final raw = await _db.rpc('order_alert_reconcile');
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (m is! Map) return;
      reconcileState = Map<String, dynamic>.from(m);
      final ids = ((reconcileState?['live_ids'] as List?) ?? const [])
          .map((e) => (e as num).toInt())
          .toList(growable: false);
      RenderLog.write('c2015_reconcile', '${ids.length}');
      if (!_nativeAlerts) {
        notifyListeners();
        return;
      }
      await _native.invokeMethod('reconcile', {
        'live_ids': ids,
        'mute_all': reconcileState?['mute_all'] == true,
      });
      notifyListeners();
    } catch (e) {
      debugPrint('[order_alert] reconcile failed: $e');
    }
  }

  /// CMD #2015 item 5 — Stop, from inside the app. Same door the
  /// notification's own button uses: the sound dies, this alert never rings
  /// again on any device, and the order itself is untouched.
  Future<Map<String, dynamic>> stop(int alertId) async {
    await stopRinging();
    await clearNotification(alertId);
    try {
      final raw = await _db.rpc('order_alert_stop', params: {'p_alert_id': alertId});
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      final out = m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{};
      await reconcile();
      return out;
    } catch (e) {
      debugPrint('[order_alert] stop failed: $e');
      return {'ok': false, 'error': 'network'};
    }
  }

  /// The strip, on its own. Cheap enough to ride every refresh, and the only
  /// thing a screen that does not want the whole feed has to ask for.
  Future<void> refreshStrip() async {
    try {
      final raw = await _db.rpc('order_alert_strip');
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (m is Map) {
        strip = Map<String, dynamic>.from(m);
        RenderLog.write('c1988_alert_strip', stripShow ? '1' : '0');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[order_alert] strip failed: $e');
    }
  }

  /// CMD #1988 item 4 — the order is open. One stamp on one row stops the ring
  /// on every device and clears the alert everywhere; the backend re-rings only
  /// if it is still unactioned after rering_after_s.
  Future<Map<String, dynamic>> seen(String orderId, {String source = 'app'}) async {
    try {
      final raw = await _db.rpc('order_alert_seen',
          params: {'p_order_id': orderId, 'p_source': source});
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      final out = m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{};
      final st = out['strip'];
      if (st is Map) {
        strip = Map<String, dynamic>.from(st);
        notifyListeners();
      }
      await stopRinging();
      // CMD #1989 item 8 — "clears automatically when the order is opened
      // anywhere". The row is already stamped; this is the same truth reaching
      // the browser's own notification tray, which no RPC can touch.
      webClearOrderNotification(orderId);
      return out;
    } catch (e) {
      debugPrint('[order_alert] seen failed: $e');
      return {'ok': false, 'error': 'network'};
    }
  }

  /// A stable id for THIS browser / THIS phone, so a snooze is per device and
  /// not a global mute. shared_preferences, never dart:html (defensive import
  /// rule): this file is reachable from the widget tree.
  String? _deviceId;
  Future<String> deviceId() async {
    if (_deviceId != null) return _deviceId!;
    try {
      final sp = await SharedPreferences.getInstance();
      var id = sp.getString('medibo_alert_device_id') ?? '';
      if (id.isEmpty) {
        id = 'd${DateTime.now().microsecondsSinceEpoch}'
            '${identityHashCode(this)}';
        await sp.setString('medibo_alert_device_id', id);
      }
      _deviceId = id;
      return id;
    } catch (_) {
      _deviceId = 'unknown-device';
      return _deviceId!;
    }
  }

  /// This user's quiet hours and THIS device's snooze — never a global mute.
  Future<Map<String, dynamic>?> prefs(String? deviceId) async {
    try {
      final raw = await _db
          .rpc('order_alert_my_prefs', params: {'p_device_id': deviceId});
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (m is Map) return Map<String, dynamic>.from(m);
    } catch (e) {
      debugPrint('[order_alert] prefs failed: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>> snoozeSet(
      String deviceId, int minutes, {String? deviceLabel}) async {
    try {
      final raw = await _db.rpc('order_alert_snooze_set', params: {
        'p_device_id': deviceId,
        'p_minutes': minutes,
        'p_device_label': deviceLabel,
      });
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      await refreshStrip();
      return m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{};
    } catch (e) {
      debugPrint('[order_alert] snooze failed: $e');
      return {'ok': false, 'error': 'network'};
    }
  }

  Future<Map<String, dynamic>> quietSet(String from, String to) async {
    try {
      final raw = await _db
          .rpc('order_alert_quiet_set', params: {'p_from': from, 'p_to': to});
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      await refreshStrip();
      return m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{};
    } catch (e) {
      debugPrint('[order_alert] quiet failed: $e');
      return {'ok': false, 'error': 'network'};
    }
  }

  Future<void> refresh() async {
    await refreshStrip();
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

  /// CMD #1989 — the notification's monogram.
  ///
  /// Om's icon is the shipped default; this is how it is replaced without a
  /// deploy. The URL the lock-screen card uses is a config value, so uploading
  /// a file and pointing the config at it IS the change.
  Future<Map<String, dynamic>?> iconGet() async {
    try {
      final raw = await _db.rpc('order_alert_icon_get');
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (m is Map) return Map<String, dynamic>.from(m);
    } catch (e) {
      debugPrint('[order_alert] icon_get failed: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>> iconSet(String iconUrl, String badgeUrl) async {
    try {
      final raw = await _db.rpc('order_alert_icon_set', params: {
        'p_icon_url': iconUrl,
        'p_badge_url': badgeUrl,
      });
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      return m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{};
    } catch (e) {
      debugPrint('[order_alert] icon_set failed: $e');
      return {'ok': false, 'error': 'network'};
    }
  }

  /// Uploads the chosen file to the bucket the backend named, then hands the
  /// public URL back to it. The app picks no bucket and builds no path rule:
  /// both come from order_alert_icon_get().
  Future<Map<String, dynamic>> iconUpload({
    required String bucket,
    required String name,
    required Uint8List bytes,
  }) async {
    try {
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'png';
      final path = 'order-alert/icon-${DateTime.now().millisecondsSinceEpoch}.$ext';
      await _db.storage.from(bucket).uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
                upsert: true,
                contentType: ext == 'jpg' || ext == 'jpeg'
                    ? 'image/jpeg'
                    : 'image/$ext'),
          );
      final url = _db.storage.from(bucket).getPublicUrl(path);
      return await iconSet(url, url);
    } catch (e) {
      debugPrint('[order_alert] icon upload failed: $e');
      return {'ok': false, 'error': 'upload'};
    }
  }

  /// CMD #1989 — the bottom sheet's whole payload, rendered by
  /// order_alert_sheet(). Null when the backend says there is nothing to show.
  Future<Map<String, dynamic>?> sheet([String? orderId]) async {
    try {
      final raw = await _db.rpc('order_alert_sheet',
          params: {'p_order_id': orderId});
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (m is Map) {
        final out = Map<String, dynamic>.from(m);
        RenderLog.write('c1989_alert_sheet_rpc', out['show'] == true ? '1' : '0');
        return out;
      }
    } catch (e) {
      debugPrint('[order_alert] sheet failed: $e');
    }
    return null;
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
