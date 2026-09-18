// CMD #1931 — the Dart half of "hear every payment".
//
// The Android service (PaymentListener.kt) can only do two things: drop
// everything that is not on the backend's allow-list, and remember what is
// left. EVERYTHING else is here, and everything here is a relay:
//
//   packages  — payment_listener_boot() says which apps may be read. This file
//               never carries a package name of its own.
//   forward   — every queued line goes to payment_alert_ingest() verbatim. No
//               parsing, no amount, no sender: the backend's rules do that.
//   speak     — payment_alert_speak_pull() hands down a finished sentence and
//               the phone's own volume. Dart reads it out; it never writes it.
//
// Web and iOS get a service that reports "not available" and does nothing, so
// the single call site on the Money screen is the same on every platform.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';
import 'live_feed.dart';

class PaymentListenerState {
  const PaymentListenerState({
    this.available = false,
    this.granted = false,
    this.queued = 0,
    this.deviceId = '',
    this.model = '',
    this.boundAtMs = 0,
    this.allowCount = 0,
    this.appVersion = '',
  });

  final bool available;

  /// Notification access, as Android's own settings report it.
  final bool granted;
  final int queued;
  final String deviceId;
  final String model;

  /// When Android last STARTED the listener service (onListenerConnected).
  /// CMD #2067: a grant is not a bind — on ColorOS/MIUI a phone can be
  /// "allowed" and never connected, and that phone hears nothing.
  final int boundAtMs;

  /// How many packages the backend has handed down. 0 = this phone drops every
  /// notification, which is what made a granted phone deaf on 17 Sep.
  final int allowCount;

  /// versionName (versionCode) of the running build, reported never composed.
  final String appVersion;

  bool get bound => boundAtMs > 0;
}

/// One per app. Started from the Money screen, kept alive for the session so a
/// payment that lands while the screen is closed is still spoken.
class PaymentListenerService {
  PaymentListenerService._();

  static final PaymentListenerService instance = PaymentListenerService._();

  static const MethodChannel _ch = MethodChannel('medibo/pay_listen');

  /// Android only. On web `defaultTargetPlatform` can still report android
  /// (a Chrome-on-Android browser), and there is no channel there at all.
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// What the phone calls itself, the way the backend's per-device row keys it.
  String get deviceId => _deviceId;
  String _deviceId = '';

  /// What Android calls this handset. Reported, never composed here.
  String get model => _model;
  String _model = '';

  /// versionName (versionCode) of the installed build, as Android reports it.
  String get appVersion => _appVersion;
  String _appVersion = '';

  /// The platform string the backend switches the card on.
  static String get platform => kIsWeb
      ? 'web'
      : defaultTargetPlatform == TargetPlatform.android
      ? 'android'
      : defaultTargetPlatform == TargetPlatform.iOS
      ? 'ios'
      : 'other';

  bool _booted = false;
  bool _draining = false;
  int _speakVolume = 100;
  bool _speakOn = true;
  Timer? _drainTimer;
  LiveFeedHandle? _feed;
  _ListenerLifecycle? _lifecycle;
  String _lastSyncSig = '';

  /// Anything the card should redraw for: a grant changed, a queue emptied.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void _bump() => revision.value = revision.value + 1;

  Future<Map<String, dynamic>> _rpc(
    String fn, [
    Map<String, dynamic> args = const {},
  ]) async {
    final raw = await Supabase.instance.client.rpc(
      fn,
      params: args.isEmpty ? null : args,
    );
    final one = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return one is Map ? Map<String, dynamic>.from(one) : <String, dynamic>{};
  }

  /// What Android says about itself right now.
  Future<PaymentListenerState> readState() async {
    if (!supported) return const PaymentListenerState();
    try {
      final res = await _ch.invokeMapMethod<String, dynamic>('state');
      _deviceId = (res?['device_id'] ?? '').toString();
      _model = (res?['model'] ?? '').toString();
      _appVersion = (res?['app_version'] ?? '').toString();
      return PaymentListenerState(
        available: true,
        granted: res?['granted'] == true,
        queued: (res?['queued'] as num?)?.toInt() ?? 0,
        deviceId: _deviceId,
        model: _model,
        boundAtMs: (res?['bound_at'] as num?)?.toInt() ?? 0,
        allowCount: (res?['allow_count'] as num?)?.toInt() ?? 0,
        appVersion: _appVersion,
      );
    } catch (_) {
      return const PaymentListenerState(available: true);
    }
  }

  /// The one system screen that can grant or revoke notification access.
  Future<bool> openSettings() async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('openSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Boot: pull the allow-list, tell Android about it, report our state back,
  /// drain whatever is waiting, and start listening for something to say.
  ///
  /// CMD #2067 — this used to be called from exactly ONE place, the Money
  /// home's card. The Devices section on the Payment alerts screen — the
  /// screen with the "Turn on notification access" button — never called it,
  /// so on a phone that only ever visited that screen the allow-list was never
  /// written and payment_alert_device_register() was never called. Granted
  /// access, no device row, nothing heard. Every surface now calls start(),
  /// and start() is cheap and idempotent.
  Future<void> start() async {
    if (!supported) return;
    if (!_booted) {
      _booted = true;
      _lifecycle ??= _ListenerLifecycle(this);
      WidgetsBinding.instance.addObserver(_lifecycle!);
    }
    try {
      await syncPairing();
      await _subscribeSpeak();
      _drainTimer?.cancel();
      // A phone that was offline when the payment landed catches up here; the
      // realtime channel handles everything that arrives while it is online.
      _drainTimer = Timer.periodic(const Duration(minutes: 2), (_) => drain());
      RenderLog.write('c1931_listener_boot', 1);
    } catch (e) {
      RenderLog.write('c1931_listener_boot_error', e.toString());
    }
  }

  /// THE one door. Safe to call on every build, on every resume and on the way
  /// back from Android's settings screen.
  ///
  /// It does, in order: re-read the backend's package allow-list and hand it to
  /// Android (a phone with an empty list drops every notification), ask Android
  /// what it currently grants and whether the service is BOUND, pair the phone
  /// with that answer, and drain anything the queue is still holding.
  Future<PaymentListenerState> syncPairing() async {
    if (!supported) return const PaymentListenerState();
    try {
      await _refreshAllowList();
    } catch (_) {
      // No network: Android keeps the list it already has.
    }
    final st = await readState();
    if (st.deviceId.isEmpty) return st;
    if (st.granted) {
      await register(state: st);
      await reportState(state: st);
      await drain();
    }
    // Redraw ONLY when something a card shows actually changed. The Money
    // card reloads on `revision`, and reloading calls start() again — an
    // unconditional bump here is an endless load/sync/load cycle.
    final sig = '${st.granted}|${st.bound}|${st.queued}|'
        '${st.allowCount}|${st.deviceId}';
    if (sig != _lastSyncSig) {
      _lastSyncSig = sig;
      _bump();
    }
    return st;
  }

  /// CMD #2067 item 4 — the grant is on, Android never started the service.
  /// Ask it to, the polite way and then the hard way, and re-pair with whatever
  /// it says afterwards. The wording of any button that calls this is the
  /// backend's (`pairing.rebind_label`).
  Future<PaymentListenerState> rebind() async {
    if (!supported) return const PaymentListenerState();
    try {
      await _ch.invokeMethod<bool>('rebind');
    } catch (_) {
      // An OEM that refuses the toggle still gets the re-read below.
    }
    // Binding is asynchronous on the system side; give it a moment before
    // asking again, so the card does not report the state from before.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    return syncPairing();
  }

  void dispose() {
    _drainTimer?.cancel();
    _drainTimer = null;
    _feed?.dispose();
    _feed = null;
    if (_lifecycle != null) {
      WidgetsBinding.instance.removeObserver(_lifecycle!);
      _lifecycle = null;
    }
    _booted = false;
  }

  Future<void> _refreshAllowList() async {
    final boot = await _rpc('payment_listener_boot');
    if (boot['ok'] != true) return;
    final packages = (boot['packages'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    await _ch.invokeMethod<bool>('setPackages', <String, dynamic>{
      'packages': packages,
      'ignore': const <String>[],
      'queue_max': (boot['queue_max'] as num?)?.toInt() ?? 500,
    });
    RenderLog.write('c1931_listener_packages', packages.length);
  }

  /// Pair this phone with the backend's device registry. Idempotent: the RPC
  /// upserts, so every launch simply refreshes last-seen and the zone.
  Future<Map<String, dynamic>> register({PaymentListenerState? state}) async {
    if (!supported) return const <String, dynamic>{'ok': false};
    final st = state ?? await readState();
    if (st.deviceId.isEmpty) return const <String, dynamic>{'ok': false};
    try {
      final res = await _rpc('payment_alert_device_register', <String, dynamic>{
        'p_device': st.deviceId,
        if (st.model.isNotEmpty) 'p_label': st.model,
        // CMD #2067 — one call now both pairs the phone AND tells the backend
        // what Android says: the grant, and whether the listener service has
        // actually been started. "Paired" on its own was a status a deaf phone
        // could show.
        'p_listener_enabled': st.granted,
        'p_bound': st.bound,
        if (st.appVersion.isNotEmpty) 'p_app_version': st.appVersion,
      });
      RenderLog.write('c2050_device_registered', res['ok'] == true ? 1 : 0);
      RenderLog.write('c2067_pair_bound', st.bound ? 1 : 0);
      RenderLog.write('c2067_pair_packages', st.allowCount);
      return res;
    } catch (_) {
      return const <String, dynamic>{'ok': false};
    }
  }

  /// Tell the backend what Android granted, and get the card back.
  Future<Map<String, dynamic>> reportState({PaymentListenerState? state}) async {
    if (!supported) return const <String, dynamic>{'show': false};
    final st = state ?? await readState();
    if (st.deviceId.isEmpty) return const <String, dynamic>{'show': false};
    final card = await _rpc('payment_listener_report', <String, dynamic>{
      'p_device': st.deviceId,
      'p_enabled': st.granted,
      'p_queued': st.queued,
      if (st.appVersion.isNotEmpty) 'p_app_version': st.appVersion,
      if (st.model.isNotEmpty) 'p_label': st.model,
    });
    _speakOn = card['speak_on'] != false;
    _speakVolume = (card['volume'] as num?)?.toInt() ?? 100;
    return card;
  }

  /// Send every queued notification to payment_alert_ingest, then forget it.
  /// A line the backend rejects is still acked — retrying it forever would
  /// wedge the queue behind one bad notification.
  Future<int> drain() async {
    if (!supported || _draining) return 0;
    _draining = true;
    var sent = 0;
    try {
      final raw = await _ch.invokeMethod<String>('drain', <String, dynamic>{
        'limit': 25,
      });
      final rows = jsonDecode(raw ?? '[]');
      if (rows is! List || rows.isEmpty) return 0;
      final done = <int>[];
      for (final r in rows.whereType<Map>()) {
        final qid = (r['qid'] as num?)?.toInt();
        try {
          await _rpc('payment_alert_ingest', <String, dynamic>{
            'p_device': _deviceId,
            'p_package': '${r['package'] ?? ''}',
            'p_title': '${r['title'] ?? ''}',
            'p_text': '${r['text'] ?? ''}',
            'p_posted_at': DateTime.fromMillisecondsSinceEpoch(
              (r['posted_at_ms'] as num?)?.toInt() ?? 0,
              isUtc: true,
            ).toIso8601String(),
          });
          if (qid != null) done.add(qid);
          sent++;
        } catch (_) {
          // Network down: leave it queued, the timer comes back for it.
          break;
        }
      }
      if (done.isNotEmpty) {
        await _ch.invokeMethod<int>('ack', <String, dynamic>{'qids': done});
        _bump();
      }
    } catch (_) {
      // Nothing to do: the next tick tries again.
    } finally {
      _draining = false;
    }
    if (sent > 0) RenderLog.write('c1931_listener_sent', sent);
    return sent;
  }

  /// A matched payment writes one row into payment_alert_speak. That is the
  /// signal; the sentence itself is pulled, so a phone that was asleep still
  /// gets it and a muted phone is told to stay quiet.
  Future<void> _subscribeSpeak() async {
    if (_feed != null) return;
    // Through LiveFeed, never a channel of our own: realtime_table_registry
    // decides whether payment_alert_speak gets a live binding or a poll, and
    // flipping that is one UPDATE (CHANGE #643 / the #646 gate).
    _feed = await LiveFeed.instance.watch(
      channelPrefix: 'pay_speak',
      tables: const ['payment_alert_speak'],
      onChange: (_) => speakPending(),
    );
  }

  /// Pull whatever is unspoken for this zone and read it out.
  Future<int> speakPending() async {
    if (!supported) return 0;
    Map<String, dynamic> res;
    try {
      res = await _rpc('payment_alert_speak_pull', <String, dynamic>{
        'p_limit': 5,
        'p_device': _deviceId,
      });
    } catch (_) {
      return 0;
    }
    if (res['ok'] != true) return 0;
    _speakOn = res['speak'] != false;
    _speakVolume = (res['volume'] as num?)?.toInt() ?? 100;
    final rows = (res['rows'] as List?) ?? const [];
    if (rows.isEmpty) return 0;
    if (_speakOn) {
      for (final r in rows.whereType<Map>()) {
        final line = '${r['message'] ?? ''}';
        if (line.isEmpty) continue;
        try {
          await _ch.invokeMethod<bool>('speak', <String, dynamic>{
            'text': line,
            'volume': _speakVolume,
          });
        } catch (_) {
          // No TTS engine on this handset: the Money card still shows the line.
        }
      }
    }
    RenderLog.write('c1931_listener_spoke', rows.length);
    _bump();
    return rows.length;
  }

  /// The mute switch and its volume live in the backend, one row per phone.
  Future<Map<String, dynamic>> setSpeak({
    required bool speak,
    int? volume,
  }) async {
    if (!supported || _deviceId.isEmpty) return const <String, dynamic>{};
    final card = await _rpc('payment_listener_set_speak', <String, dynamic>{
      'p_device': _deviceId,
      'p_speak': speak,
      'p_volume': ?volume,
    });
    _speakOn = card['speak_on'] != false;
    _speakVolume = (card['volume'] as num?)?.toInt() ?? 100;
    _bump();
    return card;
  }

  /// The whole card, worded by the backend. `show:false` draws nothing.
  Future<Map<String, dynamic>> card() async {
    try {
      return await _rpc('payment_listener_card', <String, dynamic>{
        'p_device': _deviceId,
        'p_platform': platform,
      });
    } catch (_) {
      return const <String, dynamic>{'show': false};
    }
  }
}


/// CMD #2067 — every return to the app re-checks the grant.
///
/// The 17 Sep failure was a round trip: tap the button, grant access in
/// Android's settings, come back — and nothing on the way back asked Android
/// what had just changed. `AppLifecycleState.resumed` is that moment, for the
/// settings screen and for every other way back into the app.
class _ListenerLifecycle with WidgetsBindingObserver {
  _ListenerLifecycle(this.service);

  final PaymentListenerService service;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Fire and forget: a resume must never be blocked on the network.
    service.syncPairing();
  }
}
