// CHANGE #350 — step progress must tick itself.
//
// #340 sat at "Step 0 of 7" with 550K tokens spent and a change already
// promoted. The card's checklist was a lie, and nothing on the screen said so.
// The backend now flags a checklist that stopped being reported; these tests
// pin the ONE thing the frontend is allowed to do about it: print what the
// backend said, in the right order, and never invent the warning itself.
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/restart_safety.dart';

Map<String, dynamic> row({
  String status = 'building',
  bool isLive = true,
  String liveChip = '',
  String stallChip = '',
  String stepsStaleChip = '',
  String stepsStaleHint = '',
  String stepsChip = '',
  String resumeChip = '',
  int stepsDone = 0,
  int stepsTotal = 0,
}) =>
    {
      'status': status,
      'claimed_by': 'runner-2',
      'is_live': isLive,
      'live_chip': liveChip,
      'stall_chip': stallChip,
      'steps_stale_chip': stepsStaleChip,
      'steps_stale_hint': stepsStaleHint,
      'steps_chip': stepsChip,
      'resume_chip': resumeChip,
      'steps_done': stepsDone,
      'steps_total': stepsTotal,
    };

void main() {
  group('the stale-checklist warning is the backend\'s, not Dart\'s', () {
    test('the warning sits immediately before the progress chip it distrusts',
        () {
      final l = RowLiveness(row(
        stepsStaleChip: 'Steps not being reported — checklist may be stale (22m)',
        stepsChip: 'Step 0 of 7',
      ));
      expect(l.chips.map((c) => c.kind).toList(),
          [SafetyChipKind.stepsStale, SafetyChipKind.steps]);
      // Verbatim: the age was measured and formatted server-side.
      expect(l.chips.first.label,
          'Steps not being reported — checklist may be stale (22m)');
      expect(l.chips.first.tone, 'warning');
    });

    test('full order stays offline → stall → stale → steps → resumed', () {
      final l = RowLiveness(row(
        isLive: false,
        liveChip: 'Worker offline — no heartbeat for 12m',
        stallChip: 'Tokens frozen 20m — build may be stuck',
        stepsStaleChip: 'Steps not being reported — checklist may be stale (14m)',
        stepsChip: 'Step 2 of 8',
        resumeChip: 'Resumed 2×',
      ));
      expect(l.chips.map((c) => c.kind).toList(), [
        SafetyChipKind.offline,
        SafetyChipKind.stall,
        SafetyChipKind.stepsStale,
        SafetyChipKind.steps,
        SafetyChipKind.resumed,
      ]);
    });

    test('a healthy build shows the progress chip and no warning', () {
      final l = RowLiveness(row(stepsChip: 'Step 5 of 8', stepsDone: 5, stepsTotal: 8));
      expect(l.chips.map((c) => c.kind).toList(), [SafetyChipKind.steps]);
      expect(l.stepsStale, isFalse);
      expect(l.stepsStaleHint, isEmpty);
    });

    test(
        'Dart never derives the warning — "Step 0 of 7" alone is not enough to '
        'call a checklist stale', () {
      // Tokens climbing while steps stand still is the BACKEND's measurement
      // (dev_cmd_watchdog). A screen that guessed it from steps_done==0 would
      // shout at every build during its first step.
      final l = RowLiveness(row(stepsChip: 'Step 0 of 7', stepsTotal: 7));
      expect(l.stepsStale, isFalse);
      expect(l.chips.map((c) => c.kind).toList(), [SafetyChipKind.steps]);
    });

    test('an older payload with no stale keys degrades to trusted, not warned',
        () {
      final l = RowLiveness({
        'status': 'building',
        'is_live': true,
        'steps_chip': 'Step 1 of 4',
        'steps_done': 1,
        'steps_total': 4,
      });
      expect(l.stepsStale, isFalse);
      expect(l.chips.single.kind, SafetyChipKind.steps);
    });

    test('the hint is carried through untouched for the detail screen', () {
      final l = RowLiveness(row(
        stepsStaleChip: 'Steps not being reported — checklist may be stale (30m)',
        stepsStaleHint:
            'This checklist has not moved while the build kept spending. Treat it as untrusted until the worker syncs it.',
        stepsChip: 'Step 0 of 6',
      ));
      expect(l.stepsStale, isTrue);
      expect(
          l.stepsStaleHint,
          'This checklist has not moved while the build kept spending. '
          'Treat it as untrusted until the worker syncs it.');
    });
  });
}
