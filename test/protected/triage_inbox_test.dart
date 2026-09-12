// PROTECTED — CHANGE #639.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes triage behaviour, never to make an unrelated change go
// green.
//
// What this holds down — the Triage inbox is a PRINTER, and the two buttons on
// it are the ONLY decision the app is allowed to carry:
//
//   1. Nothing on the card is derived. The severity word, the status word,
//      both tones, the source and age captions, the button captions and the
//      repro toggle's two labels all arrive in the payload. The fixture
//      deliberately pairs severity 'critical' with the label "Low" and the tone
//      'success', so a card that re-derived either from the severity string
//      fails here.
//
//   2. `can_decide` is the backend's, not a status check in Dart. A row whose
//      status is 'new' but whose can_decide is false shows NEITHER button — that
//      is what stops a queued, verifying or escalated row being re-approved from
//      a stale screen.
//
//   3. Absence is a flag. An absent screenshot, escalate note, verify detail,
//      reject reason, fix label or reopen label is OMITTED — never dashed,
//      never zeroed, never a blank box.
//
//   4. Repro steps render in payload order and only when opened. The fixture's
//      steps are deliberately not alphabetical.
//
//   5. The trend block prints its own numbers. The fixture's weekly rows
//      deliberately disagree with its "Reopen rate" stat, because the backend
//      computed the stat and the card must not recompute it from the weeks.
//
//   6. An unknown tone name stays neutral rather than being guessed at.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/triage_inbox_screen.dart';

Map<String, dynamic> _row({
  bool canDecide = true,
  bool hasShot = false,
  String? escalate,
  String? verifyDetail,
  String? rejectReason,
  String? fixLabel,
  String? reopenLabel,
  List<String>? repro,
}) =>
    {
      'id': 42,
      // Deliberately mismatched: severity says critical, the LABEL says Low and
      // the TONE says success. The card must print what it was handed.
      'severity': 'critical',
      'severity_label': 'Low',
      'severity_tone': 'success',
      'status': 'new',
      'status_label': 'Waiting for you',
      'status_tone': 'warning',
      'source': 'visual',
      'source_label': 'Visual bot',
      'found_label': '3d ago',
      'seen_label': 'seen 4 times',
      'plain_line': 'A screen came up blank on a phone-width window.',
      'surface_label': 'cust.orders',
      'repro': repro ??
          const [
            'Sign in as customer',
            'Open the cust.orders screen',
            'Use a phone-width window',
          ],
      'repro_label': 'Repro steps',
      'repro_hide_label': 'Hide steps',
      'has_shot': hasShot,
      'shot_bucket': hasShot ? 'test-artifacts' : null,
      'shot_path': hasShot ? 'run-9/a/phone.png' : null,
      'can_decide': canDecide,
      'approve_label': 'Approve',
      'reject_label': 'Reject',
      'reject_hint': 'Why is this not a real problem?',
      'escalate_note': escalate,
      'verify_detail': verifyDetail,
      'reject_reason': rejectReason,
      'fix_label': fixLabel,
      'reopen_label': reopenLabel,
    };

Future<void> _pump(WidgetTester t, Widget child) async {
  await t.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child))));
  await t.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the finding card is a printer', () {
    testWidgets('severity, status and tone are the payload\'s, not derived',
        (t) async {
      await _pump(t, TriageFindingCard(row: _row()));

      // The LABEL is printed, not the enum, and not a title-cased severity.
      expect(find.text('Low'), findsOneWidget);
      expect(find.text('Critical'), findsNothing);
      expect(find.text('Waiting for you'), findsOneWidget);

      // The tone came from severity_tone ('success'), NOT from severity
      // ('critical'). A card that mapped critical→danger paints the wrong one.
      final chip = t.widget<Container>(find.ancestor(
        of: find.text('Low'),
        matching: find.byType(Container),
      ).first);
      final deco = chip.decoration as BoxDecoration;
      expect(deco.color, toneByName('success').bg);
      expect(deco.color, isNot(toneByName('danger').bg));
    });

    testWidgets('an unknown tone name stays neutral', (t) async {
      final r = _row()..['severity_tone'] = 'chartreuse';
      await _pump(t, TriageFindingCard(row: r));
      final chip = t.widget<Container>(find.ancestor(
        of: find.text('Low'),
        matching: find.byType(Container),
      ).first);
      expect((chip.decoration as BoxDecoration).color, toneByName('neutral').bg);
    });

    testWidgets('the plain line and the surface print verbatim', (t) async {
      await _pump(t, TriageFindingCard(row: _row()));
      expect(find.text('A screen came up blank on a phone-width window.'),
          findsOneWidget);
      expect(find.text('cust.orders'), findsOneWidget);
      expect(find.text('Visual bot'), findsOneWidget);
      expect(find.text('3d ago'), findsOneWidget);
      expect(find.text('seen 4 times'), findsOneWidget);
    });

    testWidgets('can_decide false hides BOTH buttons even at status new',
        (t) async {
      await _pump(t, TriageFindingCard(row: _row(canDecide: false)));
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Reject'), findsNothing);
      // The row itself is still shown — it is history, not a hidden problem.
      expect(find.text('A screen came up blank on a phone-width window.'),
          findsOneWidget);
    });

    testWidgets('can_decide true shows both, and each fires exactly once',
        (t) async {
      var approvals = 0, rejections = 0;
      await _pump(
        t,
        TriageFindingCard(
          row: _row(),
          onApprove: () => approvals++,
          onReject: () => rejections++,
        ),
      );
      await t.tap(find.text('Approve'));
      await t.tap(find.text('Reject'));
      await t.pump();
      expect(approvals, 1);
      expect(rejections, 1);
    });

    testWidgets('busy disables both buttons — no double approval', (t) async {
      var approvals = 0;
      await _pump(
        t,
        TriageFindingCard(
            row: _row(), busy: true, onApprove: () => approvals++),
      );
      await t.tap(find.text('Approve'));
      await t.pump();
      expect(approvals, 0);
    });

    testWidgets('repro steps are hidden until opened, then render in order',
        (t) async {
      await _pump(t, TriageFindingCard(row: _row()));
      expect(find.text('Repro steps'), findsOneWidget);
      expect(find.text('· Sign in as customer'), findsNothing);

      await _pump(t, TriageFindingCard(row: _row(), expanded: true));
      expect(find.text('Hide steps'), findsOneWidget);

      final texts = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((s) => s.startsWith('· '))
          .toList();
      expect(texts, [
        '· Sign in as customer',
        '· Open the cust.orders screen',
        '· Use a phone-width window',
      ]);
    });

    testWidgets('absence is omitted, never dashed or zeroed', (t) async {
      await _pump(t, TriageFindingCard(row: _row()));
      // No screenshot, no escalate note, no verify detail, no reject reason,
      // no fix label, no reopen label were sent — so none of them are drawn.
      expect(find.byType(Image), findsNothing);
      for (final s in const ['-', '—', '0', 'null']) {
        expect(find.text(s), findsNothing);
      }
    });

    testWidgets('every optional line prints when the payload carries it',
        (t) async {
      await _pump(
        t,
        TriageFindingCard(
          row: _row(
            escalate: 'This finding has survived two fixes.',
            verifyDetail: 'the newest screenshot still trips the same rule',
            rejectReason: 'false positive: that screen is meant to be empty',
            fixLabel: 'Fix #755',
            reopenLabel: 'reopened 2×',
          ),
        ),
      );
      expect(find.text('This finding has survived two fixes.'), findsOneWidget);
      expect(find.text('the newest screenshot still trips the same rule'),
          findsOneWidget);
      expect(find.text('false positive: that screen is meant to be empty'),
          findsOneWidget);
      expect(find.text('Fix #755'), findsOneWidget);
      expect(find.text('reopened 2×'), findsOneWidget);
    });
  });

  group('the trend block prints, it does not compute', () {
    final trends = {
      'has': true,
      'title': 'Trend',
      'weeks_label': 'Found vs fixed',
      'worst_label': 'Worst surfaces',
      'weeks': const [
        // 12 found, 12 fixed across these weeks — a card that derived the
        // reopen rate from them could never print 40%.
        {'label': '24 Aug · 6 found / 6 fixed'},
        {'label': '31 Aug · 6 found / 6 fixed'},
      ],
      'stats': const [
        {
          'label': 'Reopen rate',
          'value': '40%',
          'sub': '4 of 10 came back',
          'tone': 'danger'
        },
        {
          'label': 'Find to fixed',
          'value': '2.4 h',
          'sub': 'average across 5 fixed',
          'tone': 'neutral'
        },
        {'label': 'Coverage', 'value': '1%', 'sub': null, 'tone': 'danger'},
      ],
      'worst': const [
        {
          'label': 'cust.orders',
          'value': '3 open of 9',
          'sub': '2 came back after a fix',
          'tone': 'danger'
        },
      ],
    };

    testWidgets('stats, weeks and worst print verbatim, in payload order',
        (t) async {
      await _pump(t, TriageTrendBlock(trends: trends));
      expect(find.text('40%'), findsOneWidget);
      expect(find.text('4 of 10 came back'), findsOneWidget);
      expect(find.text('2.4 h'), findsOneWidget);
      expect(find.text('1%'), findsOneWidget);
      expect(find.text('24 Aug · 6 found / 6 fixed'), findsOneWidget);
      expect(find.text('3 open of 9'), findsOneWidget);

      final labels = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((s) =>
              s == 'Reopen rate' || s == 'Find to fixed' || s == 'Coverage')
          .toList();
      expect(labels, ['Reopen rate', 'Find to fixed', 'Coverage']);
    });

    testWidgets('a stat with no sub-line omits it rather than dashing it',
        (t) async {
      await _pump(t, TriageTrendBlock(trends: trends));
      expect(find.text('-'), findsNothing);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('has:false draws nothing at all', (t) async {
      await _pump(t, const TriageTrendBlock(trends: {'has': false}));
      expect(find.byType(Text), findsNothing);
    });
  });
}
