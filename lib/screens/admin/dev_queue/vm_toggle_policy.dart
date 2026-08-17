// The VM toggle's decisions, extracted from the widget so they can be pinned by
// test/protected/vm_power_toggle_test.dart.
//
// CHANGE #224 — the VM moved from GCP to AWS EC2 and the toggle was found to be
// doing nothing at all: `dev_ctl_set` never returned `call_edge`, so the branch
// that invokes the vm-control edge function was dead code. The lesson is that
// this handful of branches is load-bearing and invisible, so it lives here as a
// pure class with no Flutter dependency.
//
// The rule these types enforce: the app decides NOTHING about the VM. Whether to
// call the cloud, which action to send, and every word shown afterwards all come
// out of a backend payload. Dart only routes them.

/// What to do after `dev_ctl_set` has answered a toggle flip.
class VmTogglePlan {
  /// Invoke the vm-control edge function?
  final bool invoke;

  /// The action to send — taken from the backend verdict, never derived here.
  final String action;

  /// A `ui_copy` key to toast instead of calling the cloud (the flip asked for
  /// the state the VM is already in). Null when there is nothing to say.
  final String? toastCopyKey;

  const VmTogglePlan({
    required this.invoke,
    this.action = 'status',
    this.toastCopyKey,
  });

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

class VmTogglePolicy {
  const VmTogglePolicy._();

  /// [verdict] is the `dev_ctl_set` payload; [currentStatus] is the backend's
  /// last known `vm_status.status`; [on] is the position the switch moved to.
  ///
  /// Only a verdict that says `call_edge: true` touches the cloud — a Claude or
  /// Workflow flip returns [VmTogglePlan.none] and never reaches EC2.
  static VmTogglePlan plan({
    required Map<String, dynamic> verdict,
    required bool on,
    required String currentStatus,
  }) {
    if (verdict['call_edge'] != true) return VmTogglePlan.none;

    // Already where the flip wants it → say so, don't spend a cloud call.
    if ((on && currentStatus == 'running') ||
        (!on && currentStatus == 'stopped')) {
      return VmTogglePlan(
        invoke: false,
        toastCopyKey:
            on ? 'dev_queue.ctl_vm_on_toast' : 'dev_queue.ctl_vm_off_toast',
      );
    }

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
}
