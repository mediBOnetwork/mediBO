// CMD #368 — the Database lane card renders admission control from the payload
// and computes nothing.
//
// The point of these tests is that the ONE number Om is tuning (how many heavy
// runners this 1 GB instance may carry at once) is a backend value shown
// verbatim, and that saving it sends the backend's own key with the typed
// number — never a locally derived label, never an optimistic local update.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/db_lane_section.dart';

Map<String, dynamic> _payload({
  bool enabled = true,
  int maxBuilds = 3,
  List<Map<String, dynamic>> recent = const [],
  List<Map<String, dynamic>> violations = const [],
}) => {
  'ok': true,
  'title': 'Database lane',
  'tone': 'success',
  'headline': '40 of 60 connections · peak 44 in 24 h · 0 statement timeouts',
  'sampled_label': 'Sampled 31 Aug 22:11:00 IST',
  'stats': const [],
  'lanes': const [],
  'held': const [],
  'held_empty': 'No agent is holding a database lane.',
  'guard': {
    'label': 'Session guardrails',
    'value_label':
        'statement 55 s · lock 5 s · idle-in-transaction 30 s — applied to '
        'every runner session as a role setting, not by the agent',
  },
  'violations': {
    'label': 'Heavy work outside the lane',
    'value_label': violations.isEmpty
        ? 'None in 7 days — every heavy statement took the lane first.'
        : '${violations.length} heavy statement(s) ran outside the lane',
    'tone': violations.isEmpty ? 'success' : 'warning',
    'recent': violations,
  },
  'window': {'label': 'Heavy scheduled audits', 'value_label': '4 jobs'},
  'alerts': {
    'label': 'Watchdog',
    'value_label': '0 database alerts in 7 days',
    'quiet': 'Quiet — no alert in the last 7 days.',
    'recent': const [],
  },
  'admission': {
    'label': 'Runner admission control',
    'value_label': enabled
        ? '4 of $maxBuilds builds in flight · 0 timeouts in 5 min'
        : 'Off — every claim is admitted regardless of database pressure.',
    'tone': enabled ? 'warning' : 'neutral',
    'source_label': 'Pressure read from the watchdog sample',
    'updated_label': 'Thresholds updated 31 Aug 22:10 IST by setup',
    'toggle': {
      'key': 'enabled',
      'label': 'Admission control',
      'value': enabled,
      'hint': 'Off lets every runner claim no matter how loaded the database is.',
    },
    'thresholds': [
      {
        'key': 'max_concurrent_builds',
        'label': 'Concurrent builds',
        'value': maxBuilds,
        'min': 1,
        'max': 8,
        'unit': 'builds',
        'hint': 'Five runners choked the 1 GB instance; two to three fly.',
      },
      {
        'key': 'conn_pct_max',
        'label': 'Connections in use',
        'value': 75,
        'min': 20,
        'max': 100,
        'unit': '%',
        'hint': 'Percent of max_connections.',
      },
    ],
    'recent_heading': 'Claims held back',
    'recent_empty': 'No runner has been held back in the last 24 hours.',
    'recent': recent,
  },
};

Future<void> _pump(
  WidgetTester t,
  Map<String, dynamic> data, {
  Future<void> Function(Map<String, dynamic>)? onPatch,
}) => t.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: DbLaneSection(data: data, onAdmissionPatch: onPatch),
      ),
    ),
  ),
);

void main() {
  testWidgets('every admission string is the payload, printed verbatim', (
    t,
  ) async {
    await _pump(t, _payload());

    expect(find.text('Runner admission control'), findsOneWidget);
    expect(
      find.text('4 of 3 builds in flight · 0 timeouts in 5 min'),
      findsOneWidget,
    );
    expect(find.text('Concurrent builds'), findsOneWidget);
    // The unit comes from the payload too — '%' hugs its number, everything
    // else gets a space. Nothing here is a Dart-side label.
    expect(find.text('3 builds'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    expect(
      find.text('No runner has been held back in the last 24 hours.'),
      findsOneWidget,
    );
  });

  testWidgets('a held-back claim renders the backend sentence, not a count', (
    t,
  ) async {
    await _pump(
      t,
      _payload(
        recent: [
          {
            'at_label': '31 Aug 21:46:12',
            'label': 'runner-5',
            'detail':
                '4 builds already in flight — this instance sustains 3 at a time.',
            'tone': 'warning',
          },
        ],
      ),
    );

    expect(
      find.text(
        'runner-5 — 4 builds already in flight — this instance sustains 3 at a time.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('No runner has been held back in the last 24 hours.'),
      findsNothing,
    );
  });

  testWidgets('saving a threshold sends the backend key and the typed number', (
    t,
  ) async {
    final sent = <Map<String, dynamic>>[];
    await _pump(
      t,
      _payload(),
      onPatch: (p) async => sent.add(p),
    );

    await t.tap(find.text('Concurrent builds'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '2');
    await t.tap(find.byType(FilledButton));
    await t.pumpAndSettle();

    expect(sent, [
      {'max_concurrent_builds': 2},
    ]);
  });

  testWidgets('the switch sends enabled, and read-only mode offers no editor', (
    t,
  ) async {
    final sent = <Map<String, dynamic>>[];
    await _pump(t, _payload(), onPatch: (p) async => sent.add(p));
    await t.tap(find.byType(Switch));
    await t.pumpAndSettle();
    expect(sent, [
      {'enabled': false},
    ]);

    // No callback => no switch, no edit affordance: a viewer who cannot save
    // must not be shown a control that silently does nothing.
    await _pump(t, _payload());
    expect(find.byType(Switch), findsNothing);
    await t.tap(find.text('Concurrent builds'));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('lane violations print the backend rows; empty says so', (
    t,
  ) async {
    await _pump(t, _payload());
    expect(
      find.text('None in 7 days — every heavy statement took the lane first.'),
      findsOneWidget,
    );

    await _pump(
      t,
      _payload(
        violations: [
          {
            'at_label': '31 Aug 21:50',
            'label': 'postgres · 31 s',
            'detail': 'create index concurrently on "MEDICINE" ...',
          },
        ],
      ),
    );
    expect(find.text('31 Aug 21:50 · postgres · 31 s'), findsOneWidget);
    expect(
      find.text('create index concurrently on "MEDICINE" ...'),
      findsOneWidget,
    );
  });

  testWidgets('ok:false renders the backend refusal and nothing else', (
    t,
  ) async {
    await _pump(t, {
      'ok': false,
      'error': 'The database lane is visible to super-admins only.',
    });
    expect(
      find.text('The database lane is visible to super-admins only.'),
      findsOneWidget,
    );
    expect(find.text('Runner admission control'), findsNothing);
  });
}
