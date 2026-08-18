// CHANGE #273 — the Cron health screen prints the backend, and only the backend.
//
// The point of #273 is that an idle database costs nothing: 15 jobs on
// '* * * * *' became one dispatcher, and most ticks now skip every task on a
// cheap existence gate. This screen is how Om SEES that. So the thing worth
// pinning is that it invents none of it — the headline, each task's mode, state
// and counts, the guard summary and every tone arrive in the cron_health()
// payload and are rendered verbatim, in payload order.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/cron_health_screen.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';
import 'package:pharma_b2b/utils/render_log.dart';

class _FakeService extends DevQueueService {
  _FakeService(this.payload)
      // autoRefreshToken:false — GoTrue otherwise starts a 10s periodic timer
      // that outlives the widget tree and trips flutter_test's !timersPending.
      : super(
            client: SupabaseClient('http://localhost:1', 'test-key',
                authOptions:
                    const AuthClientOptions(autoRefreshToken: false)));

  final Map<String, dynamic> payload;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> cronHealth() async {
    calls++;
    return payload;
  }
}

Map<String, dynamic> _payload() => {
      'ok': true,
      'title': 'Cron health',
      'headline': '51 cron jobs · 1 per-minute · peak 4 concurrent in the last hour',
      'tick': {
        'label': 'Last dispatcher tick',
        'at_label': '18 Aug 18:22:00',
        'value_label': '3 ran · 11 skipped as idle · 0 failed · 70 ms',
        'tone': 'success',
      },
      'runs_last_hour': 60,
      'db_seconds_last_hour': 4.2,
      'peak_concurrent': 4,
      // deliberately NOT alphabetical — the backend's order is the order
      'tasks': [
        {
          'name': 'order_hours',
          'mode_label': 'Time-bound',
          'state_label': 'Idle - never needed yet',
          'counts_label': '0 run · 8 skipped as idle',
          'tone': 'success',
          'error': null,
          'note': 'No row can announce "it is now 09:00".',
        },
        {
          'name': 'orphan_inquiry_cleanup',
          'mode_label': 'Event-driven',
          'state_label': 'Last ran 18 Aug 18:15 IST · 16 ms',
          'counts_label': '1 run · 3 skipped as idle',
          'tone': 'info',
          'error': null,
          'note': 'Orphans exist only because order_items rows were deleted.',
        },
        {
          'name': 'route_plan_drain',
          'mode_label': 'Event-driven',
          'state_label': 'Last run failed',
          'counts_label': '2 run · 0 skipped as idle',
          'tone': 'error',
          'error': 'canceling statement due to statement timeout',
          'note': 'An admin queueing a plan is the event.',
        },
      ],
      'guard': {
        'label': 'Guard',
        'value_label': 'max 6 concurrent · 15 refusal/repair events in 7 days',
        'recent': [
          {
            'at_label': '18 Aug 18:15',
            'kind': 'repaired',
            'job': 'zone_backfill',
            'detail': "was '* * * * *' - moved to '3-59/10 * * * *'.",
          },
        ],
      },
    };

Future<void> _pump(WidgetTester tester, _FakeService svc) async {
  // Tall surface: the screen is a ListView, so a card below the fold is never
  // built and `find` would report an ordering bug that does not exist.
  await tester.binding.setSurfaceSize(const Size(900, 3000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: CronHealthScreen(service: svc)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  test('the screen has a URL, so a deploy can actually prove it painted', () {
    // Flutter canvas taps are banned (CLAUDE.md), so without this route
    // c273_cron_health would sit at 0 forever and "it rendered" could only ever
    // be argued from a string in the bundle. Same lesson as #240.
    final main = File('lib/main.dart').readAsStringSync();
    expect(main.contains("name == '/admin/cron-health'"), isTrue,
        reason: 'the /admin/cron-health route is gone — Cron health can no '
            'longer be opened or proven by the post-deploy verifier');
    expect(main.contains('CronHealthScreen()'), isTrue,
        reason: 'the route no longer builds the Cron health screen');
  });

  testWidgets('the headline and the tick line are backend strings, printed verbatim',
      (tester) async {
    final svc = _FakeService(_payload());
    await _pump(tester, svc);

    expect(svc.calls, 1);
    expect(
        find.text('51 cron jobs · 1 per-minute · peak 4 concurrent in the last hour'),
        findsOneWidget);
    expect(find.text('3 ran · 11 skipped as idle · 0 failed · 70 ms'),
        findsOneWidget);
    expect(find.text('Last dispatcher tick'), findsOneWidget);
  });

  testWidgets('every task renders in PAYLOAD order, not sorted', (tester) async {
    await _pump(tester, _FakeService(_payload()));

    final names = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((d) => d == 'order_hours' ||
            d == 'orphan_inquiry_cleanup' ||
            d == 'route_plan_drain')
        .toList();

    expect(names, ['order_hours', 'orphan_inquiry_cleanup', 'route_plan_drain'],
        reason: 'the backend chose ord; sorting them in Dart would hide it');
  });

  testWidgets('a task prints the backend state, counts and mode - never its own',
      (tester) async {
    await _pump(tester, _FakeService(_payload()));

    expect(find.text('Idle - never needed yet'), findsOneWidget);
    expect(find.text('1 run · 3 skipped as idle'), findsOneWidget);
    expect(find.text('Event-driven'), findsNWidgets(2));
    expect(find.text('Time-bound'), findsOneWidget);
  });

  testWidgets('a failing task shows the backend error text', (tester) async {
    await _pump(tester, _FakeService(_payload()));
    expect(find.text('canceling statement due to statement timeout'),
        findsOneWidget);
  });

  testWidgets('tones come from the payload, never from the task name',
      (tester) async {
    await _pump(tester, _FakeService(_payload()));

    final chips = tester.widgetList<ToneChip>(find.byType(ToneChip)).toList();
    // tick chip + one per task
    expect(chips.length, 4);
    expect(chips[2].tone, toneByName('info'),
        reason: 'orphan_inquiry_cleanup carried tone:info');
    expect(chips[3].tone, toneByName('error'),
        reason: 'route_plan_drain carried tone:error');
  });

  testWidgets('the guard block prints its own summary and each recent event',
      (tester) async {
    await _pump(tester, _FakeService(_payload()));

    expect(find.text('max 6 concurrent · 15 refusal/repair events in 7 days'),
        findsOneWidget);
    expect(find.text('18 Aug 18:15 · repaired · zone_backfill'), findsOneWidget);
    expect(find.text("was '* * * * *' - moved to '3-59/10 * * * *'."),
        findsOneWidget);
  });

  testWidgets('an empty task list is an empty screen, not a crash',
      (tester) async {
    final p = _payload()
      ..['tasks'] = <Map<String, dynamic>>[]
      ..['guard'] = {'label': 'Guard', 'value_label': 'max 6 concurrent', 'recent': []};
    await _pump(tester, _FakeService(p));

    expect(find.byType(ToneChip), findsOneWidget); // just the tick chip
    expect(find.text('max 6 concurrent'), findsOneWidget);
  });
}
