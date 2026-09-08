// CHANGE #327 — the Build lane section.
//
// The third contention lane: builds fighting for one FILE. #325 claimed, loaded
// its context, planned its files and only then found #326 holding
// home_shell.dart — then polled that lease 97 times in six minutes while
// holding everything it had loaded. The fix decides the collision in SQL before
// a worker boots, and this card is the proof surface.
//
// So it must not become another place where a number is computed. What this
// holds down:
//   1. Sections render in PAYLOAD ORDER — the fixture is deliberately not
//      alphabetical — and every heading, label, detail and chip is printed
//      verbatim.
//   2. An empty section prints the backend's own empty_hint and no rows; a
//      populated one prints its rows and drops the hint.
//   3. A section the widget has never heard of still renders (forward compat:
//      a new section is an INSERT, never a deploy).
//   4. ok:false renders the backend's refusal sentence and nothing else — it
//      does not throw and does not invent a message.
//   5. The mode chip and the window label come from the payload, never from a
//      count done in Dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/build_lane_section.dart';

Widget _host(Map<String, dynamic> data) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(child: BuildLaneSection(data: data)),
  ),
);

Map<String, dynamic> _payload({List? sections}) => {
  'ok': true,
  'title': 'Build lane',
  'subtitle': 'Collisions are decided in SQL before a worker boots.',
  'mode_label': 'COLLISIONS: 2',
  'mode_tone': 'warning',
  'window_label': 'Last 7 days',
  'headline': {
    'label': '2 lease refusals in the last 7 days.',
    'detail': '31 files leased · 1 deferred and picked up later',
    'tone': 'warning',
  },
  'sections':
      sections ??
      [
        // Deliberately NOT alphabetical — payload order is the contract.
        {
          'heading': 'Zulu section — first on purpose',
          'empty_hint': 'nothing here',
          'rows': [
            {
              'label': '#328 · partner routing',
              'detail': 'Queued after #326 — same files',
              'value_label': 'waiting, not building',
              'tone': 'info',
            },
          ],
        },
        {
          'heading': 'Alpha section — second on purpose',
          'empty_hint': 'No worker is holding a file.',
          'rows': const [],
        },
      ],
};

void main() {
  testWidgets('sections render in payload order, verbatim', (t) async {
    await t.pumpWidget(_host(_payload()));

    expect(find.text('Build lane'), findsOneWidget);
    expect(find.text('COLLISIONS: 2'), findsOneWidget);
    expect(find.text('Last 7 days'), findsOneWidget);
    expect(find.text('2 lease refusals in the last 7 days.'), findsOneWidget);

    final zulu = t.getTopLeft(find.text('Zulu section — first on purpose')).dy;
    final alpha = t.getTopLeft(find.text('Alpha section — second on purpose')).dy;
    expect(
      zulu,
      lessThan(alpha),
      reason: 'payload order, not a client-side sort',
    );
  });

  testWidgets('a populated section prints rows and drops its hint', (t) async {
    await t.pumpWidget(_host(_payload()));

    expect(find.text('#328 · partner routing'), findsOneWidget);
    // The chain sentence is the BACKEND's — pluralisation, ids and all.
    expect(find.text('Queued after #326 — same files'), findsOneWidget);
    expect(find.text('waiting, not building'), findsOneWidget);
    expect(find.text('nothing here'), findsNothing);
  });

  testWidgets('an empty section prints the backend empty hint', (t) async {
    await t.pumpWidget(_host(_payload()));
    expect(find.text('No worker is holding a file.'), findsOneWidget);
  });

  testWidgets('an unknown section still renders — a new one needs no deploy', (
    t,
  ) async {
    await t.pumpWidget(
      _host(
        _payload(
          sections: [
            {
              'heading': 'Something invented next month',
              'empty_hint': 'nothing yet',
              'rows': [
                {
                  'label': 'lib/screens/home_shell.dart',
                  'detail': 'held by #326 · runner-2',
                  'value_label': '38m ago',
                  'tone': 'neutral',
                },
              ],
            },
          ],
        ),
      ),
    );
    expect(find.text('Something invented next month'), findsOneWidget);
    expect(find.text('lib/screens/home_shell.dart'), findsOneWidget);
    expect(find.text('held by #326 · runner-2'), findsOneWidget);
  });

  testWidgets('ok:false prints the backend refusal and nothing else', (t) async {
    await t.pumpWidget(
      _host({'ok': false, 'error': 'Super-admin only.', 'title': 'Build lane'}),
    );
    expect(find.text('Super-admin only.'), findsOneWidget);
    expect(find.text('Build lane'), findsNothing);
  });

  testWidgets('ok:false with no message renders nothing at all', (t) async {
    await t.pumpWidget(_host(const {'ok': false}));
    expect(find.byType(Text), findsNothing);
  });
}
