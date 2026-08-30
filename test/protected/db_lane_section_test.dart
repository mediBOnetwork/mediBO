// CHANGE #301 — the Database lane section.
//
// The DB coordination lane exists because the 1 GB instance stalls when several
// agents run heavy database work at once. The section that reports it must not
// become another place where a number is computed: every word — the headline,
// each stat, each lane caption, the empty state, the guardrail sentence, the
// night window and each alert line — is built by db_health_status() and printed
// verbatim, in payload order.
//
// What this holds down:
//   1. Payload order, and no locally worded anything.
//   2. An empty lane prints the backend's empty state; a held lane prints the
//      backend's own holder rows and drops the empty state.
//   3. ok:false renders the backend's refusal sentence and nothing else.
//   4. No alerts prints the backend's `quiet` line; alerts print their own copy.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/db_lane_section.dart';

Widget _host(Map<String, dynamic> data) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DbLaneSection(data: data)),
      ),
    );

Map<String, dynamic> _payload({
  List held = const [],
  List recent = const [],
}) =>
    {
      'ok': true,
      'title': 'Database lane',
      'tone': 'success',
      'headline': '18 of 60 connections · peak 22 in 24 h · 0 statement '
          'timeouts in the last 5 minutes',
      'sampled_label': 'Sampled 23 Aug 20:11:04 IST',
      'stats': [
        {'label': 'Connections', 'value': '18 / 60'},
        {'label': 'Longest transaction', 'value': '0 s'},
        {'label': 'Timeouts (5 min)', 'value': '0'},
      ],
      'lanes': [
        {
          'label': 'Exclusive — DDL, bulk writes over 20k rows, VACUUM, '
              'index builds',
          'value_label': '1 slot · free',
          'tone': 'success',
        },
        {
          'label': 'Heavy read — scans and audits over a big table',
          'value_label': '2 slots · 0 in use',
          'tone': 'success',
        },
      ],
      'held': held,
      'held_empty': 'No agent is holding a database lane.',
      'guard': {
        'label': 'Session guardrails',
        'value_label': 'statement 55 s · lock 5 s · idle-in-transaction 30 s',
      },
      'window': {
        'label': 'Heavy scheduled audits',
        'value_label': '8 jobs run in the 21:00–02:00 UTC window',
      },
      'alerts': {
        'label': 'Watchdog',
        'value_label': '0 database alerts in 7 days',
        'quiet': 'Quiet — no connection, transaction or timeout alert.',
        'recent': recent,
      },
    };

void main() {
  testWidgets('prints the backend payload verbatim, in payload order',
      (tester) async {
    await tester.pumpWidget(_host(_payload()));

    expect(find.text('Database lane'), findsOneWidget);
    expect(find.text('Sampled 23 Aug 20:11:04 IST'), findsOneWidget);
    expect(
        find.text('18 of 60 connections · peak 22 in 24 h · 0 statement '
            'timeouts in the last 5 minutes'),
        findsOneWidget);
    expect(find.text('18 / 60'), findsOneWidget);
    expect(find.text('1 slot · free'), findsOneWidget);
    expect(find.text('2 slots · 0 in use'), findsOneWidget);
    expect(find.text('statement 55 s · lock 5 s · idle-in-transaction 30 s'),
        findsOneWidget);
    expect(find.text('8 jobs run in the 21:00–02:00 UTC window'),
        findsOneWidget);

    // The exclusive lane is first in the payload, so it must paint above the
    // heavy-read lane. The section never sorts by name, slot count or tone.
    final ex = tester.getTopLeft(find.text('1 slot · free')).dy;
    final hr = tester.getTopLeft(find.text('2 slots · 0 in use')).dy;
    expect(ex, lessThan(hr));

    // Stats keep payload order too.
    final conns = tester.getTopLeft(find.text('Connections')).dx;
    final timeouts = tester.getTopLeft(find.text('Timeouts (5 min)')).dx;
    expect(conns, lessThan(timeouts));
  });

  testWidgets('an idle lane shows the backend empty state, not a Dart sentence',
      (tester) async {
    await tester.pumpWidget(_host(_payload()));
    expect(find.text('No agent is holding a database lane.'), findsOneWidget);
  });

  testWidgets('a held lane prints the holder rows and drops the empty state',
      (tester) async {
    await tester.pumpWidget(_host(_payload(held: [
      {
        'label': 'runner-2 · exclusive',
        'detail': '#288 migration · held 41 s · expires in 559 s',
        'tone': 'info',
      },
    ])));

    expect(find.text('runner-2 · exclusive'), findsOneWidget);
    expect(find.text('#288 migration · held 41 s · expires in 559 s'),
        findsOneWidget);
    expect(find.text('No agent is holding a database lane.'), findsNothing);
  });

  testWidgets('no alerts prints the backend quiet line; an alert prints its own',
      (tester) async {
    await tester.pumpWidget(_host(_payload()));
    expect(find.text('Quiet — no connection, transaction or timeout alert.'),
        findsOneWidget);

    await tester.pumpWidget(_host(_payload(recent: [
      {
        'at_label': '23 Aug 18:23',
        'severity': 'critical',
        'kind': 'db_statement_timeouts',
        'name': '40 statement timeouts in 5 minutes',
        'detail': 'seen 12 time(s) · first 23 Aug 18:12 IST',
      },
    ])));
    await tester.pumpAndSettle();

    expect(find.text('23 Aug 18:23 · 40 statement timeouts in 5 minutes'),
        findsOneWidget);
    expect(find.text('seen 12 time(s) · first 23 Aug 18:12 IST'),
        findsOneWidget);
    expect(find.text('Quiet — no connection, transaction or timeout alert.'),
        findsNothing);
  });

  testWidgets('ok:false renders the backend refusal and nothing else',
      (tester) async {
    await tester.pumpWidget(_host({
      'ok': false,
      'title': 'Database lane',
      'error': 'Only a super-admin can read the database lane.',
    }));

    expect(find.text('Only a super-admin can read the database lane.'),
        findsOneWidget);
    expect(find.text('1 slot · free'), findsNothing);
  });
}
