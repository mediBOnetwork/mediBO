// PROTECTED — CHANGE #571 (completion integrity).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how a WAITING command or a spec checklist is rendered,
// never to make an unrelated change go green.
//
// What this holds down — the two states #536 could not show:
//   • WAITING IS NOT FAILING. A command parked on a lease, a merge retry or a
//     busy database is still `building`. The chip text, the reassurance line
//     and the tone are the BACKEND's; the flag `is_waiting` is the state. A
//     wait_chip that arrives without the flag renders nothing, and a wait is
//     never dressed in the failed tone.
//   • THE SPEC CHECKLIST IS THE BACKEND'S. Items render in payload order with
//     the backend's own status_label and tone; the app never decides an item
//     is built, never re-sorts, never counts the open ones itself, and never
//     invents a note for an item that carries none.
//
// If a future edit turns a wait reason into a Dart literal, sorts the
// checklist, or computes "done" from anything but the payload, this is where
// it must be justified.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';

void main() {
  group('waiting is not failing', () {
    test('a parked row prints the backend chip and hint verbatim', () {
      final w = WaitView.fromRow({
        'status': 'building',
        'is_waiting': true,
        'wait_chip': '⏸ Waiting on a file lease · waiting 4m',
        'wait_hint': 'Not a failure — the work is committed and resumes '
            'automatically when the blocker clears.',
        'wait_reason': 'Waiting on a file lease',
        'wait_kind': 'lease',
        'wait_tone': 'warning',
      });
      expect(w.waiting, isTrue);
      expect(w.chip, '⏸ Waiting on a file lease · waiting 4m');
      expect(
          w.hint,
          'Not a failure — the work is committed and resumes automatically '
          'when the blocker clears.');
      expect(w.reason, 'Waiting on a file lease');
      expect(w.kind, 'lease');
      // The one thing a wait must never look like.
      expect(w.tone, isNot(equals(statusTone('failed'))));
      expect(w.tone, equals(toneByName('warning')));
    });

    test('the FLAG is the state — a chip without it renders nothing', () {
      final w = WaitView.fromRow({
        'status': 'building',
        'wait_chip': '⏸ stale text from a previous poll',
        'wait_hint': 'stale hint',
      });
      expect(w.waiting, isFalse);
      expect(w.chip, isEmpty);
      expect(w.hint, isEmpty);
    });

    test('an ordinary building row contributes no wait chip at all', () {
      final w = WaitView.fromRow({'status': 'building', 'is_waiting': false});
      expect(w.waiting, isFalse);
      expect(w.chip, isEmpty);
    });

    test('an unknown tone name degrades to neutral instead of throwing', () {
      final w = WaitView.fromRow(
          {'is_waiting': true, 'wait_chip': 'x', 'wait_tone': 'chartreuse'});
      expect(w.tone, equals(toneByName('neutral')));
    });
  });

  group('the spec checklist is the backend\'s', () {
    // Deliberately NOT in numeric order: the screen must not sort.
    final payload = <String, dynamic>{
      'title': 'Spec checklist',
      'chip': 'Spec 1/3',
      'open': 2,
      'total': 3,
      'items': [
        {
          'n': 2,
          'text': 'WAIT IS NOT FAILURE',
          'status': 'done',
          'status_label': 'Built',
          'evidence': 'dev_fail_rule + dev_cmd_park',
          'drop_reason': '',
          'tone': 'success',
        },
        {
          'n': 1,
          'text': 'RETRYABLE COMPLETION',
          'status': 'open',
          'status_label': 'Open',
          'evidence': '',
          'drop_reason': '',
          'tone': 'warning',
        },
        {
          'n': 3,
          'text': 'SPEC-GATED FINISH',
          'status': 'dropped',
          'status_label': 'Dropped',
          'evidence': '',
          'drop_reason': 'covered by #572',
          'tone': 'neutral',
        },
      ],
    };

    test('items render in payload order — no client sort', () {
      final items = SpecItemView.listOf(payload);
      expect(items.map((i) => i.n).toList(), [2, 1, 3]);
    });

    test('status, label and tone are printed, never derived', () {
      final items = SpecItemView.listOf(payload);
      expect(items[0].statusLabel, 'Built');
      expect(items[0].open, isFalse);
      expect(items[1].statusLabel, 'Open');
      expect(items[1].open, isTrue);
      expect(items[2].statusLabel, 'Dropped');
      // A dropped item is NOT open — but it is not "success" either; the
      // backend's own tone is what the chip wears.
      expect(items[2].open, isFalse);
      expect(items[2].tone, equals(toneByName('neutral')));
      expect(items[0].tone, equals(toneByName('success')));
    });

    test('the note is the drop reason, else the evidence, else nothing', () {
      final items = SpecItemView.listOf(payload);
      expect(items[0].note, 'dev_fail_rule + dev_cmd_park'); // evidence
      expect(items[1].note, isEmpty); // neither
      expect(items[2].note, 'covered by #572'); // drop reason wins
    });

    test('the open count is the backend\'s number, not a client tally', () {
      // The payload says 2 open while only 1 item carries status "open" — the
      // BACKEND is the authority the finish gate refuses on, so that is the
      // number the screen shows.
      expect(SpecItemView.openCount(payload), 2);
      expect(SpecItemView.listOf(payload).where((i) => i.open).length, 1);
    });

    test('a spec with no items renders nothing at all', () {
      expect(SpecItemView.listOf(const {}), isEmpty);
      expect(SpecItemView.listOf(const {'items': []}), isEmpty);
      expect(SpecItemView.openCount(const {}), 0);
    });
  });
}
