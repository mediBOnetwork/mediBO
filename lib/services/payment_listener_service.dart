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
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

class PaymentListenerState {
  const PaymentListenerState({
    this.available = false,
    this.granted = false,
    this.queued = 0,
    this.deviceId = '',
  });

  final bool available;
  final bool granted;
  final int queued;
  final String deviceId;
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
  RealtimeChannel? _channel;

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
      return PaymentListenerState(
        available: true,
        granted: res?['granted'] == true,
        queued: (res?['queued'] as num?)?.toInt() ?? 0,
        deviceId: _deviceId,
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
  Future<void> start() async {
    if (!supported || _booted) return;
    _booted = true;
    try {
      await _refreshAllowList();
      await reportState();
      await drain();
      _subscribeSpeak();
      _drainTimer?.cancel();
      // A phone that was offline when the payment landed catches up here; the
      // realtime channel handles everything that arrives while it is online.
      _drainTimer = Timer.periodic(const Duration(minutes: 2), (_) => drain());
      RenderLog.write('c1931_listener_boot', 1);
    } catch (e) {
      RenderLog.write('c1931_listener_boot_error', e.toString());
    }
  }

  void dispose() {
    _drainTimer?.cancel();
    _drainTimer = null;
    final ch = _channel;
    _channel = null;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
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

  /// Tell the backend what Android granted, and get the card back.
  Future<Map<String, dynamic>> reportState() async {
    if (!supported) return const <String, dynamic>{'show': false};
    final st = await readState();
    if (st.deviceId.isEmpty) return const <String, dynamic>{'show': false};
    final card = await _rpc('payment_listener_report', <String, dynamic>{
      'p_device': st.deviceId,
      'p_enabled': st.granted,
      'p_queued': st.queued,
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
  void _subscribeSpeak() {
    if (_channel != null) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    _channel = Supabase.instance.client
        .channel('pay_speak_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'payment_alert_speak',
          callback: (_) => speakPending(),
        )
        .subscribe();
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
