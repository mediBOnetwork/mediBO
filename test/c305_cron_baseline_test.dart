// CHANGE #305 — the execution baseline section on the Cron health screen.
//
// #305's whole deliverable is a NUMBER: 57 pg_cron jobs and 8,335 executions a
// day became one dispatcher. The screen that reports that number is the one
// place the claim could quietly become a Dart-side calculation, so what this
// pins is that it never is. Every figure, every sentence and every tone in the
// section arrives inside `baseline` and is printed verbatim, in payload order —
// and a payload that carries no baseline draws no section at all, rather than a
// reassuring "0 per hour" nobody measured.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/cron_health_screen.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';
import 'package:pharma_b2b/utils/render_log.dart';

class _FakeService extends DevQueueService {
  _FakeService(this.payload)
      : super(
          client: SupabaseClient(
            'http://localhost:1',
            'test-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          ),
        );

  final Map<String, dynamic> payload;

  @override
  Future<Map<String, dynamic>> cronHealth() async => payload;
}

Map<String, dynamic> _base({Map<String, dynamic>? baseline}) => {
  'ok': true,
  'title': 'Cron health',
  'headline': '2 cron jobs · 1 per-minute · peak 1 concurrent in the last hour',
  'tick': {
    'label': 'Last dispatcher tick',
    'at_label': '31 Aug 02:15:00',
    'value_label': '4 ran · 11 skipped as idle · 0 failed · 135 ms',
    'tone': 'success',
  },
  'runs_last_hour': 60,
  'db_seconds_last_hour': 8.1,
  'peak_concurrent': 1,
  if (baseline != null) 'baseline': baseline,
  'tasks': const [],
  'guard': {'label': 'Guard', 'value_label': 'max 6 concurrent', 'recent': []},
};

Map<String, dynamic> _baseline() => {
  'label': 'Execution baseline',
  'note': 'Before = frozen at 31 Aug 02:02 IST, immediately before the cutover.',
  'before_head': 'Before',
  'after_head': 'Now',
  'alert': {
    'tone': 'success',
    'text': '59.8 executions per hour, inside the 60 target.',
  },
  // Deliberately NOT the order a Dart sort would pick.
  'rows': const [
    {
      'metric': 'Active pg_cron jobs',
      'before': '57',
      'after': '2',
      'note': 'Everything else is a row in cron_task.',
    },
    {
      'metric': 'Executions per hour',
      'before': '347.3',
      'after': '59.8',
      'note': 'Target is under 60.',
    },
    {
      'metric': 'Executions per day',
      'before': '8335',
      'after': '1435',
      'note': 'What filled 17,289 Postgres requests a day.',
    },
  ],
  'tasks_head': 'Per task, last 24 hours',
  'tasks_note': 'Checks are dispatcher evaluations.',
  // zebra: a worked task, a fully idle task, a failing task
  'tasks': const [
    {
      'name': 'wa_notify_sweep',
      'per_day_label': '3 run · 144 checked',
      'idle_label': '98% idle',
      'interval_label': 'every 10 min',
      'avg_ms_label': '21 ms average',
      'tone': 'success',
      'error': null,
    },
    {
      'name': 'lead-pipeline',
      'per_day_label': '0 run · 96 checked',
      'idle_label': '100% idle',
      'interval_label': 'every 60 min · backed off from 15 min',
      'avg_ms_label': 'no run yet',
      'tone': 'info',
      'error': null,
    },
    {
      'name': 'route_plan_drain',
      'per_day_label': '1 run · 2 checked',
      'idle_label': '50% idle',
      'interval_label': 'event-driven',
      'avg_ms_label': '9 ms average',
      'tone': 'error',
      'error': 'canceling statement due to statement timeout',
    },
  ],
};

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  // Tall surface: the section is inside a ListView, so a card below the fold is
  // never built and `find` would report an ordering bug that does not exist.
  await tester.binding.setSurfaceSize(const Size(900, 4000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(home: CronHealthScreen(service: _FakeService(payload))),
  );
  await tester.pumpAndSettle();
}

/// Reads every rendered Text in tree order — the only honest way to assert
/// "in payload order" rather than merely "present somewhere".
List<String> _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.isNotEmpty)
    .toList();

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every baseline figure is the backend string, printed verbatim', (
    tester,
  ) async {
    await _pump(tester, _base(baseline: _baseline()));

    expect(find.text('Execution baseline'), findsOneWidget);
    // The two headline numbers this command exists to change.
    expect(find.text('57'), findsOneWidget);
    expect(find.text('347.3'), findsOneWidget);
    expect(find.text('8335'), findsOneWidget);
    expect(find.text('1435'), findsOneWidget);
    // 59.8 is a string in the payload. If Dart ever recomputed it from
    // 1435/24 it would render 59.79166..., so exact-match is the guard.
    expect(find.text('59.8'), findsOneWidget);
    // Every metric name and note is the backend's own wording.
    expect(find.text('Executions per hour'), findsOneWidget);
    expect(find.text('Target is under 60.'), findsOneWidget);
    expect(
      find.text('What filled 17,289 Postgres requests a day.'),
      findsOneWidget,
    );
    // The column heads are the payload's, not 'Before'/'After' literals in Dart.
    expect(find.text('Now'), findsWidgets);
  });

  testWidgets('metric rows render in payload order, never sorted', (
    tester,
  ) async {
    await _pump(tester, _base(baseline: _baseline()));
    final t = _texts(tester);
    final jobs = t.indexOf('Active pg_cron jobs');
    final perHour = t.indexOf('Executions per hour');
    final perDay = t.indexOf('Executions per day');
    expect(jobs, greaterThanOrEqualTo(0));
    expect(jobs, lessThan(perHour));
    expect(perHour, lessThan(perDay));
  });

  testWidgets('the creep alarm prints the backend sentence, not a Dart verdict', (
    tester,
  ) async {
    await _pump(tester, _base(baseline: _baseline()));
    expect(
      find.text('59.8 executions per hour, inside the 60 target.'),
      findsOneWidget,
    );
  });

  // Its own test, not a second pump: CronHealthScreen keeps its State across a
  // pumpWidget of the same type, so a re-pump would re-assert the FIRST
  // payload and pass for the wrong reason.
  testWidgets('the over-target wording is the backend\'s too', (tester) async {
    final over = _baseline();
    over['alert'] = {
      'tone': 'warning',
      'text': '316.4 executions per hour, above the 60 target.',
    };
    await _pump(tester, _base(baseline: over));
    expect(
      find.text('316.4 executions per hour, above the 60 target.'),
      findsOneWidget,
    );
    // The screen does not decide what "above target" means; nothing else is added.
    expect(
      find.text('59.8 executions per hour, inside the 60 target.'),
      findsNothing,
    );
  });

  testWidgets('per-task stats are backend labels, in payload order', (
    tester,
  ) async {
    await _pump(tester, _base(baseline: _baseline()));
    expect(find.text('Per task, last 24 hours'), findsOneWidget);
    expect(find.text('wa_notify_sweep'), findsOneWidget);
    expect(find.text('3 run · 144 checked · 98% idle'), findsOneWidget);
    // The backoff is reported by the backend, never derived from the interval.
    expect(
      find.text('every 60 min · backed off from 15 min · no run yet'),
      findsOneWidget,
    );
    // A failing task shows the backend's error text.
    expect(
      find.text('canceling statement due to statement timeout'),
      findsOneWidget,
    );

    final t = _texts(tester);
    expect(
      t.indexOf('wa_notify_sweep'),
      lessThan(t.indexOf('lead-pipeline')),
    );
    expect(
      t.indexOf('lead-pipeline'),
      lessThan(t.indexOf('route_plan_drain')),
    );
  });

  testWidgets('no baseline in the payload draws no section at all', (
    tester,
  ) async {
    await _pump(tester, _base());
    expect(find.text('Execution baseline'), findsNothing);
    expect(find.text('Per task, last 24 hours'), findsNothing);
    // Absence must never be rendered as a comforting zero.
    expect(find.textContaining('per hour'), findsNothing);
    // The rest of the screen still renders.
    expect(find.text('Last dispatcher tick'), findsOneWidget);
  });

  testWidgets('an empty rows list is an absence, not an empty card', (
    tester,
  ) async {
    final empty = _baseline();
    empty['rows'] = const [];
    await _pump(tester, _base(baseline: empty));
    expect(find.text('Execution baseline'), findsNothing);
  });
}
