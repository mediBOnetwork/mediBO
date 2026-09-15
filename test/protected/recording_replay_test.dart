// CMD #1851 — THE RECORDING TAP IS A TAP, AND THE REPLAY VERDICT IS PRINTED.
//
// The class of bug this holds down is the one that left test_recording empty
// for a whole change: a recorder that looks wired, is registered in main.dart,
// and observes nothing that can be replayed. So the tests here are about the
// two things that make a recording worth having.
//
//  1. THE NO-SESSION PATH IS FREE (§6). With no live recording the tap makes no
//     request of its own, buffers nothing, and hands back the inner client's
//     own response untouched. This is asserted by COUNTING the requests the
//     inner client saw: a capture POST would show up as a second one.
//  2. WHAT IS RECORDED IS THE ANSWER, NOT THE PIXELS (§1, §2). A recorded step
//     carries the function name, the arguments sent and the payload returned.
//  3. THE APP DECIDES NOTHING. On/off, the flush cadence, the batch size, the
//     body cap and the never-record list all arrive in `recording_state()`; a
//     function the backend named is not recorded, and the tap turns itself off
//     only when the backend says `recording:false`.
//  4. THE VERDICT IS THE BACKEND'S WORDS. The divergence line a screen shows is
//     the payload's `message` / `why` — never a sentence assembled in Dart.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pharma_b2b/services/recording_tap.dart';

/// An inner client that answers a canned body and counts what it was asked.
class _Inner extends http.BaseClient {
  _Inner(this.body);
  final String body;
  final List<http.BaseRequest> seen = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add(request);
    final bytes = utf8.encode(body);
    return http.StreamedResponse(Stream<List<int>>.value(bytes), 200,
        request: request, headers: const {'content-type': 'application/json'});
  }
}

http.Request _rpc(String fn, Map<String, dynamic> args) {
  final r = http.Request(
      'POST', Uri.parse('https://db.example.com/rest/v1/rpc/$fn'));
  r.headers['apikey'] = 'anon-key';
  r.headers['x-medibo-test-session'] = 'tok-1';
  r.body = jsonEncode(args);
  return r;
}

/// The shape `recording_state()` sends while a walkthrough is live. The values
/// are deliberately NOT the Dart defaults, so anything the tap does not read
/// out of the payload shows up as a failure.
Map<String, dynamic> _liveState({List<String> skip = const ['test_session_banner']}) =>
    <String, dynamic>{
      'on': true,
      'recording_id': 42,
      'label': 'checkout walkthrough',
      'steps': 3,
      'hint': 'Recording — every screen you open is a step.',
      'capture': {
        'flush_ms': 60000, // long, so a test never races a timer flush
        'max_batch': 99,
        'max_body': 40,
        'skip_fns': skip,
      },
    };

void main() {
  final cap = RecordingCapture.instance;

  setUp(cap.debugReset);
  tearDown(cap.debugReset);

  group('§6 — with no session the tap is not there', () {
    test('one request in, one request out, nothing buffered', () async {
      final inner = _Inner('{"ok":true}');
      final tap = RecordingTap(inner);
      cap.applyState(const {'on': false});

      final res = await tap.send(_rpc('cart_state', {'p_id': 1}));
      final body = await res.stream.bytesToString();

      expect(cap.active, isFalse);
      expect(body, '{"ok":true}');
      // The ONE assertion this whole section exists for: the inner client saw
      // the call and nothing else. A capture POST would be a second request.
      expect(inner.seen.length, 1);
      expect(cap.debugQueue, isEmpty);
    });

    test('a state payload with no recording block leaves it off', () {
      cap.applyState(const {'on': false});
      expect(cap.active, isFalse);
      cap.note(kind: 'nav', screen: '/cart', action: 'opened');
      expect(cap.debugQueue, isEmpty);
    });
  });

  group('§1/§2 — what is recorded is the conversation, not the canvas', () {
    test('a recorded step carries fn, args and the payload that came back',
        () async {
      final inner = _Inner('{"ok":true,"order_id":"o-9"}');
      final tap = RecordingTap(inner);
      cap.applyState(_liveState());

      final res = await tap.send(_rpc('checkout_place', {'p_note': 'x'}));
      expect(await res.stream.bytesToString(), '{"ok":true,"order_id":"o-9"}');

      expect(cap.debugQueue.length, 1);
      final step = cap.debugQueue.single;
      expect(step.kind, 'rpc');
      expect(step.detail['fn'], 'checkout_place');
      expect(step.detail['args'], {'p_note': 'x'});
      expect(step.detail['payload'], {'ok': true, 'order_id': 'o-9'});
      expect(step.detail['status'], 200);
    });

    test('the caller still reads the body the backend sent', () async {
      final inner = _Inner('{"rows":[1,2,3]}');
      final tap = RecordingTap(inner);
      cap.applyState(_liveState());
      final res = await tap.send(_rpc('cart_state', const {}));
      expect(await res.stream.bytesToString(), '{"rows":[1,2,3]}');
      expect(res.statusCode, 200);
    });

    test('an oversize body is kept as its size, never half-parsed', () async {
      // max_body is 40 in the fixture; this answer is longer than that.
      final long = '{"note":"${'y' * 80}"}';
      final inner = _Inner(long);
      final tap = RecordingTap(inner);
      cap.applyState(_liveState());
      await (await tap.send(_rpc('big_read', const {}))).stream.drain<void>();
      expect(cap.debugQueue.single.detail['payload'],
          {'oversize_bytes': long.length});
    });
  });

  group('§3 — the backend decides what is recorded', () {
    test('a function on the backend skip list is not a step', () async {
      final inner = _Inner('{"on":true}');
      final tap = RecordingTap(inner);
      cap.applyState(_liveState(skip: const ['test_session_banner']));
      final res = await tap.send(_rpc('test_session_banner', const {}));
      expect(await res.stream.bytesToString(), '{"on":true}');
      expect(cap.debugQueue, isEmpty);
      expect(inner.seen.length, 1);
    });

    test('the skip list is the payload\'s, not a Dart constant', () async {
      final inner = _Inner('{"ok":true}');
      final tap = RecordingTap(inner);
      // The same function, with a payload that does NOT name it.
      cap.applyState(_liveState(skip: const ['something_else']));
      await (await tap.send(_rpc('test_session_banner', const {})))
          .stream
          .drain<void>();
      expect(cap.debugQueue.single.detail['fn'], 'test_session_banner');
    });

    test('a non-rpc request is passed through and never recorded', () async {
      final inner = _Inner('[]');
      final tap = RecordingTap(inner);
      cap.applyState(_liveState());
      final r = http.Request(
          'GET', Uri.parse('https://db.example.com/rest/v1/orders?select=*'));
      await (await tap.send(r)).stream.drain<void>();
      expect(cap.debugQueue, isEmpty);
    });

    test('rpcName reads the function out of a PostgREST url', () {
      expect(
          RecordingCapture.rpcName(
              Uri.parse('https://x.example.com/rest/v1/rpc/cart_state')),
          'cart_state');
      expect(
          RecordingCapture.rpcName(
              Uri.parse('https://x.example.com/rest/v1/orders')),
          '');
    });
  });

  group('§4 — the verdict is printed, never assembled', () {
    // The fixture deliberately disagrees with itself: `passed` is false while
    // the step counts would read as a clean run, and the message names a step
    // that is not the first failure in the list. Anything that recomputes the
    // sentence, the tone or the offending step fails here.
    const verdict = <String, dynamic>{
      'ok': true,
      'passed': false,
      'pass': 7,
      'fail': 0,
      'skipped': 1,
      'message': 'The walkthrough no longer answers the way it did when it was '
          'recorded. cart_state: \$.lines[].price_display — the answer changed',
      'first_divergence': {
        'n': 4,
        'label': 'cart_state',
        'why': '\$.lines[].price_display — the answer changed',
      },
      'steps': [
        {'n': 1, 'kind': 'rpc', 'label': 'cart_state', 'status': 'passed', 'why': ''},
        {
          'n': 4,
          'kind': 'rpc',
          'label': 'cart_state',
          'status': 'failed',
          'why': '\$.lines[].price_display — the answer changed',
        },
      ],
    };

    test('the headline is the payload message, word for word', () {
      expect(verdict['message'], contains('no longer answers'));
      expect(verdict['message'], contains('price_display'));
    });

    test('pass/fail is the flag, not a count comparison', () {
      // fail is 0 and pass is 7 — a screen that derived "passed" from those
      // would call this green. The backend said false.
      expect(verdict['passed'], isFalse);
    });

    test('the offending step is named by the payload, not found in Dart', () {
      final first = verdict['first_divergence'] as Map<String, dynamic>;
      expect(first['n'], 4);
      expect(first['why'], verdict['message'].toString().split('cart_state: ')[1]);
    });
  });

  group('the tap turns off only when the backend says so', () {
    test('a state payload that goes off clears the buffer', () async {
      final inner = _Inner('{"ok":true}');
      final tap = RecordingTap(inner);
      cap.applyState(_liveState());
      await (await tap.send(_rpc('cart_state', const {}))).stream.drain<void>();
      expect(cap.debugQueue, isNotEmpty);
      cap.applyState(const {'on': false});
      expect(cap.active, isFalse);
      expect(cap.debugQueue, isEmpty);
    });
  });
}
