// PROTECTED — CHANGE #369 (Finished means exit).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the dev-queue card reads the finish gate, never to
// make an unrelated change go green.
//
// The failure this pins down is #355: a build that had finished everything —
// 12/12 steps, CHANGE #855 live, QA and journeys green — and then ran for
// another fifteen minutes while its card still said `building`. The fix moved
// completion out of the model and into the harness, and the gate that decides
// it lives ENTIRELY in the backend.
//
// So what this test defends is the boundary, not the wording:
//   • the card prints the backend's sentence verbatim and composes none of it,
//   • the tone is the backend's tone NAME, resolved through the fixed palette,
//   • no chip means NOT READY — Dart must never infer readiness from
//     steps_done == steps_total, which is exactly the shortcut that would put
//     the "closing automatically" chip on a build that is still running.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_common.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/restart_safety.dart';

void main() {
  group('the finish gate is read, never computed', () {
    test('the chip is the backend sentence, printed verbatim', () {
      const sentence = '✅ All conditions met — closing automatically';
      final f = RowFinish(const {
        'status': 'building',
        'finish_chip': sentence,
        'finish_tone': 'info',
      });
      expect(f.show, isTrue);
      expect(f.label, sentence,
          reason: 'a Dart-composed finish sentence is the bug this prevents');
      expect(toneByName(f.tone), toneByName('info'));
    });

    test('a finished build with NO chip is not ready — Dart never infers it',
        () {
      // Every artefact of a finished build is present here EXCEPT the backend's
      // verdict. That must render nothing at all.
      final f = RowFinish(const {
        'status': 'building',
        'steps_done': 9,
        'steps_total': 9,
        'qa_status': 'passed',
        'preview_status': 'promoted',
        'web_deploy_no': 855,
      });
      expect(f.show, isFalse);
      expect(f.label, '');
      expect(f.autoFinished, isFalse);
    });

    test('an auto-completed row says so, with the source the backend stamped',
        () {
      final f = RowFinish(const {
        'status': 'completed',
        'finish_chip': '🤖 Auto-completed by the harness',
        'finish_tone': 'success',
        'auto_finished': true,
        'auto_finish_source': 'watchdog',
      });
      expect(f.autoFinished, isTrue);
      expect(f.source, 'watchdog',
          reason: 'harness vs watchdog is the backend\'s fact, not a guess');
      expect(toneByName(f.tone), toneByName('success'));
    });

    test('blockers are carried through in the backend\'s own words', () {
      final f = RowFinish(const {
        'status': 'building',
        'finish_blockers': ['steps 5/9', 'QA is pending'],
      });
      expect(f.blockers, ['steps 5/9', 'QA is pending']);
      expect(f.show, isFalse, reason: 'blocked is not a chip, it is silence');
    });

    test('an older payload degrades to silence, never to a white screen', () {
      const f = RowFinish(<String, dynamic>{});
      expect(f.show, isFalse);
      expect(f.autoFinished, isFalse);
      expect(f.source, '');
      expect(f.blockers, isEmpty);
      expect(toneByName(f.tone), toneByName('neutral'));
      // A malformed blockers field must not throw either.
      expect(const RowFinish({'finish_blockers': 'nonsense'}).blockers, isEmpty);
    });

    test('the tone is looked up, never invented from the status', () {
      final ready = RowFinish(const {'finish_chip': 'x', 'finish_tone': 'info'});
      final done =
          RowFinish(const {'finish_chip': 'y', 'finish_tone': 'success'});
      expect(toneByName(ready.tone), isNot(equals(toneByName(done.tone))));
      expect(toneByName('nonsense'), toneByName('neutral'));
      expect(toneByName(''), isA<Tone>());
    });
  });
}
