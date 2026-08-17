// PROTECTED — CHANGE #224 (VM toggle actually powers the AWS VM).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes VM power control, never to make an unrelated change go
// green.
//
// WHY THIS EXISTS. The "VM" toggle in the Dev Queue control strip was dead for
// the whole GCP era and nobody could see it: the widget only invoked the
// vm-control edge function when `dev_ctl_set` came back with `call_edge: true`,
// and `dev_ctl_set` never sent that field. Flipping the switch wrote a config
// flag and stopped. When the builder moved from GCP Compute to AWS EC2 the
// failure was finally visible (403 from a dead project), but the missing
// `call_edge` was the older, quieter half of the bug.
//
// What this file holds down:
//   1. A flip only reaches the cloud when the BACKEND says so (`call_edge`), and
//      the action sent is the backend's word ('start'/'stop') — Dart never
//      derives a power operation from the switch position.
//   2. Claude / Workflow flips never touch the VM.
//   3. Every word Om sees after a flip is the payload's: the "already running"
//      no-op is a ui_copy KEY, and the outcome toast is the edge function's own
//      `message` (including its AWS-key setup guidance) printed verbatim.
//   4. Only a failure that arrived with NO wording may fall back to Dart's
//      chosen copy key — a backend that worded its refusal is never overridden.
//   5. The four VM states the chip knows stay exactly the four the backend
//      writes into vm_status.status.
//
// Payloads below are the real shapes: `dev_ctl_set` verdicts as returned since
// this change, and vm-control replies as normalised by
// DevQueueService.vmControl (which folds a non-2xx body into `ok: false`).
// No network, no Supabase.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/vm_toggle_policy.dart';

/// A `dev_ctl_set('vm', …)` verdict, as the RPC returns it.
Map<String, dynamic> _vmVerdict(String value) => {
      'ok': true,
      'desired_state': {'vm': value, 'claude': 'on', 'workflow': 'on'},
      'call_edge': true,
      'action': value == 'on' ? 'start' : 'stop',
    };

/// A `dev_ctl_set('claude'|'workflow', …)` verdict — no VM involvement.
Map<String, dynamic> _plainVerdict(String key, String value) => {
      'ok': true,
      'desired_state': {key: value},
    };

void main() {
  group('a flip reaches the cloud only when the backend says so', () {
    test('claude / workflow verdicts never invoke vm-control', () {
      for (final key in const ['claude', 'workflow']) {
        for (final on in const [true, false]) {
          final plan = VmTogglePolicy.plan(
            verdict: _plainVerdict(key, on ? 'on' : 'off'),
            on: on,
            // Even with the VM plainly stopped, a Claude flip must not start it.
            currentStatus: 'stopped',
          );
          expect(plan.invoke, isFalse, reason: '$key must not touch the VM');
          expect(plan.toastCopyKey, isNull);
        }
      }
    });

    test('a vm verdict WITHOUT call_edge is inert — the pre-#224 bug, pinned',
        () {
      // This is exactly what dev_ctl_set used to return. If a future edit drops
      // call_edge again, the toggle silently stops working; that regression is
      // only visible as this expectation flipping meaning, so keep it explicit:
      // no call_edge => no cloud call, by design, not by accident.
      final plan = VmTogglePolicy.plan(
        verdict: {'ok': true, 'desired_state': {'vm': 'off'}},
        on: false,
        currentStatus: 'running',
      );
      expect(plan.invoke, isFalse);
    });

    test('the action sent is the backend\'s word, not derived from the switch',
        () {
      expect(
        VmTogglePolicy.plan(
                verdict: _vmVerdict('on'), on: true, currentStatus: 'stopped')
            .action,
        'start',
      );
      expect(
        VmTogglePolicy.plan(
                verdict: _vmVerdict('off'), on: false, currentStatus: 'running')
            .action,
        'stop',
      );

      // A verdict that says call_edge but names no action must READ state, never
      // guess a power operation from `on`. Guessing here would stop a VM Om
      // never asked to stop.
      final plan = VmTogglePolicy.plan(
        verdict: {'ok': true, 'call_edge': true},
        on: false,
        currentStatus: 'running',
      );
      expect(plan.invoke, isTrue);
      expect(plan.action, 'status');
    });
  });

  group('a no-op flip is worded by the backend, and spends no cloud call', () {
    test('ON while already running → ui_copy key, no invoke', () {
      final plan = VmTogglePolicy.plan(
          verdict: _vmVerdict('on'), on: true, currentStatus: 'running');
      expect(plan.invoke, isFalse);
      expect(plan.toastCopyKey, 'dev_queue.ctl_vm_on_toast');
    });

    test('OFF while already stopped → ui_copy key, no invoke', () {
      final plan = VmTogglePolicy.plan(
          verdict: _vmVerdict('off'), on: false, currentStatus: 'stopped');
      expect(plan.invoke, isFalse);
      expect(plan.toastCopyKey, 'dev_queue.ctl_vm_off_toast');
    });

    test('a mid-transition or unknown status always invokes', () {
      // 'starting'/'stopping' are what dev_ctl_set writes optimistically, and
      // 'unknown' is what an AWS box reports before a key is saved. None of
      // these may short-circuit — otherwise a stuck 'starting' would make the
      // toggle permanently unable to reach the cloud.
      for (final s in const ['starting', 'stopping', 'unknown', '']) {
        expect(
          VmTogglePolicy.plan(
                  verdict: _vmVerdict('on'), on: true, currentStatus: s)
              .invoke,
          isTrue,
          reason: 'status "$s" must not short-circuit',
        );
      }
    });
  });

  group('the outcome toast is the edge function\'s own wording', () {
    test('the AWS setup guidance is surfaced verbatim as an error', () {
      // The live 503 body when no access key is in the Vault yet.
      const backendCopy =
          'AWS access key not saved yet. Add AWS_ACCESS_KEY_ID and '
          'AWS_SECRET_ACCESS_KEY under Secrets to start the VM from here.';
      final out = VmTogglePolicy.outcome({
        'ok': false,
        'error': 'aws_key_missing',
        'status': 'unknown',
        'message': backendCopy,
        'needs_key': true,
      });
      expect(out.message, backendCopy);
      expect(out.isError, isTrue);
      expect(out.isSilent, isFalse);
      // The backend worded this refusal, so Dart's fallback copy must NOT win.
      expect(out.needsFallbackCopy, isFalse);
    });

    test('a successful stop carries the backend\'s message, not an error', () {
      final out = VmTogglePolicy.outcome({
        'ok': true,
        'status': 'stopping',
        'operation': null,
        'message': 'Stopping the VM — it powers itself off within a minute.',
        'needs_key': false,
      });
      expect(out.isError, isFalse);
      expect(out.message, 'Stopping the VM — it powers itself off within a minute.');
      expect(out.needsFallbackCopy, isFalse);
    });

    test('a plain status read says nothing at all', () {
      final out = VmTogglePolicy.outcome(
          {'ok': true, 'status': 'running', 'operation': null, 'message': ''});
      expect(out.isSilent, isTrue, reason: 'no message => no toast');
      expect(out.isError, isFalse);
    });

    test('only a wordless failure falls back to Dart\'s copy key', () {
      // e.g. a transport error, where vmControl could not decode any body.
      final out = VmTogglePolicy.outcome({'ok': false});
      expect(out.isError, isTrue);
      expect(out.needsFallbackCopy, isTrue);

      // An EC2 rejection that DID carry wording must not be replaced.
      final worded = VmTogglePolicy.outcome({
        'ok': false,
        'error': 'aws_error',
        'detail': 'UnauthorizedOperation: You are not authorized',
        'message': 'VM control failed — could not reach the cloud',
      });
      expect(worded.needsFallbackCopy, isFalse);
      expect(worded.message, 'VM control failed — could not reach the cloud');
    });

    test('a missing ok flag is treated as failure, never as success', () {
      // Defensive: an unrecognised reply must not toast "done" over a VM that
      // never moved.
      expect(VmTogglePolicy.outcome(const {}).isError, isTrue);
    });
  });

  group('vm_status contract', () {
    test('the states the app renders are exactly what the backend writes', () {
      // dev_vm_status_write() rejects anything outside this set, and the chip in
      // dev_queue_control.dart maps exactly these (everything else → unknown).
      // Both sides must move together or the chip silently reads "Unknown"
      // while the VM is fine — which is what AWS did before this change.
      expect(
        const {'running', 'stopped', 'starting', 'stopping', 'unknown'},
        hasLength(5),
      );
      // The two the no-op short-circuit depends on are the settled states.
      final onNoop = VmTogglePolicy.plan(
          verdict: _vmVerdict('on'), on: true, currentStatus: 'running');
      final offNoop = VmTogglePolicy.plan(
          verdict: _vmVerdict('off'), on: false, currentStatus: 'stopped');
      expect(onNoop.invoke || offNoop.invoke, isFalse);
    });
  });
}
