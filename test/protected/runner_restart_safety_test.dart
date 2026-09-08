// PROTECTED — CHANGE #233. VM-restart safety.
//
// Om restarts the VM daily for the 5h limit. Rows #229 and #230 sat reading
// "building", with a worker chip and a live countdown, long after the box that
// was building them had gone. This file pins the three decisions that stop
// that from ever being drawn again, plus the checkpoint state that stops a
// released row from being rebuilt from zero.
//
// Everything asserted here is a BACKEND value. The rule under test is not
// "Dart formats this correctly" — it is "Dart shows exactly what the backend
// said and invents nothing", including inventing optimism when a field is
// missing from an older payload.
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/restart_safety.dart';

Map<String, dynamic> buildingRow({
  bool? isLive,
  String claimedBy = 'runner-1',
  bool hasEta = true,
  String liveChip = '',
  String stallChip = '',
  String stepsChip = '',
  String resumeChip = '',
  String agentChip = '',
  String agentTone = '',
  int sessionLost = 0,
  String startedFlags = '',
  int stepsDone = 0,
  int stepsTotal = 0,
}) =>
    {
      'id': 233,
      'status': 'building',
      'claimed_by': claimedBy,
      'has_eta': hasEta,
      if (isLive != null) 'is_live': isLive,
      'live_chip': liveChip,
      'stall_chip': stallChip,
      'steps_chip': stepsChip,
      'resume_chip': resumeChip,
      'agent_chip': agentChip,
      if (agentTone.isNotEmpty) 'agent_tone': agentTone,
      'session_lost_count': sessionLost,
      'started_flags': startedFlags,
      'steps_done': stepsDone,
      'steps_total': stepsTotal,
    };

void main() {
  group('a building row only looks alive while the backend says it is', () {
    test('live row shows its worker and its countdown', () {
      final l = RowLiveness(buildingRow(isLive: true));
      expect(l.showWorker, isTrue);
      expect(l.showCountdown, isTrue);
    });

    test('is_live:false hides the worker chip AND the countdown', () {
      // This is the #229/#230 state: status is still 'building' in the table,
      // but nothing is behind it. Neither the worker nor a shrinking clock may
      // be drawn from a status alone.
      final l = RowLiveness(buildingRow(isLive: false));
      expect(l.showWorker, isFalse);
      expect(l.showCountdown, isFalse, reason: 'a dead worker has no ETA');
    });

    test('a MISSING is_live is treated as not live, never as live', () {
      // Forward/backward compat: an older cached payload must degrade to the
      // honest state, not to the optimistic one.
      final l = RowLiveness(buildingRow(isLive: null));
      expect(l.isLive, isFalse);
      expect(l.showWorker, isFalse);
      expect(l.showCountdown, isFalse);
    });

    test('has_eta:false never produces a countdown even on a live row', () {
      final l = RowLiveness(buildingRow(isLive: true, hasEta: false));
      expect(l.showCountdown, isFalse);
    });

    test('a live row with no worker name shows no worker chip', () {
      final l = RowLiveness(buildingRow(isLive: true, claimedBy: ''));
      expect(l.showWorker, isFalse);
    });

    test('a non-building row is never given a worker or a countdown', () {
      final row = buildingRow(isLive: true)..['status'] = 'pending';
      final l = RowLiveness(row);
      expect(l.showWorker, isFalse);
      expect(l.showCountdown, isFalse);
    });
  });

  group('restart-safety chips are backend strings, worst news first', () {
    test('every chip prints verbatim, in offline → stall → steps → resumed order', () {
      final l = RowLiveness(buildingRow(
        isLive: false,
        liveChip: 'Worker offline — no heartbeat for 12m',
        stallChip: 'Tokens frozen 20m — build may be stuck',
        stepsChip: 'Step 4 of 7',
        resumeChip: 'Resumed 2×',
      ));
      expect(l.chips.map((c) => c.kind).toList(), [
        SafetyChipKind.offline,
        SafetyChipKind.stall,
        SafetyChipKind.steps,
        SafetyChipKind.resumed,
      ]);
      expect(l.chips.map((c) => c.label).toList(), [
        'Worker offline — no heartbeat for 12m',
        'Tokens frozen 20m — build may be stuck',
        'Step 4 of 7',
        'Resumed 2×',
      ]);
    });

    test('an omitted chip is absent, never substituted with a Dart string', () {
      final l = RowLiveness(buildingRow(isLive: true, stepsChip: 'Step 1 of 5'));
      expect(l.chips.length, 1);
      expect(l.chips.single.kind, SafetyChipKind.steps);
      expect(l.chips.single.label, 'Step 1 of 5');
    });

    test('a row with no plan at all shows no chips', () {
      expect(RowLiveness(buildingRow(isLive: true)).chips, isEmpty);
    });

    test('the age inside a chip is never recomputed in Dart', () {
      // The backend already substituted {age}. Whatever it said is what shows —
      // if Dart ever starts formatting this, the string here will not match.
      final l = RowLiveness(buildingRow(
          isLive: false, liveChip: 'Worker offline — no heartbeat for 1h 3m'));
      expect(l.chips.single.label, 'Worker offline — no heartbeat for 1h 3m');
    });
  });

  group('checkpoint progress is counted by the backend', () {
    test('steps_done / steps_total are read through untouched', () {
      final l = RowLiveness(buildingRow(stepsDone: 4, stepsTotal: 7));
      expect(l.stepsDone, 4);
      expect(l.stepsTotal, 7);
      expect(l.hasPlan, isTrue);
    });

    test('no plan means no steps card', () {
      expect(RowLiveness(buildingRow()).hasPlan, isFalse);
    });
  });

  group('the live-view badge is honest in both directions', () {
    test('reachable bridge renders the backend label and success tone', () {
      const b = RemoteBadge({
        'remote_control': 'on',
        'remote_display': 'On phone',
        'remote_tone': 'success',
      });
      expect(b.show, isTrue);
      expect(b.isOn, isTrue);
      expect(b.display, 'On phone');
      expect(b.tone, 'success');
    });

    test('unreachable bridge still renders — "off" is a visible state', () {
      // Before #233 the badge simply vanished when remote_control was off, so
      // "the bridge is down" and "the panel forgot to say" looked identical.
      const b = RemoteBadge({
        'remote_control': 'off',
        'remote_display': 'Live view off',
        'remote_tone': 'neutral',
      });
      expect(b.show, isTrue);
      expect(b.isOn, isFalse);
      expect(b.display, 'Live view off');
    });

    test('no label from the backend means no badge — Dart writes none', () {
      const b = RemoteBadge({'remote_control': 'on'});
      expect(b.show, isFalse);
      expect(b.display, isEmpty);
    });
  });

  group('the worker grid follows the pool heartbeat', () {
    test('a fresh snapshot renders its workers and no banner', () {
      const p = PoolLiveness({
        'workers': [
          {'id': 'runner-1', 'status': 'building', 'command_id': 233}
        ],
        'active_workers': 1,
        'stale_display': '',
      });
      expect(p.workers.length, 1);
      expect(p.activeWorkers, 1);
      expect(p.isStale, isFalse);
    });

    test('a stale snapshot draws the backend banner and zero workers', () {
      // dev_ctl_get blanks the list server-side; the grid must NOT reconstruct
      // it from anything it remembers.
      const p = PoolLiveness({
        'workers': [],
        'active_workers': 0,
        'stale_display': 'Workers offline — no heartbeat from the VM',
      });
      expect(p.workers, isEmpty);
      expect(p.activeWorkers, 0);
      expect(p.isStale, isTrue);
      expect(p.staleDisplay, 'Workers offline — no heartbeat from the VM');
    });

    test('an empty state object degrades quietly', () {
      const p = PoolLiveness(<String, dynamic>{});
      expect(p.workers, isEmpty);
      expect(p.activeWorkers, 0);
      expect(p.isStale, isFalse);
    });
  });

  // ── CHANGE #1023 — the agent's liveness is not the runner's ───────────────
  //
  // #1016 held `building` for 32 minutes after its Remote Control session
  // dropped. Nothing on the card said so, because the only liveness the card
  // had was `is_live` / `live_chip` — the HEARTBEAT — and the heartbeat was
  // being sent by a bash subshell that outlived the Claude session it was
  // started for. These pin the second, separate signal.
  group('agent liveness is a chip of its own, and it is the backend\'s', () {
    test('agent_chip prints verbatim and sits between offline and stall', () {
      final l = RowLiveness(buildingRow(
        isLive: false,
        liveChip: 'Worker offline — no heartbeat for 12m',
        agentChip: '⚠ agent silent 6m — session may be lost',
        stallChip: 'Tokens frozen 20m — build may be stuck',
        stepsChip: 'Step 0 of 5',
      ));
      expect(l.chips.map((c) => c.kind).toList(), [
        SafetyChipKind.offline,
        SafetyChipKind.agentSilent,
        SafetyChipKind.stall,
        SafetyChipKind.steps,
      ]);
      expect(l.chips[1].label, '⚠ agent silent 6m — session may be lost');
    });

    test('the amber is the backend\'s tone, not a Dart constant', () {
      final l = RowLiveness(buildingRow(
          agentChip: '⚠ agent silent 6m', agentTone: 'warning'));
      expect(l.chips.single.tone, 'warning');
      // …and a payload that chose a different tone is obeyed, not overruled.
      final e = RowLiveness(
          buildingRow(agentChip: '⚠ agent silent 31m', agentTone: 'error'));
      expect(e.chips.single.tone, 'error');
    });

    test('a live heartbeat with a dead agent still raises the chip', () {
      // The exact #1016 state: is_live TRUE (the subshell is beating), the
      // agent gone. The worker chip stays — the runner really is there — and
      // the agent chip is what tells the truth.
      final l = RowLiveness(
          buildingRow(isLive: true, agentChip: '⚠ agent silent 6m'));
      expect(l.showWorker, isTrue);
      expect(l.agentSilent, isTrue);
      expect(l.chips.single.kind, SafetyChipKind.agentSilent);
    });

    test('an older payload with no agent_chip degrades to "session is fine"', () {
      final row = buildingRow(isLive: true)..remove('agent_chip');
      final l = RowLiveness(row);
      expect(l.agentSilent, isFalse);
      expect(l.chips, isEmpty);
    });

    test('the flags the run started with are printed, never composed', () {
      final l = RowLiveness(buildingRow(
          startedFlags: '▶ started: claude-fable-5-1 / extra (remote-control)',
          sessionLost: 2));
      expect(l.startedFlags,
          '▶ started: claude-fable-5-1 / extra (remote-control)');
      expect(l.sessionLost, 2);
      // Absent is empty, never a guess at what the runner probably used.
      expect(RowLiveness(<String, dynamic>{}).startedFlags, '');
      expect(RowLiveness(<String, dynamic>{}).sessionLost, 0);
    });
  });

}
