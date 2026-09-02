// CHANGE #641 / verified by #670 — the DB circuit breaker has to be VISIBLE.
//
// Ten database timeouts inside five minutes and the backend switches Workflow
// off by itself. That is the one state Om must never have to open a panel to
// discover, and it is composed entirely server-side by `_dev_breaker_badge()`:
// the label, the sentence, the IST timestamp inside the sentence, and the tone
// name. This suite holds down that the app PRINTS that verdict and computes
// none of it — the payloads below are the real ones captured from
// `dev_ctl_get().breaker` while the breaker was tripped.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';

/// Verbatim from the backend on 2026-09-02, ten timeouts in five minutes.
const _tripped = <String, dynamic>{
  'tripped': true,
  'tone': 'danger',
  'label': 'Auto-paused: DB timeouts',
  'detail': '10 database timeouts in 5 min — Workflow was switched off at '
      '02 Sep 22:31 IST so the runners stop adding load. Fix the slow call, '
      'then turn Workflow back on.',
  'at': '2026-09-02T17:01:51.974406+00:00',
  'count': 10,
  'window_min': 5,
};

/// What the same RPC returns when nothing is wrong.
const _quiet = <String, dynamic>{
  'tripped': false,
  'label': '',
  'detail': '',
  'tone': 'neutral',
};

Future<void> _pump(WidgetTester t, Map<String, dynamic> breaker) =>
    t.pumpWidget(MaterialApp(
      home: Scaffold(body: BreakerBanner(breaker: breaker)),
    ));

void main() {
  testWidgets('a tripped breaker prints the backend label and sentence verbatim',
      (t) async {
    await _pump(t, _tripped);
    expect(find.text(_tripped['label'] as String), findsOneWidget);
    expect(find.text(_tripped['detail'] as String), findsOneWidget);
    // The sentence carries the count, the window and the IST time the backend
    // formatted. Nothing in Dart may re-derive or re-word any of it.
    expect((_tripped['detail'] as String).contains('10 database timeouts'), isTrue);
    expect((_tripped['detail'] as String).contains('IST'), isTrue);
  });

  testWidgets('the badge is absent while the breaker is quiet', (t) async {
    await _pump(t, _quiet);
    expect(find.byType(Text), findsNothing);
    expect(find.byIcon(Icons.pause_circle_filled), findsNothing);
  });

  testWidgets('an absent breaker key renders nothing rather than throwing',
      (t) async {
    await _pump(t, const <String, dynamic>{});
    expect(t.takeException(), isNull);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('tripped:true with no label is still nothing — a badge with no '
      'words is worse than no badge', (t) async {
    await _pump(t, const <String, dynamic>{'tripped': true, 'label': ''});
    expect(find.byType(Text), findsNothing);
  });

  testWidgets("the backend's tone is honoured — 'danger' is not grey", (t) async {
    await _pump(t, _tripped);
    final box = t.widget<Container>(find
        .ancestor(of: find.byIcon(Icons.pause_circle_filled),
            matching: find.byType(Container))
        .first);
    final deco = box.decoration as BoxDecoration;
    // toneByName('danger') must resolve to the destructive tone, not to the
    // neutral fallback — a pause that renders grey reads as "fine".
    expect(deco.color, equals(toneByName('danger').bg));
    expect(deco.color, isNot(equals(toneByName('nonsense').bg)));
  });

  test("the widget shows the badge only on the backend's own flag", () {
    expect(BreakerBanner.tripped(_tripped), isTrue);
    expect(BreakerBanner.tripped(_quiet), isFalse);
    expect(BreakerBanner.tripped(null), isFalse);
    expect(BreakerBanner.tripped(const {'tripped': true, 'label': ''}), isFalse);
  });
}
