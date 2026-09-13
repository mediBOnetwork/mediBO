// The VM toggle's decisions, extracted from the widget so they can be pinned by
// test/protected/vm_power_toggle_test.dart.
//
// CHANGE #224 — the VM moved from GCP to AWS EC2 and the toggle was found to be
// doing nothing at all: `dev_ctl_set` never returned `call_edge`, so the branch
// that invokes the vm-control edge function was dead code. The lesson is that
// this handful of branches is load-bearing and invisible, so it lives here as a
// pure class with no Flutter dependency.
//
// CHANGE #224 FOLLOW-UP — "start is not working, only stop works". The second
// half of the same bug, and the reason this file shrank:
//
//   `plan()` used to skip the cloud call when the LAST KNOWN status already
//   matched the flip ("VM already running"). That status came from the cached
//   `vm_status` config row — and the only thing that refreshes it while the box
//   is off is a timer running ON the box. So once the VM stopped with a stale
//   'running' in the cache, every future START was answered with a cheerful
//   "VM already running" toast and no EC2 call at all. The app could strand its
//   own builder and then insist it was fine.
//
//   The no-op check now lives in vm-control, which answers it from a
//   DescribeInstances read taken microseconds earlier. Dart no longer holds an
//   opinion about VM state — it cannot hold a stale one.
//
// CMD #1864 — the third instance of the same bug, and the one that moved the
// cloud call out of the app for good.
//
//   The Runners strip (strip_v3_card) flips a toggle with `dev_ctl_set` and
//   never read `call_edge` at all, so START moved the switch and asked AWS
//   nothing. STOP looked like it worked only because it needs no cloud call:
//   the supervisor on the box sees desired_state.vm='off' and powers itself
//   down. Two renderers, one errand, and only one of them ran it.
//
//   Worse, the errand wrote its answer into the wrong database. vm-control
//   writes vm_status with a service client for its OWN project, and the copy
//   that holds a working AWS key is PRODUCTION's — while the chip reads the
//   CONTROL PLANE. So even the card that did make the call never saw the state
//   come back, and the chip sat on the last word the box itself had written
//   before it powered off: "running", for ever.
//
//   `dev_ctl_set('vm', …)` now makes the call server-side and answers
//   `call_edge:false`; [pollState] chases `dev_vm_poll` on the cadence the
//   payload names until the BACKEND says settled. [chip] is the last piece:
//   Dart no longer owns a status→label map either.
//
// The rule these types enforce: the app decides NOTHING about the VM. Whether to
// call the cloud, which action to send, when to look again, and every word shown
// afterwards all come out of a backend payload. Dart only routes them.

/// What to do after `dev_ctl_set` has answered a toggle flip.
class VmTogglePlan {
  /// Invoke the vm-control edge function?
  final bool invoke;

  /// The action to send — taken from the backend verdict, never derived here.
  final String action;

  const VmTogglePlan({required this.invoke, this.action = 'status'});

  static const none = VmTogglePlan(invoke: false);
}

/// What to show after the vm-control edge function has answered.
class VmToggleOutcome {
  /// The backend's own wording, printed verbatim. Empty when it sent none.
  final String message;

  /// True when the call was refused or failed — e.g. no AWS access key saved,
  /// or EC2 rejected the request. The wording is still the backend's.
  final bool isError;

  const VmToggleOutcome({required this.message, required this.isError});

  /// Nothing to toast: the backend succeeded quietly and said nothing.
  bool get isSilent => message.isEmpty && !isError;

  /// The backend failed without wording it — the only case where the caller may
  /// fall back to its own `ui_copy` key.
  bool get needsFallbackCopy => message.isEmpty && isError;
}

/// Whether to look at EC2 again, and how long to wait first.
///
/// `pending` and `stopping` are real EC2 states that take tens of seconds to
/// resolve. Showing one and stopping there is exactly the "guessed label" Om
/// rejected, so the client keeps asking until the BACKEND says `settled`.
class VmPollPlan {
  final bool again;
  final Duration delay;

  /// Hard ceiling on how many times the caller may re-ask, from the payload.
  /// A VM that never settles must not become an infinite poll loop.
  final int maxPolls;

  const VmPollPlan({
    required this.again,
    this.delay = Duration.zero,
    this.maxPolls = 0,
  });

  static const stop = VmPollPlan(again: false);
}

class VmTogglePolicy {
  const VmTogglePolicy._();

  /// [verdict] is the `dev_ctl_set` payload.
  ///
  /// Only a verdict that says `call_edge: true` touches the cloud — a Claude or
  /// Workflow flip returns [VmTogglePlan.none] and never reaches EC2.
  ///
  /// Note what is NOT here: any comparison against a known VM state. The edge
  /// function reads the live state itself and words its own "already running" /
  /// "already stopped" reply, so a cached value can never swallow a real flip.
  static VmTogglePlan plan(Map<String, dynamic> verdict) {
    if (verdict['call_edge'] != true) return VmTogglePlan.none;
    return VmTogglePlan(
      invoke: true,
      // The backend named the action. If it somehow sent none, read state
      // instead of guessing a power operation.
      action: (verdict['action'] ?? 'status').toString(),
    );
  }

  /// [reply] is what `vmControl` handed back (its `ok` flag plus whatever the
  /// edge function returned). The message is passed through untouched.
  static VmToggleOutcome outcome(Map<String, dynamic> reply) => VmToggleOutcome(
        message: (reply['message'] ?? '').toString(),
        isError: reply['ok'] != true,
      );

  /// Read [reply] for whether EC2 is still moving.
  ///
  /// A failed call never schedules a poll: if the key is missing or IAM refused,
  /// asking again just repeats the refusal. A reply that omitted `settled`
  /// (an older function version, or the GCP branch) is treated as settled —
  /// silence must not start a loop.
  static VmPollPlan poll(Map<String, dynamic> reply) {
    if (reply['ok'] != true) return VmPollPlan.stop;
    if (reply['settled'] != false) return VmPollPlan.stop;
    final ms = (reply['poll_after_ms'] as num?)?.toInt() ?? 0;
    final max = (reply['poll_max'] as num?)?.toInt() ?? 0;
    if (ms <= 0 || max <= 0) return VmPollPlan.stop;
    return VmPollPlan(
      again: true,
      delay: Duration(milliseconds: ms),
      maxPolls: max,
    );
  }

  /// Does the chip's cached reading need a live EC2 read before it is shown?
  ///
  /// The verdict is the BACKEND's (`dev_ctl_get().vm.needs_live_check`), which
  /// weighs the reading's age against a different threshold for settled and
  /// transitional states. Dart must not re-derive it from a timestamp — that is
  /// how the cache became authoritative in the first place.
  static bool needsLiveCheck(Map<String, dynamic> vm) =>
      vm['needs_live_check'] == true;

  /// Whether to keep polling `dev_vm_poll`, read from a `dev_ctl_set` or
  /// `dev_vm_poll` payload.
  ///
  /// The stop conditions are all the backend's words: `asked_ok:false` (the
  /// call never left the database, so asking again just repeats the failure)
  /// and `settled` (EC2 is at rest). `settled` is read from the envelope first
  /// and from the vm block second, because both carry it and a caller should
  /// not have to know which one it was handed.
  static VmPollPlan pollState(Map<String, dynamic> reply) {
    if (reply['ok'] == false || reply['asked_ok'] == false) {
      return VmPollPlan.stop;
    }
    final vm = (reply['vm'] as Map?)?.cast<String, dynamic>() ?? const {};
    if ((reply['settled'] ?? vm['settled']) != false) return VmPollPlan.stop;
    final p = (reply['poll'] as Map?)?.cast<String, dynamic>() ??
        (vm['poll'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final ms = (p['interval_ms'] as num?)?.toInt() ?? 0;
    final max = (p['max_polls'] as num?)?.toInt() ?? 0;
    if (ms <= 0 || max <= 0) return VmPollPlan.stop;
    return VmPollPlan(
      again: true,
      delay: Duration(milliseconds: ms),
      maxPolls: max,
    );
  }

  /// The chip beside "VM": the live EC2 word and its tone, both composed in the
  /// backend from `vm_status` and `ui_copy`.
  ///
  /// This used to be a `const map` from status to a ui_copy key and a tone —
  /// which is a display decision, and the toggle position was the only thing
  /// keeping it company. An empty label means the payload sent none, and the
  /// caller draws nothing rather than inventing a word for the gap.
  static VmChip chip(Map<String, dynamic> vm) => VmChip(
        label: (vm['chip_label'] ?? '').toString(),
        tone: (vm['chip_tone'] ?? '').toString(),
      );
}

/// The VM chip's two backend strings. Nothing here is derived.
class VmChip {
  final String label;
  final String tone;

  const VmChip({required this.label, required this.tone});

  /// False when the payload carried no word — draw nothing.
  bool get has => label.isNotEmpty;
}
