// PROTECTED — CHANGE #474 (failure drills).
//
// What this holds down: the runbook shelf computes NOTHING. The fixture is
// deliberately self-contradictory — a card whose last drill FAILED carries the
// chip label "Passed" with tone 'success', and a card that has never run
// carries a summary sentence — so any Dart that infers a chip from a status,
// a tone from a word, or a hint from emptiness fails here rather than in front
// of an operator at 2 a.m.
//
//   * sections, manual steps and evidence render in PAYLOAD order (all three
//     fixtures are deliberately not alphabetical),
//   * the chip label and its tone are the payload's, never derived,
//   * the button caption is button.label, and button.running_label while that
//     card's drill is in flight — no "Running…" literal in Dart,
//   * running a drill replaces the row with the CARD THE BACKEND RETURNED, so
//     the screen never guesses what the drill did,
//   * ok:false prints the backend's own refusal sentence and draws no cards.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/ops_runbooks_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _card({
  required String key,
  required String title,
  String chipLabel = 'Passed',
  String chipTone = 'success',
  String ranLabel = '03 Sep 2026, 10:14 pm',
  String summary = 'The queue held the message and the fallback fired.',
  String neverHint = '',
  List<Map<String, String>> evidence = const [],
  List<String> steps = const [],
  String buttonLabel = 'Run drill',
  String runningLabel = 'Running…',
}) =>
    {
      'key': key,
      'title': title,
      'owner_label': 'Ops',
      'sections': [
        {'heading': 'Depends on', 'body': 'Meta WhatsApp Business API'},
        {'heading': 'What breaks', 'body': 'Sends fail or the template is rejected'},
        {'heading': 'How we find out', 'body': 'The failed count climbs'},
        {'heading': 'What happens by itself', 'body': 'Push and email fire instead'},
      ],
      'steps_heading': 'What a human does',
      'steps': steps,
      'drill': {
        'heading': 'The drill',
        'note': 'Forces a send failure for a synthetic recipient.',
        'has_run': ranLabel.isNotEmpty,
        'chip_label': chipLabel,
        'chip_tone': chipTone,
        'never_hint': neverHint,
        'ran_label': ranLabel,
        'summary': summary,
        'evidence_heading': 'Evidence',
        'evidence': evidence,
      },
      'button': {
        'key': key,
        'label': buttonLabel,
        'running_label': runningLabel,
      },
    };

final Map<String, dynamic> _home = {
  'ok': true,
  'title': 'Failure drills',
  'subtitle': 'What we do not own, and the last time we proved the fallback.',
  'summary': {'label': '4 passed · 1 failed · 1 never run', 'tone': 'danger'},
  'empty': 'No runbooks yet.',
  'error': 'Could not read the runbooks.',
  'retry': 'Try again',
  'cards': [
    // Deliberately contradictory: this drill FAILED, and the backend still
    // sent 'Passed'/'success'. The screen must print what it was handed.
    _card(
      key: 'whatsapp_down',
      title: 'WhatsApp down or template rejected',
      chipLabel: 'Passed',
      chipTone: 'success',
      summary: 'FAILED: the fallback never fired.',
      steps: const [
        'Open Notifications and read the failed count',
        'Confirm the template status in Meta Business Manager',
      ],
      evidence: const [
        {'label': 'queued', 'value': '1'},
        {'label': 'channel', 'value': 'push'},
        {'label': 'alert', 'value': 'notify_send_failing'},
      ],
    ),
    _card(
      key: 'ocr_failure',
      title: 'OCR failure on a bill or prescription',
      chipLabel: 'Never run',
      chipTone: 'info',
      ranLabel: '',
      summary: '',
      neverHint: 'This drill has never been run.',
    ),
  ],
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  // A bare card is taller than the 600 px test viewport; in the app it always
  // lives inside the shelf's ListView, so the harness gives it the same scroll.
  Future<void> pump(WidgetTester t, Widget child) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child))));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
  }

  /// The whole screen brings its own Scaffold and its own ListView — wrapping
  /// it in a second scroll view would hand it an unbounded height.
  Future<void> pumpScreen(WidgetTester t, Widget child) async {
    await t.pumpWidget(MaterialApp(home: child));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
  }

  group('RunbookCard — every word is the payload', () {
    testWidgets('sections, steps and evidence render in payload order',
        (t) async {
      await pump(
          t, RunbookCard(card: _home['cards'][0], onRun: (_) {}));

      // Section headings, in the order the backend listed them.
      final headings = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .toList();
      final iDepends = headings.indexOf('Depends on');
      final iBreaks = headings.indexOf('What breaks');
      final iFind = headings.indexOf('How we find out');
      final iSelf = headings.indexOf('What happens by itself');
      expect(iDepends, isNonNegative);
      expect(iDepends < iBreaks && iBreaks < iFind && iFind < iSelf, isTrue,
          reason: 'sections must render in payload order');

      // The steps heading is the payload's, not a Dart literal.
      expect(find.text('What a human does'), findsOneWidget);
      expect(
          headings.indexOf('Open Notifications and read the failed count') <
              headings.indexOf(
                  'Confirm the template status in Meta Business Manager'),
          isTrue);

      // Evidence keeps payload order too.
      expect(headings.indexOf('queued') < headings.indexOf('channel'), isTrue);
      expect(headings.indexOf('channel') < headings.indexOf('alert'), isTrue);
    });

    testWidgets('the chip is the payload word and tone, never inferred',
        (t) async {
      await pump(t, RunbookCard(card: _home['cards'][0], onRun: (_) {}));

      // The summary says FAILED; the backend's chip says Passed. The screen
      // prints the chip it was given.
      expect(find.text('Passed'), findsOneWidget);
      expect(find.text('FAILED: the fallback never fired.'), findsOneWidget);

      final pill = t.widget<RunbookPill>(find.byType(RunbookPill));
      expect(pill.label, 'Passed');
      expect(pill.tone, 'success');
    });

    testWidgets('a never-run drill shows the backend hint and no timestamp',
        (t) async {
      await pump(t, RunbookCard(card: _home['cards'][1], onRun: (_) {}));

      expect(find.text('This drill has never been run.'), findsOneWidget);
      expect(find.text('Never run'), findsOneWidget);
      // No ran_label, so no timestamp line at all — not a dash, not an empty
      // row.
      expect(find.text('03 Sep 2026, 10:14 pm'), findsNothing);
    });

    testWidgets('the button caption is the payload, busy caption included',
        (t) async {
      var tapped = '';
      await pump(
          t,
          RunbookCard(
              card: _home['cards'][0], onRun: (k) => tapped = k));
      expect(find.text('Run drill'), findsOneWidget);
      await t.ensureVisible(find.text('Run drill'));
      await t.pump();
      await t.tap(find.text('Run drill'));
      expect(tapped, 'whatsapp_down',
          reason: 'the tap carries the backend button key');

      await pump(
          t,
          RunbookCard(
              card: _home['cards'][0], busy: true, onRun: (_) {}));
      expect(find.text('Running…'), findsOneWidget);
      expect(find.text('Run drill'), findsNothing);
      expect(
          t.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull,
          reason: 'a running drill cannot be started again');
    });
  });

  group('OpsRunbooksScreen — the shelf', () {
    testWidgets('renders the payload title, subtitle, summary and every card',
        (t) async {
      await pumpScreen(
          t, OpsRunbooksScreen(service: _FakeService(homePayload: _home)));
      await t.pumpAndSettle();

      expect(find.text('Failure drills'), findsOneWidget);
      expect(
          find.text(
              'What we do not own, and the last time we proved the fallback.'),
          findsOneWidget);
      expect(find.text('4 passed · 1 failed · 1 never run'), findsOneWidget);

      // The shelf is a lazy list: the first card is drawn, and the second
      // arrives on scroll — in the backend's order, not sorted here.
      expect(find.text('WhatsApp down or template rejected'), findsOneWidget);
      await t.scrollUntilVisible(
          find.text('OCR failure on a bill or prescription'), 300);
      expect(find.text('OCR failure on a bill or prescription'), findsOneWidget);
    });

    testWidgets('a drill replaces the row with the card the BACKEND returned',
        (t) async {
      final after = _card(
        key: 'whatsapp_down',
        title: 'WhatsApp down or template rejected',
        chipLabel: 'Failed',
        chipTone: 'danger',
        summary: 'The queue dropped the message.',
      );
      final svc = _FakeService(
          homePayload: _home, drillReply: {'ok': true, 'card': after});

      await pumpScreen(t, OpsRunbooksScreen(service: svc));
      await t.pumpAndSettle();
      expect(find.text('Passed'), findsOneWidget);

      await t.ensureVisible(find.text('Run drill').first);
      await t.pump();
      await t.tap(find.text('Run drill').first);
      await t.pumpAndSettle();

      expect(svc.drilled, 'whatsapp_down');
      expect(find.text('Failed'), findsOneWidget,
          reason: 'the row shows the backend recomputed card');
      expect(find.text('The queue dropped the message.'), findsWidgets);
    });

    testWidgets('ok:false prints the backend refusal and draws no cards',
        (t) async {
      await pumpScreen(
          t,
          OpsRunbooksScreen(
              service: _FakeService(homePayload: const {
            'ok': false,
            'message': 'Failure drills are an admin surface.',
          })));
      await t.pumpAndSettle();

      expect(find.text('Failure drills are an admin surface.'), findsOneWidget);
      expect(find.byType(RunbookCard), findsNothing);
    });
  });
}

/// A RunbooksService that never touches Supabase.
class _FakeService implements RunbooksService {
  _FakeService({required this.homePayload, this.drillReply});

  final Map<String, dynamic> homePayload;
  final Map<String, dynamic>? drillReply;
  String drilled = '';

  @override
  Future<Map<String, dynamic>> home() async => homePayload;

  @override
  Future<Map<String, dynamic>> drill(String key) async {
    drilled = key;
    return drillReply ?? const {};
  }
}
