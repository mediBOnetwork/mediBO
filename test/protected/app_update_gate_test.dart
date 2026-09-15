// PROTECTED — CHANGE #1922.
//
// See CLAUDE.md: this runs before EVERY deploy and may only be edited by a
// CHANGE that deliberately changes this behaviour, never to make an unrelated
// change go green.
//
// What it holds down — the panel that says what the in-app update prompt is
// allowed to offer:
//
//   1. THE PANEL COMPUTES NOTHING. Headings, the two version lines, both
//      status labels, the rollout sentence, the "Play read …" line and every
//      log row are printed exactly as app_update_state() sent them. The
//      fixture deliberately uses sentences no Dart file could have coined; if
//      any of them stops appearing, a switch statement has crept back in.
//
//   2. SUBMITTED IS NOT PUBLISHED. The 08-Sep payload — 1.3.24 published,
//      1.3.25 submitted and in review — must render BOTH, each with its own
//      status label, so the state that caused this change is visible on one
//      screen instead of split between a Play Console tab and a log file.
//
//   3. THE PROMPT CHIP IS THE BACKEND'S. is_on/label/tone arrive together; the
//      panel never decides "on" from the presence of a version.
//
//   4. AN EMPTY LOG PRINTS THE BACKEND'S EMPTY SENTENCE, never a Dart one.
//
//   5. A REFUSAL DRAWS NOTHING. ok:false (not an admin, or the RPC is missing
//      on a fresh branch) renders no card at all — never a half-panel with
//      blank strings, and never an exception on a screen that is otherwise
//      working.
//
//   6. THE GATE CHECKLIST IS THE BACKEND'S (CMD #1956). Four builds shipped as
//      1.3.25 and the panel could only say "submitted" — it could not say WHICH
//      clause was holding the prompt shut. The four conditions, their Met /
//      Not yet words and their tones now arrive in payload['gate'], and the
//      panel prints them. A payload with no gate block draws no list, so an
//      older backend degrades to exactly the #1922 panel.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/app_update_gate_panel.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _payload({
  bool promptOn = true,
  bool publishedHas = true,
  bool submittedHas = true,
  bool gate = true,
  List<Map<String, dynamic>> log = const [],
}) => <String, dynamic>{
      'ok': true,
      'title': 'In-app update prompt',
      'subtitle': 'Only a version Google Play has published may be offered.',
      'prompt': {
        'is_on': promptOn,
        'label': promptOn ? 'Prompt is ON' : 'Prompt is OFF',
        'tone': promptOn ? 'success' : 'neutral',
        'detail': promptOn
            ? 'Play has published Version 1.3.24 (38). Anyone older sees the sheet.'
            : 'Nothing is published on Play, so no one is prompted.',
      },
      'published': {
        'has': publishedHas,
        'heading': 'Users are being offered',
        'empty_label': 'No published version yet — the prompt is off.',
        'version_label': 'Version 1.3.24 (38)',
        'status_label': 'Published on Play',
        'status_tone': 'success',
        'meta_label': 'Published 4d ago',
      },
      'submitted': {
        'has': submittedHas,
        'heading': 'Latest submitted build',
        'empty_label': 'No build has been submitted.',
        'version_label': 'Version 1.3.25 (39)',
        'status_label': 'In review on Play',
        'status_tone': 'warning',
        'rollout_label': '',
        'track_label': 'production track',
        'meta_label': 'Submitted 4d ago',
      },
      if (gate) 'gate': const {
        'heading': 'Why the prompt is on or off',
        'rows': [
          {'label': 'Play reports it published', 'met': true,
           'value': 'Met', 'tone': 'success'},
          {'label': 'Rolled out to 100% of users', 'met': false,
           'value': 'Not yet', 'tone': 'warning'},
          {'label': 'On the production track', 'met': true,
           'value': 'Met', 'tone': 'success'},
          {'label': 'Play review completed', 'met': false,
           'value': 'Not yet', 'tone': 'warning'},
        ],
        'note': 'Not now hides the prompt for 24 h for that build code. '
            'A newer code asks again.',
      },
      'checked_label': 'Play read 2m ago',
      'log_heading': 'Play status changes',
      'log_empty': 'No status change recorded yet.',
      'log': log,
    };

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));
  await tester.pump();
}

void main() {
  setUpAll(() {
    // The panel calls RenderLog.write; its 800 ms debounce is a real Timer
    // that would outlive the test and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  testWidgets('1+2: the submitted build and the published build both render, verbatim',
      (tester) async {
    await _pump(tester, AppUpdateGateView(state: _payload()));

    // the header and its one sentence
    expect(find.text('In-app update prompt'), findsOneWidget);
    expect(find.text('Only a version Google Play has published may be offered.'),
        findsOneWidget);

    // published: what users are actually offered
    expect(find.text('Users are being offered'), findsOneWidget);
    expect(find.text('Version 1.3.24 (38)'), findsOneWidget);
    expect(find.text('Published on Play'), findsOneWidget);
    expect(find.text('Published 4d ago'), findsOneWidget);

    // submitted: present, and clearly NOT the one being offered
    expect(find.text('Latest submitted build'), findsOneWidget);
    expect(find.text('Version 1.3.25 (39)'), findsOneWidget);
    expect(find.text('In review on Play'), findsOneWidget);
    expect(find.text('production track'), findsOneWidget);

    // the freshness line is the backend's sentence, not a formatted DateTime
    expect(find.text('Play read 2m ago'), findsOneWidget);
  });

  testWidgets('3: the prompt chip and its sentence come from the payload',
      (tester) async {
    await _pump(tester, AppUpdateGateView(state: _payload()));
    expect(find.text('Prompt is ON'), findsOneWidget);
    expect(
        find.text(
            'Play has published Version 1.3.24 (38). Anyone older sees the sheet.'),
        findsOneWidget);

    // Nothing published: the SAME widget prints the backend's off-state, and a
    // version line is never invented from the submitted build.
    await _pump(
      tester,
      AppUpdateGateView(
          state: _payload(promptOn: false, publishedHas: false)),
    );
    expect(find.text('Prompt is OFF'), findsOneWidget);
    expect(find.text('Nothing is published on Play, so no one is prompted.'),
        findsOneWidget);
    expect(find.text('No published version yet — the prompt is off.'),
        findsOneWidget);
    expect(find.text('Version 1.3.24 (38)'), findsNothing);
  });

  testWidgets('1: a nonsense status label still renders — no Dart vocabulary',
      (tester) async {
    final p = _payload();
    (p['submitted'] as Map)['status_label'] = 'Zzz — waiting on a human';
    (p['published'] as Map)['status_label'] = 'Serving everybody';
    await _pump(tester, AppUpdateGateView(state: p));
    expect(find.text('Zzz — waiting on a human'), findsOneWidget);
    expect(find.text('Serving everybody'), findsOneWidget);
  });

  testWidgets('4: the log renders in payload order, and its empty state is the backend\'s',
      (tester) async {
    await _pump(tester, AppUpdateGateView(state: _payload()));
    expect(find.text('No status change recorded yet.'), findsOneWidget);

    await _pump(
      tester,
      AppUpdateGateView(
        state: _payload(log: const [
          {
            'title': '1.3.25 (39) · In review on Play → Published on Play',
            'detail': '',
            'at_label': '12 Sep 2026, 03:05 PM',
            'tone': 'success',
          },
          {
            'title': '1.3.25 (39) · Submitted — waiting for Play → In review on Play',
            'detail': 'Rolling out to 10% of users',
            'at_label': '09 Sep 2026, 11:20 AM',
            'tone': 'warning',
          },
        ]),
      ),
    );
    expect(find.text('1.3.25 (39) · In review on Play → Published on Play'),
        findsOneWidget);
    expect(find.text('Rolling out to 10% of users'), findsOneWidget);
    expect(find.text('12 Sep 2026, 03:05 PM'), findsOneWidget);
    expect(find.text('No status change recorded yet.'), findsNothing);
  });

  testWidgets('5: a refusal draws nothing at all', (tester) async {
    await _pump(
      tester,
      AppUpdateGatePanel(
          loader: () async => <String, dynamic>{'ok': false, 'error': 'not_authorized'}),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateGateView), findsNothing);
    expect(find.text('In-app update prompt'), findsNothing);

    // and a payload that does arrive is rendered by the same panel (a fresh
    // key, so the element is rebuilt rather than keeping the refused state)
    await _pump(
      tester,
      AppUpdateGatePanel(
          key: const ValueKey('ok'), loader: () async => _payload()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateGateView), findsOneWidget);
    expect(find.text('Users are being offered'), findsOneWidget);
  });

  testWidgets('6: the gate checklist prints the backend\'s four conditions',
      (tester) async {
    await _pump(tester, AppUpdateGateView(state: _payload()));

    expect(find.text('Why the prompt is on or off'), findsOneWidget);
    expect(find.text('Play reports it published'), findsOneWidget);
    expect(find.text('Rolled out to 100% of users'), findsOneWidget);
    expect(find.text('On the production track'), findsOneWidget);
    expect(find.text('Play review completed'), findsOneWidget);

    // The verdict words are the backend's, and both appear twice — the panel
    // never coins "yes"/"no" and never derives one from `met`.
    expect(find.text('Met'), findsNWidgets(2));
    expect(find.text('Not yet'), findsNWidgets(2));

    // The dismissal window is a backend sentence too, hours included.
    expect(
      find.text('Not now hides the prompt for 24 h for that build code. '
          'A newer code asks again.'),
      findsOneWidget,
    );
  });

  testWidgets('6: no gate block in the payload draws no checklist',
      (tester) async {
    await _pump(tester, AppUpdateGateView(state: _payload(gate: false)));
    expect(find.text('Why the prompt is on or off'), findsNothing);
    expect(find.text('Met'), findsNothing);
    // …and the rest of the panel is untouched.
    expect(find.text('Version 1.3.24 (38)'), findsOneWidget);
  });

  testWidgets('6: the panel fits a 360 px phone without overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pump(tester, AppUpdateGateView(state: _payload()));
    expect(tester.takeException(), isNull);
    expect(find.text('Play review completed'), findsOneWidget);
  });
}
