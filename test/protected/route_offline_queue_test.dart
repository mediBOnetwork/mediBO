// test/protected/route_offline_queue_test.dart — CMD #1878
//
// What this file holds down is the QA scenario itself: airplane mode, two
// stops checked in, reconnect, both land ONCE.
//
// The queue is the one place in this app where a lost write is invisible
// until a rep swears he visited a shop the report says he never did, so every
// rule it obeys is nailed here on the Dart VM: order, idempotency, the chip's
// wording coming from the backend, and a broken network never dropping an
// entry on the floor.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/route_offline_queue.dart';

/// The `sync` block exactly as _c1878_sync_block() builds it — abbreviated to
/// the counts this file exercises, plus the fallback template.
const Map<String, dynamic> kSync = {
  'labels': {
    '1': '1 check-in pending sync',
    '2': '2 check-ins pending sync',
    '3': '3 check-ins pending sync',
  },
  'labels_fallback': '{n} check-ins pending sync',
  'queued_message': 'Saved on this device. It syncs when you are back online.',
  'offline_banner': 'Offline — showing your saved route.',
  'retry_label': 'Sync now',
};

PendingCheckIn entry(String stop, String ts, {String status = 'visited'}) =>
    PendingCheckIn(
        stopId: stop, routeId: 'r1', status: status, clientTs: ts);

void main() {
  group('the pending chip is the backend\'s sentence', () {
    test('a count the backend pre-worded is printed verbatim', () {
      expect(RouteSyncPlan.pendingLabel(kSync, 3), '3 check-ins pending sync');
      expect(RouteSyncPlan.pendingLabel(kSync, 1), '1 check-in pending sync');
    });

    test('nothing queued is NO chip — never a "0 pending" string', () {
      expect(RouteSyncPlan.pendingLabel(kSync, 0), isNull);
      expect(RouteSyncPlan.pendingLabel(kSync, -1), isNull);
    });

    test('a count past the ladder fills the BACKEND\'s own {n} slot', () {
      expect(RouteSyncPlan.pendingLabel(kSync, 44), '44 check-ins pending sync');
    });

    test('no sync block at all draws no chip rather than an invented one', () {
      expect(RouteSyncPlan.pendingLabel(null, 2), isNull);
      expect(RouteSyncPlan.pendingLabel(const {}, 2), isNull);
    });
  });

  group('replay order and shape', () {
    test('oldest first — the rep\'s own sequence, not arrival order', () {
      final out = RouteSyncPlan.ordered([
        entry('s2', '2026-09-08T10:30:00+05:30'),
        entry('s1', '2026-09-08T10:05:00+05:30'),
        entry('s3', '2026-09-08T11:00:00+05:30'),
      ]);
      expect(out.map((e) => e.stopId).toList(), ['s1', 's2', 's3']);
    });

    test('the device clock reading always travels with the call', () {
      final p = entry('s1', '2026-09-08T10:05:00+05:30').rpcParams();
      expect(p['p_stop_id'], 's1');
      expect(p['p_status'], 'visited');
      expect(p['p_client_ts'], '2026-09-08T10:05:00+05:30');
    });

    test('an empty note is omitted, never sent as an empty string', () {
      final p = PendingCheckIn(
              stopId: 's1',
              routeId: 'r1',
              status: 'visited',
              note: '   ',
              clientTs: 't')
          .rpcParams();
      expect(p.containsKey('p_note'), isFalse);
    });

    test('a correction before sync REPLACES the held answer for that stop', () {
      var q = <PendingCheckIn>[];
      q = RouteSyncPlan.merge(q, entry('s1', 't1', status: 'visited'));
      q = RouteSyncPlan.merge(q, entry('s1', 't2', status: 'converted'));
      expect(q.length, 1);
      expect(q.single.status, 'converted');
    });
  });

  group('what counts as landed', () {
    test('ok:true lands; the idempotent replay of one lands too', () {
      expect(RouteSyncPlan.landed({'ok': true}), isTrue);
      expect(RouteSyncPlan.landed({'ok': true, 'duplicate': true}), isTrue);
      expect(RouteSyncPlan.duplicate({'ok': true, 'duplicate': true}), isTrue);
    });

    test('a refusal about THIS stop is permanent; a blink is not', () {
      expect(
          RouteSyncPlan.permanentFailure(
              {'ok': false, 'error': 'stop_not_found'}),
          isTrue);
      expect(
          RouteSyncPlan.permanentFailure({'ok': false, 'error': 'db_timeout'}),
          isFalse);
      expect(RouteSyncPlan.landed(null), isFalse);
      expect(RouteSyncPlan.landed('boom'), isFalse);
    });
  });

  group('THE QA SCENARIO — airplane mode, two stops, reconnect', () {
    late RouteOfflineQueue queue;
    late MemoryRouteOfflineStore store;

    setUp(() {
      store = MemoryRouteOfflineStore();
      queue = RouteOfflineQueue(store: store);
    });

    test('both check-ins land exactly once, in the order they were made',
        () async {
      await queue.load();
      await queue.enqueue(entry('stopB', '2026-09-08T10:30:00+05:30'));
      await queue.enqueue(entry('stopA', '2026-09-08T10:05:00+05:30'));
      expect(queue.pendingCount, 2);
      expect(RouteSyncPlan.pendingLabel(kSync, queue.pendingCount),
          '2 check-ins pending sync');

      // Reconnect. The server accepts both.
      final sent = <Map<String, dynamic>>[];
      final landed = await queue.flush((p) async {
        sent.add(p);
        return {'ok': true, 'stop_id': p['p_stop_id']};
      });

      expect(landed, 2);
      expect(queue.pendingCount, 0);
      expect(RouteSyncPlan.pendingLabel(kSync, queue.pendingCount), isNull);
      // Order: the 10:05 stop before the 10:30 one, whatever order they were
      // tapped into the queue.
      expect(sent.map((e) => e['p_stop_id']).toList(), ['stopA', 'stopB']);
      // Every call carried its own device clock reading.
      expect(sent.every((e) => (e['p_client_ts'] as String).isNotEmpty), isTrue);
    });

    test('a second flush sends NOTHING — the queue is already empty',
        () async {
      await queue.enqueue(entry('stopA', 't1'));
      await queue.flush((p) async => {'ok': true});
      var calls = 0;
      final again = await queue.flush((p) async {
        calls++;
        return {'ok': true};
      });
      expect(calls, 0);
      expect(again, 0);
    });

    test('a replay the server has already seen still clears the queue',
        () async {
      await queue.enqueue(entry('stopA', 't1'));
      final landed = await queue.flush(
          (p) async => {'ok': true, 'duplicate': true, 'message': 'saved'});
      expect(landed, 1);
      expect(queue.pendingCount, 0);
    });

    test('still offline: nothing is lost and the ORDER survives', () async {
      await queue.enqueue(entry('stopA', 't1'));
      await queue.enqueue(entry('stopB', 't2'));
      final landed = await queue.flush((p) async => throw Exception('offline'));
      expect(landed, 0);
      expect(queue.pendingCount, 2);
      expect(queue.pending.map((e) => e.stopId).toList(), ['stopA', 'stopB']);
    });

    test('a mid-queue failure stops the replay — the tail keeps its order',
        () async {
      await queue.enqueue(entry('stopA', 't1'));
      await queue.enqueue(entry('stopB', 't2'));
      await queue.enqueue(entry('stopC', 't3'));
      final landed = await queue.flush((p) async {
        if (p['p_stop_id'] == 'stopB') throw Exception('dropped');
        return {'ok': true};
      });
      expect(landed, 1);
      expect(queue.pending.map((e) => e.stopId).toList(), ['stopB', 'stopC']);
    });

    test('a stop that no longer exists is dropped, not retried forever',
        () async {
      await queue.enqueue(entry('gone', 't1'));
      final landed = await queue.flush(
          (p) async => {'ok': false, 'error': 'stop_not_found'});
      expect(landed, 0);
      expect(queue.pendingCount, 0);
    });

    test('the queue survives a reload of the app', () async {
      await queue.enqueue(entry('stopA', 't1'));
      await queue.enqueue(entry('stopB', 't2'));

      final reopened = RouteOfflineQueue(store: store);
      await reopened.load();
      expect(reopened.pendingCount, 2);
      expect(reopened.pending.first.stopId, 'stopA');
    });

    test('a corrupt queue file loses the queue, never the screen', () async {
      await store.write(RouteOfflineQueue.queueKey, 'not json at all');
      final reopened = RouteOfflineQueue(store: store);
      await reopened.load();
      expect(reopened.pendingCount, 0);
    });
  });

  group('the cached route is the payload, byte for byte', () {
    test('what was cached is what comes back', () async {
      final store = MemoryRouteOfflineStore();
      final queue = RouteOfflineQueue(store: store);
      const bundle = {
        'ok': true,
        'today': {
          'title': 'Today',
          'routes': [
            {'route_id': 'r1', 'nav_uri': 'https://maps.example/x', 'progress_label': '2 of 9 done'}
          ]
        },
        'sync': kSync,
      };
      await queue.cacheBundle(bundle);
      final back = await queue.cachedBundle();
      expect(back?['today']['routes'][0]['nav_uri'], 'https://maps.example/x');
      expect(back?['today']['routes'][0]['progress_label'], '2 of 9 done');
      expect(back?['sync']['offline_banner'], kSync['offline_banner']);
    });

    test('a device that has never been online has no cache, and says so',
        () async {
      final queue = RouteOfflineQueue(store: MemoryRouteOfflineStore());
      expect(await queue.cachedBundle(), isNull);
    });
  });
}
