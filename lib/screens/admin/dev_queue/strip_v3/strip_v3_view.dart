import 'package:flutter/material.dart';

import '../../../../design_tokens.dart';
import '../dev_queue_common.dart';

/// CHANGE #1367 — the Runner control strip, v3. The PURE renderer.
///
/// v1 and v2 drew what Om had ASKED for. That is not a status, and three
/// capabilities proved it by dying quietly behind a green toggle: usage sync,
/// Remote Control, and the build branch — which reported `enabled: true`,
/// `want: true` and 22 pending commands while its status had been `off` since
/// the day it shipped, because a token read parsed a JSON string as an object
/// and concluded the vault was empty. The card said everything was on. It was
/// on in the only sense the card measured: somebody had switched it on.
///
/// So every toggle here carries TWO booleans — `desired` and `actual` — and the
/// strip's headline is the backend's sentence for the gap between them, or its
/// all-clear. The widget compares nothing and words nothing: `strip_v3_card()`
/// decides what counts as blocked, in what order, and how to say it.
///
/// The one rule worth stating twice, because #1369 broke it and stopped the
/// fleet: a capability that cannot be OBSERVED is never reported as broken.
/// `rc_sessions: null` means "the supervisor has not reported recently" and
/// draws nothing at all — it is not zero.
class StripV3View extends StatelessWidget {
  /// `strip_v3_card()`, verbatim.
  final Map<String, dynamic> data;

  /// Tapping a toggle. The parent calls the backend and re-renders from what it
  /// returns — this widget never assumes a tap succeeded.
  final void Function(String key, bool on)? onToggle;

  /// Tapping a live command chip.
  final void Function(int id)? onOpenCommand;

  final bool busy;

  const StripV3View({
    super.key,
    required this.data,
    this.onToggle,
    this.onOpenCommand,
    this.busy = false,
  });

  static bool shows(Map<String, dynamic>? d) => (d?['has'] ?? false) == true;

  @override
  Widget build(BuildContext context) {
    if (!shows(data)) return const SizedBox.shrink();

    final toggles = (data['toggles'] as List?) ?? const [];
    final blocked = (data['blocked'] as List?) ?? const [];
    final tone = toneByName((data['tone'] ?? 'neutral').toString());
    final drain = (data['drain_label'] ?? '').toString();

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

        // Every gap, in the order the backend ranked them. One line each.
        if (blocked.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          for (final b in blocked)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.error_outline,
                    size: Ds.t.bodySize, color: toneByName('warning').fg),
                SizedBox(width: Ds.space.x8),
                Expanded(
                    child: Text(b.toString(),
                        style: Ds.t.caption
                            .copyWith(color: toneByName('warning').fg))),
              ]),
            ),
        ],

        SizedBox(height: Ds.space.x16),
        for (final t in toggles) _toggle(t as Map),

        SizedBox(height: Ds.space.x12),
        Text((data['building_label'] ?? '').toString(), style: Ds.t.body),
        if ((data['branch_label'] ?? '').toString().isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text((data['branch_label']).toString(), style: Ds.t.caption),
        ],
        if (drain.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          ToneChip(label: drain, tone: toneByName('info')),
        ],
      ]),
    );
  }

  /// One row, two truths. `desired` drives the switch; `actual` is stated
  /// beside it, and the two disagreeing is the whole information content of
  /// this card — so the disagreement is never smoothed over by showing one of
  /// them twice.
  Widget _toggle(Map t) {
    final key = (t['key'] ?? '').toString();
    final desired = (t['desired'] ?? false) == true;
    final actual = (t['actual'] ?? false) == true;
    final sub = (t['sub'] ?? '').toString();
    final mismatch = desired != actual;

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text((t['label'] ?? '').toString(),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
              if (mismatch) ...[
                SizedBox(width: Ds.space.x8),
                ToneChip(
                    label: actual ? 'running' : 'not running',
                    tone: toneByName('warning')),
              ],
            ]),
            if (sub.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(sub, style: Ds.t.caption),
            ],
          ]),
        ),
        Switch(
          value: desired,
          activeThumbColor: kBrand,
          onChanged: busy || onToggle == null
              ? null
              : (v) => onToggle!.call(key, v),
        ),
      ]),
    );
  }
}
