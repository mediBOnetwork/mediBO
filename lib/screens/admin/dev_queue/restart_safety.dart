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
enum SafetyChipKind { offline, stall, steps, resumed }

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
    add(SafetyChipKind.stall, 'stall_chip', 'warning');
    add(SafetyChipKind.steps, 'steps_chip', 'info');
    add(SafetyChipKind.resumed, 'resume_chip', 'neutral');
    return out;
  }
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
