/// CHANGE #233 — the restart-safety read model.
///
/// Om restarts the VM daily for the 5h limit. Three separate lies used to
/// survive that restart, and all three are decided here, in one pure place, so
/// they can be pinned by a test instead of re-appearing in the next screen:
///
///   1. a worker chip next to a row whose worker is gone,
///   2. a "Live view on" badge with no bridge behind it,
///   3. a worker grid drawn from a pool snapshot that stopped updating.
///
/// Nothing in this file computes a display string. `is_live`, `live_chip`,
/// `steps_chip`, `stall_chip`, `resume_chip`, `remote_display`, `remote_tone`
/// and `stale_display` are all composed by the backend (dev_cmd_list /
/// dev_ctl_get, wording in ui_copy). This class only decides which of them the
/// screen is allowed to show.
library;

/// What kind of restart-safety chip a label is — the screen picks the glyph.
enum SafetyChipKind { offline, agentSilent, stall, stepsStale, steps, resumed }

class SafetyChip {
  final SafetyChipKind kind;
  final String label;
  final String tone;
  const SafetyChip(this.kind, this.label, this.tone);
}

/// One registry row's liveness + checkpoint state.
class RowLiveness {
  final Map<String, dynamic> row;
  const RowLiveness(this.row);

  static String _s(dynamic v) => (v ?? '').toString();

  String get status => _s(row['status']).isEmpty ? 'pending' : _s(row['status']);
  String get claimedBy => _s(row['claimed_by']);

  /// The BACKEND's verdict on the heartbeat behind this row. Absent is false —
  /// an old payload must degrade to "not live", never to "assume live".
  bool get isLive => row['is_live'] == true;

  /// A worker name may only appear while that worker is still breathing.
  bool get showWorker => status == 'building' && claimedBy.isNotEmpty && isLive;

  /// A countdown may only run while the row is live. `has_eta` already carries
  /// the backend's staleness cut; this is the belt to that braces, so a payload
  /// from an older build cannot resurrect the fake clock.
  bool get showCountdown =>
      status == 'building' && row['has_eta'] == true && isLive;

  /// The backend's verdict that the AGENT — not the runner reporting for it —
  /// has gone quiet. Absent is false: a payload from an older build degrades to
  /// "the session is fine", never to a warning Dart invented.
  bool get agentSilent => (row['agent_chip'] ?? '').toString().isNotEmpty;

  /// How many times this build has already lost its Claude session.
  int get sessionLost => (row['session_lost_count'] as num?)?.toInt() ?? 0;

  /// The exact flags the last launch used, as the backend recorded them
  /// ("▶ started: claude-fable-5-1 / extra (remote-control)"). Empty = never
  /// recorded; the detail screen prints it verbatim and never composes one.
  String get startedFlags => (row['started_flags'] ?? '').toString();

  /// The backend's verdict that the checklist has stopped being reported.
  /// Absent is false: an older payload degrades to "trusted", never to a
  /// warning Dart invented.
  bool get stepsStale => (row['steps_stale_chip'] ?? '').toString().isNotEmpty;

  /// One line of guidance, worded by the backend, for the detail screen.
  String get stepsStaleHint => (row['steps_stale_hint'] ?? '').toString();

  int get stepsDone => (row['steps_done'] as num?)?.toInt() ?? 0;
  int get stepsTotal => (row['steps_total'] as num?)?.toInt() ?? 0;
  bool get hasPlan => stepsTotal > 0;

  /// Ordered, worst-news-first: offline, then stalled, then progress, then the
  /// resume count. Empty strings are dropped — the backend omitting a chip is
  /// how it says "not applicable", and Dart never fills that in.
  List<SafetyChip> get chips {
    final out = <SafetyChip>[];
    void add(SafetyChipKind k, String key, String tone) {
      final label = _s(row[key]);
      if (label.isNotEmpty) out.add(SafetyChip(k, label, tone));
    }

    add(SafetyChipKind.offline, 'live_chip', 'error');
    // CHANGE #1023 — sits between "the worker is gone" and "the build stalled",
    // because it is neither. `live_chip` says the heartbeat stopped; this says
    // the heartbeat is fine and the Claude session behind it is not. #1016 sat
    // in exactly that state for 32 minutes with nothing on the card to show it:
    // a bash subshell kept beating for a session that had already dropped. The
    // tone is the backend's (`agent_tone`), so the amber is not a Dart guess.
    add(SafetyChipKind.agentSilent, 'agent_chip',
        _s(row['agent_tone']).isEmpty ? 'warning' : _s(row['agent_tone']));
    add(SafetyChipKind.stall, 'stall_chip', 'warning');
    // CHANGE #350 — sits IMMEDIATELY before the progress chip on purpose: it is
    // the warning that the very next chip cannot be trusted. The backend sets
    // it when tokens climbed while the checklist stood still, and clears it the
    // moment any step is reported, so Dart neither measures it nor guesses it.
    add(SafetyChipKind.stepsStale, 'steps_stale_chip', 'warning');
    add(SafetyChipKind.steps, 'steps_chip', 'info');
    add(SafetyChipKind.resumed, 'resume_chip', 'neutral');
    return out;
  }
}

/// CHANGE #369 — the finish gate, as the card reads it.
///
/// #355 finished its work — 12/12 steps, CHANGE #855 live, QA green — and then
/// kept running for fifteen minutes while its card still said `building`. The
/// gate that ends that lives entirely in the backend: it observes every
/// completion condition, completes the row itself, and interrupts the agent's
/// turn. This class is the card's HALF of that contract, and its whole job is
/// to make one thing impossible — Dart deciding for itself that a build looks
/// finished.
///
/// So there is deliberately no `stepsDone == stepsTotal` here. Readiness is a
/// backend verdict (`finish_ready_at` stamped, rendered as `finish_chip`), and
/// a payload that sends no chip means "not ready" — never "work it out".
class RowFinish {
  final Map<String, dynamic> row;
  const RowFinish(this.row);

  /// The sentence, composed by dev_cmd_list from ui_copy. Empty = no chip.
  String get label => (row['finish_chip'] ?? '').toString();

  /// The tone NAME the backend chose; the screen resolves it via toneByName.
  String get tone => (row['finish_tone'] ?? 'neutral').toString();

  /// Was this row closed by the harness rather than by the model? The backend
  /// stamps it at completion; absent degrades to false.
  bool get autoFinished => row['auto_finished'] == true;

  /// 'harness' (the heartbeat detector) or 'watchdog' (the server-side
  /// backstop) — printed verbatim wherever the source matters.
  String get source => (row['auto_finish_source'] ?? '').toString();

  /// What is still holding the row open, in the backend's own words. Used by
  /// the detail screen; the card only needs [label].
  List<String> get blockers => (row['finish_blockers'] is List)
      ? (row['finish_blockers'] as List).map((e) => e.toString()).toList()
      : const <String>[];

  bool get show => label.isNotEmpty;
}

/// The live-view badge. Honest in BOTH directions: the backend measures whether
/// the bridge is genuinely reachable and sends the label and the tone, so "off"
/// is a visible state rather than a missing chip.
class RemoteBadge {
  final Map<String, dynamic> status;
  const RemoteBadge(this.status);

  String get display => (status['remote_display'] ?? '').toString();
  String get tone => (status['remote_tone'] ?? 'neutral').toString();
  bool get isOn => (status['remote_control'] ?? 'off') == 'on';
  bool get show => display.isNotEmpty;
}

/// CHANGE #237 — the CLAUDE CODE device list, which is a different bridge from
/// [RemoteBadge].
///
/// [RemoteBadge] measures mediBO's OWN live-view bridge (medibo-bridge). It read
/// "On phone" for weeks while Om's Claude Code mobile app listed no devices at
/// all, because nothing on the build VM had ever opened an ANTHROPIC Remote
/// Control session: the GCP box typed `/remote-control` into an interactive TUI,
/// and the headless `claude --print` loop that replaced it never registers.
/// Conflating the two badges is what hid that for so long, so they stay separate
/// classes with separate keys.
///
/// `phone_sessions` is MEASURED on the VM (a live Anthropic bridgeSessionId per
/// worker companion) and every string here is composed by the backend.
class PhoneBadge {
  final Map<String, dynamic> status;
  const PhoneBadge(this.status);

  String get display => (status['phone_display'] ?? '').toString();
  String get tone => (status['phone_tone'] ?? 'neutral').toString();

  /// What to do about it — one line, worded by the backend for BOTH states.
  String get hint => (status['phone_hint'] ?? '').toString();

  int get count => (status['phone_sessions'] as num?)?.toInt() ?? 0;
  bool get isOn => count > 0;

  /// The session names exactly as the phone app lists them. Order is the
  /// backend's; empties are dropped so a partial payload cannot render a blank
  /// row that looks like a session.
  List<String> get names => ((status['phone_names'] as List?) ?? const [])
      .map((e) => (e ?? '').toString())
      .where((e) => e.isNotEmpty)
      .toList();

  bool get show => display.isNotEmpty;
}

/// The worker grid's source of truth.
class PoolLiveness {
  final Map<String, dynamic> state;
  const PoolLiveness(this.state);

  /// The backend already blanks workers/counts/countdowns when the pool's own
  /// heartbeat goes stale. Reading them straight through is therefore correct —
  /// and this list must never be reconstructed from anything else.
  List<Map<String, dynamic>> get workers => ((state['workers'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  int get activeWorkers => (state['active_workers'] as num?)?.toInt() ?? 0;
  String get staleDisplay => (state['stale_display'] ?? '').toString();
  bool get isStale => staleDisplay.isNotEmpty;
}
