// PROTECTED — the rider's offline action queue (CMD #453, feature_gaps 93).
//
// delivery_replay() and delivery_action_log shipped in CHANGE #629 and were
// never called: every proof-sheet action went straight at its own RPC, so a
// rider in a basement got an exception and LOST the action, and the log table
// held zero rows. These tests pin the four decisions that make the queue a
// queue rather than a retry:
//
//   1. the action is PERSISTED before it is sent, so a crash cannot eat it;
//   2. an unreachable backend is `queued`, never a silent success and never a
//      Dart-authored error sentence — the copy is the backend's own label;
//   3. every action carries its OWN client_action_id, which is what makes the
//      replay idempotent on the server side;
//   4. a drain stops at the first entry that will not go, so the rider's
//      actions reach the backend in the order they happened.
//
// No Supabase is initialised here on purpose: an uninitialised client is
// exactly the "cannot reach the backend" case the queue exists for.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/delivery_offline_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _prefsKey = 'delivery_action_queue_v1';

Future<List<Map<String, dynamic>>> _stored() async {
  final sp = await SharedPreferences.getInstance();
  final raw = sp.getString(_prefsKey) ?? '[]';
  return (jsonDecode(raw) as List)
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DeliveryOfflineQueue q;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // A fresh queue over an empty store: every test starts where a rider who
    // has never queued anything starts.
    q = DeliveryOfflineQueue.forTest();
  });

  test('an unreachable backend queues the action instead of losing it', () async {
    final before = q.pending.value;

    final res = await q.send('mark_delivered', {
      'delivery_id': 'd-1',
      'receiver': 'Ravi',
    });

    // The refusal is honest: not ok, and explicitly `queued` — never a fake
    // success and never an exception thrown at the rider.
    expect(res['ok'], isFalse);
    expect(res['queued'], isTrue);
    expect(res['error'], 'queued_offline');
    // …and the sentence is the BACKEND's label. With no catalog loaded it is
    // empty, because this file is not allowed to invent wording.
    expect(res['message'], '');

    expect(q.pending.value, before + 1);
  });

  test('the action is persisted, with its own id and payload, before sending',
      () async {
    await q.send('fail', {'delivery_id': 'd-2', 'reason_code': 'closed'});

    final rows = await _stored();
    expect(rows, hasLength(1));
    expect(rows.single['action'], 'fail');
    expect(rows.single['payload']['delivery_id'], 'd-2');
    expect(rows.single['payload']['reason_code'], 'closed');
    expect((rows.single['client_action_id'] as String).isNotEmpty, isTrue);
  });

  test('every action gets a DIFFERENT client_action_id, in the order it happened',
      () async {
    await q.send('scan_qr', {'token': 't1'});
    await q.send('scan_qr', {'token': 't2'});

    final rows = await _stored();
    expect(rows, hasLength(2));
    expect(rows[0]['payload']['token'], 't1');
    expect(rows[1]['payload']['token'], 't2');
    expect(rows[0]['client_action_id'], isNot(rows[1]['client_action_id']));
  });

  test('a drain that cannot reach the backend keeps everything queued', () async {
    await q.send('signature', {'delivery_id': 'd-3', 'signature_path': 's.png'});
    await q.send('location', {'lat': 21.25, 'lng': 81.63});
    expect(q.pending.value, 2);

    await q.drain();

    // Still offline: nothing was dropped and the order is untouched.
    final rows = await _stored();
    expect(rows, hasLength(2));
    expect(rows[0]['action'], 'signature');
    expect(rows[1]['action'], 'location');
    expect(q.pending.value, 2);
  });

  test('a restart finds the queue on disk', () async {
    await q.send('partial', {'delivery_id': 'd-4', 'delivered_qty': 2});

    // A new process reads the same store; the action survived the app dying.
    final rows = await _stored();
    expect(rows.single['action'], 'partial');
    expect(rows.single['payload']['delivered_qty'], 2);
  });
}
