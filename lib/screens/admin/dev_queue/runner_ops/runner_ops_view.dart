import 'package:flutter/material.dart';

import '../../../../design_tokens.dart';
import '../dev_queue_common.dart';

/// CHANGE #1368 — the Runner policies card. The PURE renderer.
///
/// #1367 taught the strip to say whether the fleet IS running. This says
/// whether it SHOULD be, right now, and which policy is holding it if not.
///
/// Eight rows, every one of them printed: the label, the one-line explanation,
/// the state sentence and the state's tone all arrive from `runner_ops_card()`.
/// The widget decides nothing — not the wording of "Draining — 2 still
/// building", not whether pacing is ahead of budget, not the ON/OFF words, not
/// even the plural in "went red 2 times". If a policy's meaning changes, that
/// is an UPDATE to `ui_copy` and `worker_pool.ops`, never a deploy of this file.
///
/// The switch is bound to `on` (what the policy is set to) and is offered only
/// where the backend said `can_toggle`; a row that carries an `action` gets a
/// button instead, because Boost and "run the drill now" are events, not states.
class RunnerOpsView extends StatelessWidget {
  /// `runner_ops_card()`, verbatim.
  final Map<String, dynamic> data;

  /// Flipping a policy. The parent calls the backend and re-renders from what
  /// comes back — this widget never paints a tap as if it had succeeded.
  final void Function(String key, bool on)? onToggle;

  /// Pressing a row's one-shot action (`boost`, `drill_now`).
  final void Function(String key)? onAction;

  final bool busy;

  const RunnerOpsView({
    super.key,
    required this.data,
    this.onToggle,
    this.onAction,
    this.busy = false,
  });

  static bool shows(Map<String, dynamic>? d) => (d?['has'] ?? false) == true;

  @override
  Widget build(BuildContext context) {
    if (!shows(data)) return const SizedBox.shrink();

    final policies = (data['policies'] as List?) ?? const [];
    final tone = toneByName((data['tone'] ?? 'neutral').toString());
    final workers = (data['workers_label'] ?? '').toString();

    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text((data['title'] ?? '').toString(),
                style: Ds.t.subtitle
                    .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
          ),
          ToneChip(label: (data['headline'] ?? '').toString(), tone: tone),
        ]),
        if (workers.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(workers, style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x16),
        for (final p in policies) _row(p as Map),
      ]),
    );
  }

  Widget _row(Map p) {
    final key = (p['key'] ?? '').toString();
    final on = (p['on'] ?? false) == true;
    final canToggle = (p['can_toggle'] ?? false) == true;
    final action = (p['action'] ?? '').toString();
    final sub = (p['sub'] ?? '').toString();
    final state = (p['state_label'] ?? '').toString();

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((p['label'] ?? '').toString(),
                style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
            if (sub.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(sub, style: Ds.t.caption),
            ],
            if (state.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              ToneChip(
                  label: state,
                  tone: toneByName((p['state_tone'] ?? 'neutral').toString())),
            ],
          ]),
        ),
        SizedBox(width: Ds.space.x12),
        // A row may carry a state AND a one-shot: the nightly drill is both a
        // policy you can switch off and something you can run right now. So
        // both controls are drawn when both are sent, rather than one of them
        // silently winning — which is how "Run it now" would never appear.
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (canToggle)
            Switch(
              value: on,
              activeThumbColor: kBrand,
              onChanged: busy || onToggle == null
                  ? null
                  : (v) => onToggle!.call(key, v),
            ),
          if (action.isNotEmpty && _actionLabel(key).isNotEmpty)
            _actionButton(key, action),
        ]),
      ]),
    );
  }

  Widget _actionButton(String key, String action) => OutlinedButton(
        onPressed:
            busy || onAction == null ? null : () => onAction!.call(action),
        style: OutlinedButton.styleFrom(
          foregroundColor: kBrand,
          side: BorderSide(color: kBrand),
          minimumSize: Size(Ds.space.x48 * 2, Ds.space.x48),
        ),
        child: Text((_actionLabel(key)).toString(), style: Ds.t.caption),
      );

  /// A one-shot needs a verb, and the verb is the backend's too: it rides on
  /// the policy row as `action_label`. The fallback is the EMPTY STRING, not a
  /// Dart word — and the caller above draws no button at all for an empty
  /// label, so a missing backend string shows up as a missing button rather
  /// than as an English literal quietly living in the widget tree.
  String _actionLabel(String key) {
    for (final p in ((data['policies'] as List?) ?? const [])) {
      if (p is Map && (p['key'] ?? '').toString() == key) {
        return (p['action_label'] ?? '').toString();
      }
    }
    return '';
  }
}
