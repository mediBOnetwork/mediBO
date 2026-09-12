// CMD #1940 — the deploy-lock waiter queue block renders ONE payload verbatim:
// holder label/tone, waiters in PAYLOAD order (never re-sorted), each waiter's
// own position and next-check strings, the interval sentence; has:false draws
// nothing; the intervals tap is the only decision and it is the caller's.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_deploy_wait.dart';
import 'package:pharma_b2b/utils/render_log.dart';

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  final payload = <String, dynamic>{
    'has': true,
    'title': 'Deploy lock queue',
    'holder': {
      'label': 'deploy lock — #1934',
      'tone': 'warning',
      'detail': 'CMD #1934: Order cut-off screen · frees in ~612s',
      'busy': true,
    },
    'count': 3,
    'count_label': '3 commands asleep in the queue',
    // Deliberately NOT in id order: the backend's position order is the order.
    'waiters': [
      {
        'command_id': 1943,
        'label': '#1943 · QA #1940 waiter B',
        'position_label': '#1',
        'kind_label': 'deploy lock',
        'detail': 'qa-1940-b · deploy lock · waiting 31s · next check 20:58',
        'tone': 'info',
      },
      {
        'command_id': 1942,
        'label': '#1942 · QA #1940 waiter A',
        'position_label': '#2',
        'kind_label': 'deploy lock',
        'detail': 'qa-1940-a · deploy lock · waiting 34s · next check 21:03',
        'tone': 'info',
      },
      {
        'command_id': 1945,
        'label': '#1945 · QA #1940 lease waiter D',
        'position_label': '',
        'kind_label': 'file lease',
        'detail': 'qa-1940-d · file lease · waiting 30s · next check 20:59',
        'tone': 'neutral',
      },
    ],
    'intervals': {
      'minutes_by_position': [2, 5, 5, 10],
      'safety_poll_minutes': 15,
      'urgent_jumps': true,
      'label':
          'Safety check by position: 2 · 5 · 5 · 10 min (last repeats) · ceiling 15 min',
      'urgent_label': 'Urgent commands jump to the head',
      'edit_label': 'Edit intervals',
      'push_label': 'Woken by pg_notify on release — 0 tokens while asleep',
    },
  };

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets('holder, waiters in payload order, next-check and intervals are verbatim',
      (tester) async {
    var edits = 0;
    await tester.pumpWidget(host(DeployWaitBlock(
      data: payload,
      onEditIntervals: () => edits++,
    )));

    expect(find.text('Deploy lock queue'), findsOneWidget);
    expect(find.text('deploy lock — #1934'), findsOneWidget);
    expect(find.text('CMD #1934: Order cut-off screen · frees in ~612s'),
        findsOneWidget);
    expect(find.text('3 commands asleep in the queue'), findsOneWidget);

    // Payload order wins: B (#1) sits above A (#2), which sits above the lease
    // waiter — even though A has the lower id.
    final yB = tester.getTopLeft(find.text('#1943 · QA #1940 waiter B')).dy;
    final yA = tester.getTopLeft(find.text('#1942 · QA #1940 waiter A')).dy;
    final yD = tester.getTopLeft(find.text('#1945 · QA #1940 lease waiter D')).dy;
    expect(yB < yA, isTrue, reason: 'position 1 above position 2');
    expect(yA < yD, isTrue, reason: 'lock waiters above lease waiters');

    // The pill is the backend's position label; a lease sleeper shows its kind.
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
    expect(find.text('file lease'), findsOneWidget);

    // Next-check time arrives inside the backend's own detail line, untouched.
    expect(
        find.text('qa-1940-b · deploy lock · waiting 31s · next check 20:58'),
        findsOneWidget);
    expect(
        find.text(
            'Safety check by position: 2 · 5 · 5 · 10 min (last repeats) · ceiling 15 min'),
        findsOneWidget);
    expect(find.text('Urgent commands jump to the head'), findsOneWidget);
    expect(find.text('Woken by pg_notify on release — 0 tokens while asleep'),
        findsOneWidget);

    await tester.tap(find.byIcon(Icons.tune));
    expect(edits, 1);
  });

  testWidgets('has:false draws nothing; an empty queue prints the backend empty line',
      (tester) async {
    await tester.pumpWidget(host(const DeployWaitBlock(data: {'has': false})));
    expect(find.byType(Text), findsNothing);

    await tester.pumpWidget(host(const DeployWaitBlock(data: {
      'has': true,
      'title': 'Deploy lock queue',
      'holder': {'label': 'deploy lock — free', 'tone': 'success', 'detail': ''},
      'count': 0,
      'count_label':
          'Nobody is waiting — the next deploy takes the lock straight away.',
      'waiters': [],
      'intervals': {},
    })));
    expect(
        find.text(
            'Nobody is waiting — the next deploy takes the lock straight away.'),
        findsOneWidget);
    expect(find.text('deploy lock — free'), findsOneWidget);
    expect(find.byIcon(Icons.tune), findsNothing,
        reason: 'no editor callback → no editor affordance');
  });

  test('the minutes field only parses; it never invents a list', () {
    expect(parseMinutesByPosition('2, 5,5,10'), [2, 5, 5, 10]);
    expect(parseMinutesByPosition('2 · 5 · 5 · 10'), [2, 5, 5, 10]);
    expect(parseMinutesByPosition('3'), [3]);
    expect(parseMinutesByPosition(''), isNull);
    expect(parseMinutesByPosition('2, x'), isNull);
    expect(parseMinutesByPosition('0, 5'), isNull);
  });
}
