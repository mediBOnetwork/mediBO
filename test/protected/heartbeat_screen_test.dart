// PROTECTED — CHANGE #468.
//
// The daily heartbeat is the platform's canary, so the screen that reports it
// must never invent anything. Everything on it is a backend string: the status
// labels, the one-line summary, the stage names and their timeouts, the
// "artifacts cleaned up" sentence, the alert chip and the two button captions.
// If this file ever needs a Dart literal to make a case pass, the payload
// contract has been broken and THAT is the bug.
//
// It also holds the exclusion contract's app-side half: a canary run is
// reported, never computed — the app never decides that a run passed, never
// derives a duration, and never names a stage key of its own.
// (The database half of the exclusion — the ledgers refusing a synthetic write
// and pnl_line_v / _c427_bill_units keeping their filter — is the SQL
// behaviour test `heartbeat_synthetic_excluded`, which rg_check runs before
// every command completes.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_heartbeat_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

class _FakeService implements HeartbeatService {
  _FakeService(this._home, {Map<String, dynamic>? detail})
      : _detail = detail ?? const {};

  final Map<String, dynamic> _home;
  final Map<String, dynamic> _detail;

  /// What the screen actually asked the backend to break.
  String? lastBreakStage;
  int runCalls = 0;

  @override
  Future<Map<String, dynamic>> home() async => _home;

  @override
  Future<Map<String, dynamic>> detail(int runId) async => _detail;

  @override
  Future<Map<String, dynamic>> runNow({String? breakStage}) async {
    runCalls++;
    lastBreakStage = breakStage;
    return {'ok': true, 'summary_line': 'BACKEND RAN IT'};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _greenRun() => {
      'id': 21,
      'status': 'passed',
      'status_label': 'PASSED-FROM-BACKEND',
      'status_tone': 'success',
      'when_label': '03 Sep, 01:52 IST',
      'duration_label': '1.1 s',
      'summary_line':
          'Heartbeat OK — 15/15 stages in 1.1s · order CPO030926TSTO1 · artifacts cleaned',
      'stage_label': '15 of 15 stages',
      'clean_label': 'CLEANED-FROM-BACKEND',
      'clean_tone': 'success',
      'order_code': 'CPO030926TSTO1',
    };

Map<String, dynamic> _failedRun() => {
      'id': 23,
      'status': 'failed',
      'status_label': 'FAILED-FROM-BACKEND',
      'status_tone': 'danger',
      'when_label': '03 Sep, 01:58 IST',
      'duration_label': '0.4 s',
      'summary_line': 'Heartbeat FAILED at Counted in warehouse — drill · order X',
      'stage_label': '7 of 15 stages',
      'alert_label': 'ALERT-SENT-FROM-BACKEND',
      'alert_tone': 'warning',
      'clean_label': 'CLEANED-FROM-BACKEND',
      'clean_tone': 'success',
    };

Map<String, dynamic> _home({List<Map<String, dynamic>>? stages}) => {
      'ok': true,
      'allowed': true,
      'title': 'TITLE-FROM-BACKEND',
      'subtitle': 'SUBTITLE-FROM-BACKEND',
      'empty_label': 'EMPTY-FROM-BACKEND',
      'error_title': 'ERROR-TITLE-FROM-BACKEND',
      'retry_label': 'RETRY-FROM-BACKEND',
      'section_runs': 'RUNS-FROM-BACKEND',
      'section_stages': 'STAGES-FROM-BACKEND',
      'enabled': true,
      'schedule_label': '04:47 IST daily',
      'actions': [
        {'key': 'run', 'label': 'RUN-FROM-BACKEND', 'tone': 'brand'},
        {
          'key': 'drill',
          'label': 'DRILL-FROM-BACKEND',
          'tone': 'neutral',
          'hint': 'HINT-FROM-BACKEND'
        },
      ],
      'last': _greenRun(),
      'runs': [_greenRun(), _failedRun()],
      // deliberately NOT in alphabetical order, and the ords are not 1..n
      'stages': stages ??
          [
            {
              'ord': 10,
              'key': 'fixtures',
              'label': 'ZZ-FIRST-STAGE',
              'note': 'NOTE-ONE',
              'timeout_label': '15 s'
            },
            {
              'ord': 105,
              'key': 'bill',
              'label': 'AA-SECOND-STAGE',
              'note': 'NOTE-TWO',
              'timeout_label': '30 s'
            },
            {
              'ord': 150,
              'key': 'exclusions',
              'label': 'MM-LAST-STAGE',
              'note': 'NOTE-THREE',
              'timeout_label': '30 s'
            },
          ],
    };

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  Future<void> pump(WidgetTester t, _FakeService svc) async {
    // A tall viewport so the whole page is built: the sections below the fold
    // are the ones this file is here to check, and a lazy ListView never
    // builds what it cannot show.
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 4000);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(home: AdminHeartbeatScreen(service: svc)));
    await t.pumpAndSettle();
  }

  testWidgets('every visible word is the backend\'s', (t) async {
    final svc = _FakeService(_home());
    await pump(t, svc);

    expect(find.text('TITLE-FROM-BACKEND'), findsOneWidget);
    expect(find.text('SUBTITLE-FROM-BACKEND'), findsOneWidget);
    expect(find.text('RUNS-FROM-BACKEND'), findsOneWidget);
    expect(find.text('STAGES-FROM-BACKEND'), findsOneWidget);
    expect(find.text('RUN-FROM-BACKEND'), findsOneWidget);
    expect(find.text('DRILL-FROM-BACKEND'), findsOneWidget);
    expect(find.text('HINT-FROM-BACKEND'), findsOneWidget);
    expect(find.text('04:47 IST daily'), findsOneWidget);

    // the status word is printed, never derived from status == 'passed'
    expect(find.text('PASSED-FROM-BACKEND'), findsWidgets);
    expect(find.text('FAILED-FROM-BACKEND'), findsOneWidget);
    expect(find.text('Passed'), findsNothing);
    expect(find.text('Failed'), findsNothing);

    // the duration is the backend's string; nothing here divides by 1000
    expect(find.text('1.1 s'), findsOneWidget);
  });

  testWidgets('stages render in payload order, never sorted', (t) async {
    await pump(t, _FakeService(_home()));
    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => s.endsWith('-STAGE'))
        .toList();
    expect(labels, ['ZZ-FIRST-STAGE', 'AA-SECOND-STAGE', 'MM-LAST-STAGE']);
  });

  testWidgets('no alert chip when the payload sent none', (t) async {
    // The green run carries no alert_label at all, so no alert chip is drawn
    // and no Dart fallback wording appears in its place.
    await pump(t, _FakeService(_home()));
    expect(find.text('ALERT-SENT-FROM-BACKEND'), findsNothing);
    expect(find.text('Alert sent'), findsNothing);
    expect(find.text('CLEANED-FROM-BACKEND'), findsOneWidget);
  });

  testWidgets('the alert chip is the run that actually alerted', (t) async {
    final p = _home();
    p['last'] = _failedRun();
    await pump(t, _FakeService(p));
    expect(find.text('ALERT-SENT-FROM-BACKEND'), findsOneWidget);
  });

  testWidgets('the drill breaks the stage the BACKEND named', (t) async {
    final svc = _FakeService(_home());
    await pump(t, svc);

    await t.tap(find.text('RUN-FROM-BACKEND'));
    await t.pumpAndSettle();
    expect(svc.runCalls, 1);
    expect(svc.lastBreakStage, isNull); // a normal run breaks nothing

    await t.tap(find.text('DRILL-FROM-BACKEND'));
    await t.pumpAndSettle();
    expect(svc.runCalls, 2);
    // the payload's own last stage key — no Dart literal chooses it
    expect(svc.lastBreakStage, 'exclusions');
  });

  testWidgets('a stage list the app has never seen still drills correctly',
      (t) async {
    final svc = _FakeService(_home(stages: [
      {
        'ord': 5,
        'key': 'a_brand_new_stage',
        'label': 'NEW-STAGE',
        'note': '',
        'timeout_label': '5 s'
      },
    ]));
    await pump(t, svc);
    await t.tap(find.text('DRILL-FROM-BACKEND'));
    await t.pumpAndSettle();
    expect(svc.lastBreakStage, 'a_brand_new_stage');
  });

  testWidgets('a refusal renders the backend copy instead of throwing',
      (t) async {
    await pump(
        t,
        _FakeService({
          'ok': false,
          'allowed': false,
          'error_title': 'REFUSED-FROM-BACKEND',
          'retry_label': 'RETRY-FROM-BACKEND',
        }));
    expect(find.text('REFUSED-FROM-BACKEND'), findsOneWidget);
    expect(find.text('RETRY-FROM-BACKEND'), findsOneWidget);
  });

  testWidgets('no runs yet renders the backend empty state', (t) async {
    final p = _home();
    p['last'] = null;
    p['runs'] = <Map<String, dynamic>>[];
    await pump(t, _FakeService(p));
    expect(find.text('EMPTY-FROM-BACKEND'), findsOneWidget);
  });
}
