import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';

/// CHANGE #327 — the Build lane, on the Cron health screen.
///
/// The third lane, and the same failure as the other two in a third resource.
/// The DB lane was heavy queries fighting for one instance; the deploy lane was
/// finished builds fighting for one mutex; this one is builds fighting for one
/// FILE. #325 claimed, loaded its whole context, planned its files and only
/// then discovered #326 was holding home_shell.dart — then sat parked, polling
/// the lease 97 times in six minutes while holding everything it had loaded.
///
/// The collision is decided in SQL now, at add time, before a worker boots:
/// intersecting predictions auto-chain through depends_on and the second
/// command simply stays pending. This card is where Om can see that it worked —
/// what is chained (queued, never parked), what is held, which paths are still
/// fought over, and how much god-file debt is still creating the hot spots.
///
/// The widget decides nothing. Title, subtitle, mode chip, every heading, every
/// row label, every count sentence and every empty hint arrive from
/// `build_contention_status()`; tones are backend-chosen names resolved through
/// the shared palette. Sections render in payload order and an unknown section
/// with no rows falls back to its own hint — a new section needs no deploy.
class BuildLaneSection extends StatelessWidget {
  final Map<String, dynamic> data;
  const BuildLaneSection({super.key, required this.data});

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

          // ── did anything wait on anything? ─────────────────────────────
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
