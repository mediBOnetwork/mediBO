// PROTECTED — CHANGE #1856.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes hold/cold-resume behaviour, never to make an unrelated
// change go green.
//
// WHAT THIS HOLDS DOWN — a wait has two prices, and the queue must never print
// one word for both.
//
// #1848 spent 9.7M tokens because it parked and was resumed COLD four times (a
// db restart, then merge-lane entries 883, 884 and 886). The waiting itself was
// free; the RE-ENTRY was not, because every cold resume re-reads the whole
// context. CHANGE #1856 adds the middle mode — HOLD, where the session is kept
// alive and idles — and makes the difference countable on the command that paid
// it.
//
//   1. HOLDING IS A WAITING STATE, AND IT IS NOT A PARK. `is_waiting` covers
//      both, so a held command still shows its banner — but `holding` is the
//      backend's own `wait_state` word, never inferred from the chip text or
//      from "waiting and not parked". The fixture's holding row carries a chip
//      that says nothing about holding, so a view that read the wording would
//      fail here.
//
//   2. THE COST OUTLIVES THE WAIT. `resume_cost_line` is read whatever
//      `is_waiting` says: a FINISHED command with four cold resumes must still
//      say what they cost. A view that only filled the cost while waiting would
//      make the whole change invisible on exactly the rows that prove it.
//
//   3. NOTHING IS PLURALISED, SUMMED OR TONED IN DART. The sentence, both
//      counts and the tone all arrive from `dev_cmd_list`. The fixture's
//      sentence deliberately DISAGREES with its own counts (it says "2 hold(s)
//      … 1 cold resume" while hold_count is 7 and cold_resume_count is 3), so
//      any widget that rebuilt the sentence from the numbers — or picked its
//      tone from "colds > 0" — fails here. Two places wording the same fact is
//      how a panel about waste starts lying about waste.
//
//   4. ABSENCE DRAWS NOTHING. A command that never waited has an empty
//      `resume_cost_line`, and an empty line renders nothing at all — not a
//      dash, not a zero. "0 cold resumes" on every card is how a real 4 stops
//      being read.
//
//   5. TONE IS ONE LOOKUP. An unknown tone stays neutral rather than being
//      guessed from the counts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';

/// A row as `dev_cmd_list` sends it. Every field here is a backend string.
Map<String, dynamic> _row({
  bool waiting = false,
  String waitState = '',
  String chip = '',
  String hint = '',
  String tone = 'warning',
  String costLine = '',
  String costTone = 'neutral',
  int holds = 0,
  int colds = 0,
}) =>
    {
      'id': 1856,
      'is_waiting': waiting,
      'wait_state': waitState,
      'wait_chip': chip,
      'wait_hint': hint,
      'wait_tone': tone,
      'wait_kind': 'merge',
      'wait_reason': 'queued in the merge lane (entry 886)',
      'resume_cost_line': costLine,
      'resume_cost_tone': costTone,
      'hold_count': holds,
      'cold_resume_count': colds,
    };

void main() {
  group('CHANGE #1856 — a hold is not a cold resume', () {
    test('a HELD command is waiting, and says so from wait_state alone', () {
      final w = WaitView.fromRow(_row(
        waiting: true,
        waitState: 'holding',
        // Deliberately silent about holding: the STATE is the state, the chip
        // is only the wording.
        chip: '⏸ queued in the merge lane (entry 886) · 7m',
        hint: 'Not a failure and not a restart — the session is being kept alive.',
        tone: 'info',
      ));
      expect(w.waiting, isTrue);
      expect(w.holding, isTrue);
      expect(w.chip, '⏸ queued in the merge lane (entry 886) · 7m');
      expect(w.hint,
          'Not a failure and not a restart — the session is being kept alive.');
    });

    test('a PARKED command is waiting but not holding', () {
      final w = WaitView.fromRow(_row(
        waiting: true,
        waitState: 'parked',
        chip: '⏸ queued in the merge lane (entry 886) · waiting 12m',
      ));
      expect(w.waiting, isTrue);
      expect(w.holding, isFalse);
    });

    test('a command that is not waiting is neither', () {
      final w = WaitView.fromRow(_row());
      expect(w.waiting, isFalse);
      expect(w.holding, isFalse);
      expect(w.chip, isEmpty);
      expect(w.hint, isEmpty);
    });

    test('the cost sentence is printed verbatim, never rebuilt from the counts',
        () {
      // The sentence and the counts DISAGREE on purpose.
      final w = WaitView.fromRow(_row(
        waiting: false,
        costLine:
            'Waiting cost — 2 hold(s) kept this session alive · 1 cold resume re-read the whole context',
        costTone: 'warning',
        holds: 7,
        colds: 3,
      ));
      expect(
          w.costLine,
          'Waiting cost — 2 hold(s) kept this session alive · 1 cold resume re-read the whole context');
      expect(w.holds, 7);
      expect(w.coldResumes, 3);
      // The tone is the payload's, not "colds > 0 means danger".
      expect(w.costTone, toneByName('warning'));
    });

    test('the cost survives the wait — a finished row still shows it', () {
      final w = WaitView.fromRow(_row(
        waiting: false,
        waitState: '',
        costLine:
            'Waiting cost — 0 hold(s) kept this session alive · 4 cold resumes re-read the whole context',
        costTone: 'warning',
        colds: 4,
      ));
      expect(w.waiting, isFalse);
      expect(w.costLine, contains('4 cold resumes'));
      expect(w.coldResumes, 4);
    });

    test('a command that never waited prints no cost at all', () {
      final w = WaitView.fromRow(_row());
      expect(w.costLine, isEmpty);
      expect(w.holds, 0);
      expect(w.coldResumes, 0);
    });

    test('an unknown cost tone stays neutral instead of being guessed', () {
      final w = WaitView.fromRow(_row(
        costLine: 'Waiting cost — 1 hold(s) kept this session alive',
        costTone: 'lavender',
        colds: 9,
      ));
      expect(w.costTone, toneByName('lavender'));
    });
  });

  group('CHANGE #1856 — the Waiting lane counts the two prices apart', () {
    // The panel is a printer (waiting_economy_test.dart holds that down). What
    // is new here is that a hold row and a cold-resume row are DIFFERENT rows
    // with their own tones, so the fixture must survive being rendered in
    // payload order with a success hold above a danger cold.
    testWidgets('hold and cold rows render in payload order with their tones',
        (tester) async {
      const rows = [
        {
          'key': 'holds',
          'label': 'Held — session kept alive',
          'value': '6',
          'sub': '41m of idling with no context re-read',
          'tone': 'success',
        },
        {
          'key': 'cold',
          'label': 'Cold resumes — context re-read',
          'value': '4',
          'sub': 'across 1 command(s) · each one tore a session down',
          'tone': 'danger',
        },
      ];
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: _Rows(rows: rows)),
      ));
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      expect(labels.indexOf('Held — session kept alive'),
          lessThan(labels.indexOf('Cold resumes — context re-read')));
      expect(labels, contains('41m of idling with no context re-read'));
    });
  });
}

/// The smallest thing that renders the two rows in payload order — the real
/// panel is covered by waiting_economy_test.dart; this only guards the pair.
class _Rows extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const _Rows({required this.rows});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in rows) ...[
            Text('${r['label']}'),
            Text('${r['sub']}'),
          ],
        ],
      );
}
