// PROTECTED — CHANGE #1366.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change go
// green.
//
// What this holds down — the two surfaces that were SILENT on 4-5 Sep while the
// EC2 root disk sat at 99% and every runner refused to claim for 21 hours:
//
//   1. The blocked banner is a PRINTER. "Runners blocked: <reason>", the
//      detail sentence and the age line are runner_blocked_badge() strings.
//      The fixture's label deliberately names a DIFFERENT reason from the one
//      in its own `reason` field, so a banner that rebuilt the sentence in Dart
//      out of `reason` fails here.
//
//   2. Absence is a flag, never an empty banner. `has:false` draws NOTHING —
//      no zero-height container, no placeholder. That is what makes it safe to
//      keep the banner above the collapsed header, where it is always visible.
//
//   3. The disk line never computes. Its label, its "47% used · 30.1 GB free"
//      sentence and its sub-line all arrive whole; the fixture's value string
//      deliberately disagrees with its own pct/free_gb numbers, so a card that
//      formatted the sentence from the numbers fails.
//
//   4. "Not measured" is not "0%". `has:false` on the disk block draws nothing
//      rather than a dash or a zero — a disk nobody has read must never render
//      as a reassuring number.
//
//   5. Tone is carried, not inferred, through ONE lookup, and an unknown tone
//      stays neutral. A 99%-full disk is coloured because the BACKEND said
//      danger, never because Dart compared 99 to a threshold it keeps itself.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_control.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_workers.dart';

Map<String, dynamic> _blocked({bool has = true, String tone = 'danger'}) => {
      'has': has,
      'tone': tone,
      // Deliberately NOT 'Runners blocked: ' + reason — the whole sentence is
      // the backend's, and a card that rebuilds it from `reason` gets this
      // wrong on purpose.
      'label': 'Runners blocked: Disk headroom — 0.7 GB free (99% used)',
      'detail':
          'runner-2 refused to claim at 05 Sep 09:12 IST. Nothing in the queue '
          'moves until the boot doctor is green again.',
      'since_label': 'Blocked for 21.3h',
      'agent': 'runner-2',
      'reason': 'disk_space',
    };

Map<String, dynamic> _disk({bool has = true, String tone = 'success'}) => {
      'has': has,
      'tone': tone,
      'label': 'Disk',
      // The numbers below say 47 / 30.1; this sentence deliberately does not.
      'value': '91% used · 5.2 GB free',
      'sub_line': 'Floor is 2 GB — headroom is fine',
      'pct': 47,
      'free_gb': 30.1,
    };

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('Runners-blocked banner', () {
    testWidgets('prints the backend sentence verbatim, never rebuilt in Dart',
        (t) async {
      await t.pumpWidget(_wrap(RunnersBlockedBanner(blocked: _blocked())));

      // The whole label, exactly as sent — including the check name and the
      // free-GB figure the doctor measured.
      expect(
          find.text('Runners blocked: Disk headroom — 0.7 GB free (99% used)'),
          findsOneWidget);
      // A banner that composed 'Runners blocked: ' + reason would print this.
      expect(find.text('Runners blocked: disk_space'), findsNothing);
      // Detail and age are their own strings, not derived from a timestamp.
      expect(
          find.textContaining('runner-2 refused to claim at 05 Sep 09:12 IST'),
          findsOneWidget);
      expect(find.text('Blocked for 21.3h'), findsOneWidget);
    });

    testWidgets('has:false draws nothing at all', (t) async {
      await t.pumpWidget(_wrap(RunnersBlockedBanner(blocked: _blocked(has: false))));
      expect(find.byType(Container), findsNothing);
      expect(find.byType(Text), findsNothing);
      expect(find.byIcon(Icons.report_gmailerrorred), findsNothing);
    });

    testWidgets('an empty payload is absence, not a blank banner', (t) async {
      await t.pumpWidget(_wrap(const RunnersBlockedBanner(blocked: {})));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('an absent detail or age line is omitted, never dashed',
        (t) async {
      final b = _blocked()
        ..['detail'] = ''
        ..['since_label'] = '';
      await t.pumpWidget(_wrap(RunnersBlockedBanner(blocked: b)));
      expect(find.byType(Text), findsOneWidget); // the label alone
      expect(find.text('—'), findsNothing);
    });

    testWidgets('tone is one lookup — an unknown tone stays neutral', (t) async {
      await t.pumpWidget(
          _wrap(RunnersBlockedBanner(blocked: _blocked(tone: 'danger'))));
      final danger = t
          .widget<Container>(find.byType(Container).first)
          .decoration as BoxDecoration;

      await t.pumpWidget(_wrap(
          RunnersBlockedBanner(blocked: _blocked(tone: 'tone-from-the-future'))));
      final unknown = t
          .widget<Container>(find.byType(Container).first)
          .decoration as BoxDecoration;

      expect(unknown.color, isNot(danger.color));
      // It still renders — a tone name Dart has never heard of must not blank
      // the one banner that says the fleet has stopped.
      expect(
          find.text('Runners blocked: Disk headroom — 0.7 GB free (99% used)'),
          findsOneWidget);
    });
  });

  group('Runner health disk line', () {
    testWidgets('prints the backend sentence, never one built from the numbers',
        (t) async {
      await t.pumpWidget(_wrap(RunnerDiskLine(disk: _disk())));
      expect(find.text('Disk'), findsOneWidget);
      expect(find.text('91% used · 5.2 GB free'), findsOneWidget);
      // The raw numbers are in the payload and must NOT be formatted locally.
      expect(find.text('47% used · 30.1 GB free'), findsNothing);
      expect(find.text('47%'), findsNothing);
      expect(find.text('Floor is 2 GB — headroom is fine'), findsOneWidget);
    });

    testWidgets('not measured is nothing, not 0% and not a dash', (t) async {
      await t.pumpWidget(_wrap(RunnerDiskLine(disk: _disk(has: false))));
      expect(find.byType(Text), findsNothing);
      expect(find.text('0%'), findsNothing);
      expect(find.text('—'), findsNothing);
      expect(find.byIcon(Icons.storage_outlined), findsNothing);
    });

    testWidgets('an absent sub-line is omitted rather than dashed', (t) async {
      final d = _disk()..['sub_line'] = '';
      await t.pumpWidget(_wrap(RunnerDiskLine(disk: d)));
      expect(find.text('Disk'), findsOneWidget);
      expect(find.text('91% used · 5.2 GB free'), findsOneWidget);
      expect(find.byType(Text), findsNWidgets(2));
    });

    testWidgets('the value wears the payload tone, and an unknown one is neutral',
        (t) async {
      Color colourOf(String tone) {
        return RunnerDiskLine.debugValueColour(tone);
      }

      expect(colourOf('danger'), isNot(colourOf('success')));
      expect(colourOf('warning'), isNot(colourOf('success')));
      expect(colourOf('error'), colourOf('danger'));
      expect(colourOf('a-tone-from-the-future'), colourOf(''));
    });

    testWidgets('a danger disk still renders every string', (t) async {
      await t.pumpWidget(_wrap(RunnerDiskLine(disk: _disk(tone: 'danger'))));
      expect(find.text('91% used · 5.2 GB free'), findsOneWidget);
      expect(find.text('Floor is 2 GB — headroom is fine'), findsOneWidget);
    });
  });
}
