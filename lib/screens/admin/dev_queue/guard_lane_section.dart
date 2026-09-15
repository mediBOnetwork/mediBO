import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';

/// CHANGE #916 — the Regression guard, on the Cron health screen.
///
/// The guard had no surface at all. Its only way to reach Om was to file an
/// urgent "RG red after #N" command, which is why every attempt to make that
/// command rarer felt like hiding something: with no panel, "no command" and
/// "nothing wrong" look identical. Nine of those rows had been filed and most
/// concluded "intentional, already rebaselined".
///
/// #916 gave the watcher a stricter test — a schema-only red must be the SAME
/// red across the whole confirmation window, not three unrelated reds in a row
/// — and this card is the other half of that trade: the verdict, the recent
/// runs in order (the churn is the evidence), what the watcher will do about a
/// red right now, and the guard alerts of the last day.
///
/// The widget decides nothing. Title, subtitle, verdict chip, every heading,
/// every row label, every count sentence, every timestamp and every empty hint
/// arrive from `rg_guard_card()`; tones are backend-chosen names resolved
/// through the shared palette. Sections render in payload order, so a new
/// section needs no deploy.
class GuardLaneSection extends StatelessWidget {
  final Map<String, dynamic> data;
  const GuardLaneSection({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    // ok:false is the backend refusing (not a crash) and it ships its own
    // sentence — render that, never a locally worded one.
    if (data['ok'] != true) {
      final err = (data['error'] as String?) ?? '';
      if (err.isEmpty) return const SizedBox.shrink();
      return DqCard(
        child: Text(err, style: Ds.t.body.copyWith(color: Ds.c.danger)),
      );
    }

    final headline =
        (data['headline'] as Map?)?.cast<String, dynamic>() ?? const {};
    final sections = (data['sections'] as List?) ?? const [];

    return DqCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (data['title'] as String?) ?? '',
                  style: Ds.t.subtitle.copyWith(
                    fontWeight: FontWeight.w700,
                    color: kTextHi,
                  ),
                ),
              ),
              ToneChip(
                label: (data['mode_label'] as String?) ?? '',
                tone: toneByName((data['mode_tone'] as String?) ?? 'neutral'),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(
            (data['subtitle'] as String?) ?? '',
            style: Ds.t.caption.copyWith(color: kTextLo),
          ),

          // ── the one sentence about the newest run ──────────────────────
          SizedBox(height: Ds.space.x16),
          _row(
            (headline['label'] as String?) ?? '',
            (headline['detail'] as String?) ?? '',
            (data['window_label'] as String?) ?? '',
            (headline['tone'] as String?) ?? 'neutral',
          ),

          // ── the sections, in payload order ─────────────────────────────
          for (final s in sections) ...[
            SizedBox(height: Ds.space.x24),
            Text(
              ((s as Map)['heading'] as String?) ?? '',
              style: Ds.t.body.copyWith(
                fontWeight: FontWeight.w600,
                color: kTextHi,
              ),
            ),
            if (((s['rows'] as List?) ?? const []).isEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(
                (s['empty_hint'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
            ] else
              for (final r in (s['rows'] as List)) ...[
                SizedBox(height: Ds.space.x12),
                _row(
                  ((r as Map)['label'] as String?) ?? '',
                  (r['detail'] as String?) ?? '',
                  (r['value_label'] as String?) ?? '',
                  (r['tone'] as String?) ?? 'neutral',
                ),
              ],
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String detail, String value, String tone) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Ds.t.body.copyWith(
                fontWeight: FontWeight.w600,
                color: kTextHi,
              ),
            ),
            if (detail.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(detail, style: Ds.t.caption.copyWith(color: kTextLo)),
            ],
          ],
        ),
      ),
      SizedBox(width: Ds.space.x8),
      if (value.isNotEmpty) ToneChip(label: value, tone: toneByName(tone)),
    ],
  );
}
