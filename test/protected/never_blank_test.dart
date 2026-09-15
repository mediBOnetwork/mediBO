import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/services/payload_cache.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/widgets/stale_payload.dart';

/// CMD #1813 — the never-blank contract.
///
/// On 2026-09-06 every RPC in the app stalled together at ~13.9 s. The app's
/// own timeout fired at ~15 s and every affected screen painted an empty body
/// with a Retry button, in front of customers. This file is what stops that
/// class of screen from coming back:
///
///   * there is NO state — not even a cold start with a dead backend — in
///     which the app offers a bare Retry button,
///   * a failed refresh NEVER takes the last good payload off the screen,
///   * every word the layer prints is a `ui_copy` string, and every timing it
///     obeys is a `ui_copy` number, so the fixtures below deliberately say
///     things a Dart literal would never say,
///   * and a screen that has never loaded still shows a live, self-retrying
///     skeleton rather than a dead end.
void main() {
  // Every fixture string is deliberately NOT the sentence a Dart fallback
  // would contain, so any hardcoded copy fails instead of coincidentally
  // matching. The timings are milliseconds so the tests stay on the VM.
  const copy = <String, String>{
    'net.updating': 'ZZ-UPDATING',
    'net.saved_copy': 'ZZ-SAVED-COPY',
    'net.first_try': 'ZZ-FIRST-TRY',
    'net.first_retry': 'ZZ-FIRST-RETRY',
    'net.retry_backoff_ms': '10,20,40',
    'net.slow_after_ms': '5',
    'net.rpc_timeout_ms': '200',
  };

  setUp(() {
    UiCopy.debugSet(copy);
    PayloadStore.diskEnabled = false;
    PayloadStore.debugClear();
  });

  tearDown(() {
    PayloadStore.diskEnabled = true;
    PayloadStore.debugClear();
  });

  group('PayloadState — the contract, stated once', () {
    test('there is no state in which a Retry button is offered', () {
      const states = <PayloadState>[
        PayloadState(),
        PayloadState(loading: true),
        PayloadState(failures: 9),
        PayloadState(data: {'a': 1}, source: PayloadSource.cache, failures: 4),
        PayloadState(data: {'a': 1}, source: PayloadSource.network),
      ];
      for (final s in states) {
        expect(s.showRetryButton, isFalse,
            reason: 'a bare Retry button is the defect this change removes');
      }
    });

    test('a fresh payload that is not refreshing says nothing at all', () {
      const s = PayloadState(data: {'a': 1}, source: PayloadSource.network);
      expect(s.statusKey, '');
      expect(s.showStatusLine, isFalse);
      expect(s.hasBody, isTrue);
      expect(s.showSkeleton, isFalse);
      expect(s.isStale, isFalse);
    });

    test('a slow refresh over a good payload prints the BACKEND updating line',
        () {
      const s = PayloadState(
          data: {'a': 1}, source: PayloadSource.network, loading: true);
      expect(s.statusKey, 'net.updating');
      expect(s.statusLine, 'ZZ-UPDATING');
      expect(s.hasBody, isTrue, reason: 'the body must not go away');
    });

    test('a FAILED refresh keeps the body and switches to the saved-copy line',
        () {
      const s = PayloadState(
          data: {'a': 1}, source: PayloadSource.cache, failures: 3);
      expect(s.hasBody, isTrue);
      expect(s.isStale, isTrue);
      expect(s.statusKey, 'net.saved_copy');
      expect(s.statusLine, 'ZZ-SAVED-COPY');
      expect(s.showRetryButton, isFalse);
    });

    test('a cold start is a live skeleton, never a dead end', () {
      const first = PayloadState();
      expect(first.showSkeleton, isTrue);
      expect(first.statusLine, 'ZZ-FIRST-TRY');

      const failing = PayloadState(failures: 2);
      expect(failing.showSkeleton, isTrue);
      expect(failing.statusLine, 'ZZ-FIRST-RETRY');
      expect(failing.showRetryButton, isFalse);
    });

    test('an unknown copy key renders empty, never a Dart sentence', () {
      UiCopy.debugSet(const {});
      const s = PayloadState(data: {'a': 1}, loading: true);
      expect(s.statusKey, 'net.updating');
      expect(s.statusLine, '');
      expect(s.showStatusLine, isFalse);
    });
  });

  group('PayloadTiming — the backend owns how hard the app tries', () {
    test('the backoff ladder is the payload, and its last entry is the ceiling',
        () {
      expect(PayloadTiming.backoffMs, [10, 20, 40]);
      expect(PayloadTiming.delayFor(1).inMilliseconds, 10);
      expect(PayloadTiming.delayFor(2).inMilliseconds, 20);
      expect(PayloadTiming.delayFor(3).inMilliseconds, 40);
      expect(PayloadTiming.delayFor(99).inMilliseconds, 40,
          reason: 'past the end of the ladder the app holds the ceiling');
    });

    test('slow-after and the attempt timeout are the payload too', () {
      expect(PayloadTiming.slowAfter.inMilliseconds, 5);
      expect(PayloadTiming.attemptTimeout.inMilliseconds, 200);
    });

    test('a missing or unusable schedule still retries — it never stops', () {
      UiCopy.debugSet(const {'net.retry_backoff_ms': 'nonsense,,-4'});
      expect(PayloadTiming.backoffMs.first, greaterThan(0));
      expect(PayloadTiming.delayFor(1).inMilliseconds, greaterThan(0));
    });
  });

  group('PayloadController — a bad minute never empties a screen', () {
    test('a success stores the payload and clears the failure count', () async {
      final ctl = PayloadController(
        cacheKey: 'k1',
        fetch: () async => {'v': 'fresh'},
      );
      await ctl.start();
      expect(ctl.state.data, {'v': 'fresh'});
      expect(ctl.state.source, PayloadSource.network);
      expect(ctl.state.failures, 0);
      expect(await PayloadStore.read('k1'), isNotNull);
      ctl.dispose();
    });

    test('a cached payload paints BEFORE the network answers', () async {
      PayloadStore.debugSeed('k2', {'v': 'from-disk'});
      final seen = <String>[];
      final ctl = PayloadController(
        cacheKey: 'k2',
        fetch: () async {
          // The controller must already be showing the cache by now.
          seen.add((_lastData ?? const {})['v']?.toString() ?? '');
          return {'v': 'from-network'};
        },
      );
      ctl.addListener(() => _lastData = ctl.state.data);
      await ctl.start();
      expect(seen.single, 'from-disk',
          reason: 'the disk copy must be on screen while the RPC is running');
      expect(ctl.state.data, {'v': 'from-network'});
      expect(ctl.state.source, PayloadSource.network);
      ctl.dispose();
    });

    test('a throwing fetch leaves the last good payload exactly where it was',
        () async {
      PayloadStore.debugSeed('k3', {'v': 'last-good'});
      var calls = 0;
      final ctl = PayloadController(
        cacheKey: 'k3',
        fetch: () async {
          calls++;
          throw StateError('backend having a bad minute');
        },
      );
      await ctl.start();
      expect(calls, 1);
      expect(ctl.state.data, {'v': 'last-good'},
          reason: 'a failure must never take the body away');
      expect(ctl.state.failures, 1);
      expect(ctl.state.statusKey, 'net.saved_copy');
      expect(ctl.state.showRetryButton, isFalse);

      // And it retries by itself, on the backend's 10 ms first step.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls, greaterThan(1),
          reason: 'nobody taps anything — the controller retries itself');
      ctl.dispose();
    });

    test('a null payload counts as a failure, not as an empty screen',
        () async {
      PayloadStore.debugSeed('k4', {'v': 'last-good'});
      final ctl = PayloadController(cacheKey: 'k4', fetch: () async => null);
      await ctl.start();
      expect(ctl.state.data, {'v': 'last-good'});
      expect(ctl.state.failures, 1);
      ctl.dispose();
    });

    test('an attempt that never returns times out on the BACKEND value',
        () async {
      final ctl = PayloadController(
        cacheKey: 'k5',
        fetch: () => Future<Map<String, dynamic>?>.delayed(
            const Duration(seconds: 30), () => {'v': 'too-late'}),
      );
      final started = DateTime.now();
      await ctl.start();
      final ms = DateTime.now().difference(started).inMilliseconds;
      expect(ms, lessThan(2000),
          reason: 'the 200 ms attempt timeout in the fixture must be obeyed');
      expect(ctl.state.failures, 1);
      expect(ctl.state.showRetryButton, isFalse);
      ctl.dispose();
    });
  });

  group('the widgets draw the contract and nothing else', () {
    Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('the status line prints the backend sentence verbatim',
        (t) async {
      await t.pumpWidget(host(const PayloadStatusLine(
        state: PayloadState(
            data: {'a': 1}, source: PayloadSource.cache, failures: 2),
      )));
      expect(find.text('ZZ-SAVED-COPY'), findsOneWidget);
      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('nothing is drawn when there is nothing to say', (t) async {
      await t.pumpWidget(host(const PayloadStatusLine(
        state: PayloadState(data: {'a': 1}, source: PayloadSource.network),
      )));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('a stale body is still THE body, with the line above it',
        (t) async {
      await t.pumpWidget(host(NeverBlankBody(
        state: const PayloadState(
            data: {'title': 'ZZ-BODY'},
            source: PayloadSource.cache,
            failures: 1),
        builder: (_, d) => Text(d['title'] as String),
        skeleton: const Text('ZZ-SKELETON'),
      )));
      expect(find.text('ZZ-BODY'), findsOneWidget);
      expect(find.text('ZZ-SKELETON'), findsNothing);
      expect(find.text('ZZ-SAVED-COPY'), findsOneWidget);
    });

    testWidgets('a cold start shows the skeleton AND stays alive', (t) async {
      await t.pumpWidget(host(NeverBlankBody(
        state: const PayloadState(failures: 1),
        builder: (_, d) => const Text('ZZ-BODY'),
        skeleton: const Text('ZZ-SKELETON'),
      )));
      expect(find.text('ZZ-SKELETON'), findsOneWidget);
      expect(find.text('ZZ-BODY'), findsNothing);
      expect(find.text('ZZ-FIRST-RETRY'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // The one thing that must never be here.
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('the strip is drawn from tokens, never from literals',
        (t) async {
      await t.pumpWidget(host(const PayloadStatusLine(
        state: PayloadState(data: {'a': 1}, loading: true),
      )));
      final box = t.widget<Container>(find.byType(Container).first);
      expect((box.color), Ds.c.bg,
          reason: 'a refreshing strip is quiet, not an alarm');
    });
  });
}

/// Scratch used by the cache-before-network test.
Map<String, dynamic>? _lastData;
