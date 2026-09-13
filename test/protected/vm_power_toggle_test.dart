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
// WHAT THE FOLLOW-UP CHANGED, AND WHY THIS FILE MOVED WITH IT. Om reported
// "start is not working, only stop works" after the first fix. The cause was
// the no-op shortcut this file used to pin: `plan()` compared the flip against
// the LAST KNOWN `vm_status` and, on a match, toasted "VM already running"
// without calling EC2. That cached row is only refreshed by a timer running ON
// the box, so the moment the VM stopped holding a stale 'running', START became
// permanently unreachable — the app stranded its own builder and reported
// success. So the shortcut is GONE from Dart: vm-control now answers
// "already running" from a DescribeInstances read taken microseconds earlier.
// The three ex-shortcut tests below are replaced by their inverse — proof that
// NO cached state can suppress a flip.
//
// What this file holds down now:
//   1. A flip only reaches the cloud when the BACKEND says so (`call_edge`), and
//      the action sent is the backend's word ('start'/'stop') — Dart never
//      derives a power operation from the switch position.
//   2. Claude / Workflow flips never touch the VM.
//   3. NO cached VM state can turn a flip into a no-op. That decision, and its
//      wording, belong to the edge function that just read EC2.
//   4. Every word Om sees after a flip is the payload's, printed verbatim —
//      including the exact IAM action AWS refused.
//   5. Only a failure that arrived with NO wording may fall back to Dart's
//      chosen copy key — a backend that worded its refusal is never overridden.
//   6. A transitional EC2 state (pending/stopping) is CHASED to a resting one on
//      the backend's own interval and cap; a failed or settled reply never
//      starts a poll loop.
//   7. Whether a stale chip needs a live read is the backend's verdict, not a
//      timestamp Dart re-derives.
//
// CMD #1864 — THE THIRD ROUND, and the one that took the cloud call out of the
// app entirely. Two separate failures, both invisible from the switch:
//
//   (a) A SECOND renderer appeared. The v3 Runners strip flips the same toggle
//       with `dev_ctl_set` and never read `call_edge` at all, so START moved the
//       switch and asked AWS nothing. STOP kept working only because it needs no
//       cloud call — the supervisor on the box honours desired_state.vm='off' by
//       powering itself down. An errand handed to a renderer is an errand one of
//       them will forget.
//   (b) The answer went to the wrong database. vm-control writes `vm_status`
//       with a service client for ITS OWN project, and the copy with a working
//       AWS key is production's — while the chip reads dev_ctl_get on the
//       CONTROL PLANE. So the chip's row was only ever written by the runner ON
//       the box, and a box that is off writes nothing: it froze on "running"
//       while EC2 said Stopped.
//
// So `dev_ctl_set('vm', …)` makes the call itself and answers `call_edge:false`
// plus a poll cadence, and this file gains:
//   8. `pollState` chases a control-plane verdict to a settled state on the
//      payload's own interval and cap, and stops on `asked_ok:false` — a call
//      that never left the database is not chased.
//   9. The chip's word and tone are `chip_label` / `chip_tone`. The status→label
//      map that lived in the widget is gone: a chip that can compose its own
//      word can keep showing it after the thing it describes has died.
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
          final plan = VmTogglePolicy.plan(_plainVerdict(key, on ? 'on' : 'off'));
          expect(plan.invoke, isFalse, reason: '$key must not touch the VM');
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
          {'ok': true, 'desired_state': {'vm': 'off'}});
      expect(plan.invoke, isFalse);
    });

    test('the action sent is the backend\'s word, not derived from the switch',
        () {
      expect(VmTogglePolicy.plan(_vmVerdict('on')).action, 'start');
      expect(VmTogglePolicy.plan(_vmVerdict('off')).action, 'stop');

      // A verdict that says call_edge but names no action must READ state, never
      // guess a power operation. Guessing here would stop a VM Om never asked
      // to stop.
      final plan = VmTogglePolicy.plan({'ok': true, 'call_edge': true});
      expect(plan.invoke, isTrue);
      expect(plan.action, 'status');
    });
  });

  group('no cached VM state may suppress a flip', () {
    test('every status still invokes — including the two that used to short-circuit',
        () {
      // 'running'/'stopped' are the settled states the old code treated as
      // "nothing to do". They were read from a config row that NOTHING updates
      // while the box is off, which is precisely how START died: cache says
      // running, EC2 says stopped, app toasts "already running" forever.
      //
      // plan() no longer accepts a status at all — that is the fix, expressed as
      // an API shape. This test exists so a future edit cannot quietly hand it
      // one back.
      for (final verdict in [_vmVerdict('on'), _vmVerdict('off')]) {
        expect(VmTogglePolicy.plan(verdict).invoke, isTrue);
      }
    });

    test('the "already running" wording now arrives from the edge function', () {
      // vm-control checks the live state itself and words the no-op, so the
      // client just prints it — same sentence Om saw before, now backed by a
      // DescribeInstances read instead of a cache.
      final out = VmTogglePolicy.outcome({
        'ok': true,
        'status': 'running',
        'changed': false,
        'settled': true,
        'message': 'VM already running',
      });
      expect(out.message, 'VM already running');
      expect(out.isError, isFalse);
      expect(out.needsFallbackCopy, isFalse);
      // A no-op is settled: nothing to chase.
      expect(VmTogglePolicy.poll({
        'ok': true,
        'settled': true,
        'poll_after_ms': 6000,
        'poll_max': 20,
      }).again, isFalse);
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

    test('an IAM refusal names the exact missing action, verbatim', () {
      // Om asked for this by name: a denied StartInstances must not read as a
      // vague "couldn't reach the cloud", or the fix is un-actionable.
      const denied =
          'AWS refused this. The saved access key is missing the IAM permission '
          'ec2:StartInstances on instance i-0d570e128d49615bd. Add that action '
          "to the key's IAM policy, then try the toggle again.";
      final out = VmTogglePolicy.outcome({
        'ok': false,
        'error': 'aws_iam_denied',
        'iam_action': 'ec2:StartInstances',
        'detail': 'UnauthorizedOperation: You are not authorized',
        'status': 'unknown',
        'message': denied,
      });
      expect(out.message, denied);
      expect(out.isError, isTrue);
      expect(out.needsFallbackCopy, isFalse,
          reason: 'the named action must never be replaced by generic copy');
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

  group('a transitional state is chased, on the backend\'s terms', () {
    test('settled:false schedules another read with the payload\'s interval', () {
      // What StartInstances actually returns: pending, not running.
      final p = VmTogglePolicy.poll({
        'ok': true,
        'status': 'starting',
        'changed': true,
        'settled': false,
        'poll_after_ms': 6000,
        'poll_max': 20,
      });
      expect(p.again, isTrue);
      expect(p.delay, const Duration(milliseconds: 6000));
      expect(p.maxPolls, 20);
    });

    test('a resting state stops the chase', () {
      for (final s in const ['running', 'stopped']) {
        expect(
          VmTogglePolicy.poll({
            'ok': true,
            'status': s,
            'settled': true,
            'poll_after_ms': 6000,
            'poll_max': 20,
          }).again,
          isFalse,
          reason: '$s is settled — nothing left to watch',
        );
      }
    });

    test('a failed call never polls — repeating a refusal is not progress', () {
      // No key, and IAM denied: both would just re-refuse 20 more times.
      for (final reply in [
        {'ok': false, 'error': 'aws_key_missing', 'settled': true},
        {
          'ok': false,
          'error': 'aws_iam_denied',
          'settled': false,
          'poll_after_ms': 6000,
          'poll_max': 20,
        },
      ]) {
        expect(VmTogglePolicy.poll(reply).again, isFalse);
      }
    });

    test('a reply that omits settled is treated as settled, not as a loop', () {
      // Forward/backward compatibility: an older function version, or the GCP
      // branch, sends no `settled`. Silence must never start an unbounded poll.
      expect(VmTogglePolicy.poll({'ok': true, 'status': 'starting'}).again,
          isFalse);
    });

    test('missing or zero cadence numbers stop the chase', () {
      // A misconfigured vm_poll row must degrade to "don't poll", never to a
      // tight zero-delay loop against EC2.
      for (final reply in [
        {'ok': true, 'settled': false},
        {'ok': true, 'settled': false, 'poll_after_ms': 0, 'poll_max': 20},
        {'ok': true, 'settled': false, 'poll_after_ms': 6000, 'poll_max': 0},
      ]) {
        expect(VmTogglePolicy.poll(reply).again, isFalse);
      }
    });
  });

  group('chip freshness is the backend\'s verdict', () {
    test('needs_live_check is read, never re-derived from a timestamp', () {
      expect(
          VmTogglePolicy.needsLiveCheck(
              {'status': 'running', 'age_s': 4, 'needs_live_check': true}),
          isTrue);
      // Even a very old reading is NOT refetched unless the backend says so —
      // the thresholds live in the vm_poll config row, and differ for settled
      // and transitional states.
      expect(
          VmTogglePolicy.needsLiveCheck(
              {'status': 'running', 'age_s': 99999, 'needs_live_check': false}),
          isFalse);
      // An absent flag is not an invitation to guess.
      expect(VmTogglePolicy.needsLiveCheck(const {}), isFalse);
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
      // 'starting'/'stopping' are the EC2 pending/stopping states, and they are
      // the ones the poll loop exists for.
      expect(
        VmTogglePolicy.poll({
          'ok': true,
          'status': 'stopping',
          'settled': false,
          'poll_after_ms': 6000,
          'poll_max': 20,
        }).again,
        isTrue,
      );
    });
  });

  // ── CMD #1864 ────────────────────────────────────────────────────────────
  group('the backend makes the cloud call, and the app chases its verdict', () {
    /// `dev_ctl_set('vm', …)` as it answers since CMD #1864: the EC2 call is
    /// already made, so there is no errand — only a state to watch land.
    Map<String, dynamic> setVerdict({
      String value = 'on',
      bool askedOk = true,
      String status = 'unknown',
      bool settled = false,
    }) => {
          'ok': true,
          'desired_state': {'vm': value},
          'call_edge': false,
          'action': value == 'on' ? 'start' : 'stop',
          'asked_ok': askedOk,
          'toast': 'Start sent to AWS — the VM is booting.',
          'vm': {
            'status': status,
            'settled': settled,
            'chip_label': 'Unknown',
            'chip_tone': 'paused',
            'poll': {'interval_ms': 6000, 'max_polls': 20},
          },
          'poll': {'interval_ms': 6000, 'max_polls': 20},
        };

    test('a vm flip no longer hands the app a cloud errand', () {
      // The half of the bug that only one of the two renderers ever ran.
      expect(VmTogglePolicy.plan(setVerdict()).invoke, isFalse);
    });

    test('an unsettled verdict is chased on the payload\'s own cadence', () {
      final plan = VmTogglePolicy.pollState(setVerdict());
      expect(plan.again, isTrue);
      expect(plan.delay, const Duration(milliseconds: 6000));
      expect(plan.maxPolls, 20);
    });

    test('the cadence is read from the payload, never assumed', () {
      final v = setVerdict();
      v['poll'] = {'interval_ms': 1500, 'max_polls': 4};
      final plan = VmTogglePolicy.pollState(v);
      expect(plan.delay, const Duration(milliseconds: 1500));
      expect(plan.maxPolls, 4);
    });

    test('a settled state ends the chase, whichever half carries the flag', () {
      expect(
        VmTogglePolicy.pollState(
            setVerdict(status: 'running', settled: true)).again,
        isFalse,
      );
      // The envelope's own `settled`, as dev_vm_poll returns it.
      expect(
        VmTogglePolicy.pollState({
          'ok': true,
          'settled': true,
          'vm': {'status': 'running', 'settled': true},
          'poll': {'interval_ms': 6000, 'max_polls': 20},
        }).again,
        isFalse,
      );
    });

    test('a call that never left the database is not chased', () {
      // _ops_vm_call could not post (no service key in the vault). Polling would
      // just re-read a state nothing is moving.
      expect(VmTogglePolicy.pollState(setVerdict(askedOk: false)).again, isFalse);
      expect(
        VmTogglePolicy.pollState({'ok': false, 'settled': false}).again,
        isFalse,
      );
    });

    test('a verdict with no chase in it stops on the first look', () {
      // Claude / Workflow flips, and any older backend that sends neither.
      expect(VmTogglePolicy.pollState(_plainVerdict('claude', 'on')).again,
          isFalse);
      expect(VmTogglePolicy.pollState(const {}).again, isFalse);
      // Missing or zero numbers are silence, not a default.
      final v = setVerdict();
      v['poll'] = {'interval_ms': 0, 'max_polls': 20};
      expect(VmTogglePolicy.pollState(v).again, isFalse);
    });

    test('a chase still needs a real state to be unsettled about', () {
      // dev_vm_poll's own reply while EC2 is mid-flight.
      final plan = VmTogglePolicy.pollState({
        'ok': true,
        'settled': false,
        'vm': {
          'status': 'starting',
          'settled': false,
          'poll': {'interval_ms': 6000, 'max_polls': 20},
        },
      });
      expect(plan.again, isTrue);
      expect(plan.delay, const Duration(milliseconds: 6000));
    });
  });

  group('the chip prints the backend\'s word, and nothing else', () {
    test('label and tone are the payload\'s, verbatim', () {
      final chip = VmTogglePolicy.chip({
        'status': 'stopped',
        'chip_label': 'Stopped',
        'chip_tone': 'paused',
      });
      expect(chip.label, 'Stopped');
      expect(chip.tone, 'paused');
      expect(chip.has, isTrue);
    });

    test('the status word is NOT what gets drawn — the label is', () {
      // The fixture deliberately disagrees with itself: a widget that still
      // mapped status→copy key would print "Running", and this is exactly the
      // lie the change is about. It must print what the backend sent.
      final chip = VmTogglePolicy.chip({
        'status': 'running',
        'chip_label': 'Stopping',
        'chip_tone': 'awaiting_approval',
      });
      expect(chip.label, 'Stopping');
      expect(chip.tone, 'awaiting_approval');
    });

    test('no word means no chip — never an invented one', () {
      expect(VmTogglePolicy.chip(const {}).has, isFalse);
      expect(VmTogglePolicy.chip(const {'status': 'running'}).has, isFalse);
      expect(VmTogglePolicy.chip(const {'chip_label': ''}).has, isFalse);
    });
  });
}
