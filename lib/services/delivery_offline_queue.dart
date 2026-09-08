// lib/services/delivery_offline_queue.dart — CMD #453 (feature_gaps 93)
//
// THE RIDER'S ACTION QUEUE.
//
// delivery_replay(p_client_action_id, p_action, p_payload) and the
// delivery_action_log table have existed since CHANGE #629 and cover eight
// actions — but nothing in the app ever called them. Every proof-sheet action
// went straight at its own RPC, so a rider in a basement or a stairwell got an
// exception and LOST the action. delivery_action_log had zero rows.
//
// This is the missing half. Every write a rider makes goes through here:
//   1. an id is minted and the action is PERSISTED before anything is sent,
//   2. it is sent through delivery_replay, which is idempotent on that id,
//   3. it is dropped from the queue only once the backend has answered,
//   4. anything still queued is drained on the next call and on app start.
//
// Nothing here decides copy: `queuedMessage` is the backend's own
// `dlv_offline_queued` label. And nothing here decides success — the response
// is returned to the caller verbatim, exactly as a direct RPC call would be.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../fulfill/fulfill_lookups.dart';
import '../utils/render_log.dart';

class DeliveryOfflineQueue {
  DeliveryOfflineQueue._();
  static final DeliveryOfflineQueue instance = DeliveryOfflineQueue._();

  /// A second, independent queue over the same store. The app uses [instance];
  /// this exists so a test can start from an empty in-memory queue without
  /// reaching into private state.
  @visibleForTesting
  DeliveryOfflineQueue.forTest();

  static const String _prefsKey = 'delivery_action_queue_v1';

  /// How many actions are still waiting to reach the backend. The UI watches
  /// this; it never counts for itself.
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  final Random _rand = Random();
  bool _draining = false;
  List<Map<String, dynamic>> _queue = <Map<String, dynamic>>[];
  bool _loaded = false;

  /// The backend's sentence for "kept, will send later". Empty until the copy
  /// catalog has loaded — an empty string prints nothing rather than a guess.
  String get queuedMessage => FulfillLookups.instance.ui('dlv_offline_queued');
  String get sendingMessage => FulfillLookups.instance.ui('dlv_offline_sending');

  /// A client action id is only ever a KEY — it carries no meaning and is never
  /// displayed. Time-ordered so a drain replays in the order the rider acted.
  String _mintId() {
    final n = _rand.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '${DateTime.now().toUtc().microsecondsSinceEpoch}-$n';
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefsKey) ?? '';
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _queue = decoded
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }
    } catch (_) {
      _queue = <Map<String, dynamic>>[];
    }
    pending.value = _queue.length;
  }

  Future<void> _save() async {
    pending.value = _queue.length;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_prefsKey, jsonEncode(_queue));
    } catch (_) {
      // A device that cannot persist still sends; it just cannot survive a
      // restart. Losing the mirror must not lose the action in flight.
    }
  }

  /// Call once at rider-screen boot: anything left from a previous session
  /// goes out before the rider does anything new.
  Future<void> start() async {
    await _load();
    unawaited(drain());
  }

  /// Send [action] with [payload]. Returns the backend's own reply, or a
  /// `queued: true` envelope when the device could not reach it at all.
  Future<Map<String, dynamic>> send(
    String action,
    Map<String, dynamic> payload,
  ) async {
    await _load();
    final entry = <String, dynamic>{
      'client_action_id': _mintId(),
      'action': action,
      'payload': payload,
    };
    _queue.add(entry);
    await _save();

    final res = await _flush(entry);
    if (res != null) {
      // whatever else is waiting rides out on the same working connection
      unawaited(drain());
      return res;
    }
    RenderLog.write('c453_delivery_offline', 'queued;action=$action;n=${_queue.length}');
    return <String, dynamic>{
      'ok': false,
      'error': 'queued_offline',
      'queued': true,
      'message': queuedMessage,
    };
  }

  /// One attempt at one entry. Returns the reply, or null when the device could
  /// not reach the backend — the entry then stays queued.
  Future<Map<String, dynamic>?> _flush(Map<String, dynamic> entry) async {
    try {
      final res = await Supabase.instance.client.rpc('delivery_replay', params: {
        'p_client_action_id': entry['client_action_id'],
        'p_action': entry['action'],
        'p_payload': entry['payload'],
      });
      _queue.removeWhere((e) => e['client_action_id'] == entry['client_action_id']);
      await _save();
      return res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
    } catch (_) {
      // Offline, or the backend is unreachable. The id is already persisted, so
      // the retry is safe: delivery_replay is idempotent on it.
      return null;
    }
  }

  /// Push everything that is still waiting, oldest first. Stops at the first
  /// entry that will not go — the rider is still offline, so the rest will not
  /// go either, and order is preserved.
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;
    try {
      await _load();
      for (final entry in List<Map<String, dynamic>>.from(_queue)) {
        final res = await _flush(entry);
        if (res == null) break;
      }
      if (_queue.isEmpty) {
        RenderLog.write('c453_delivery_offline', 'drained');
      }
    } finally {
      _draining = false;
    }
  }
}
