import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';

/// CHANGE #324 — the Deploy lane, on the Cron health screen.
///
/// It sits beside the Database lane because it is the same failure in a
/// different resource: work that could run in parallel forced into a single
/// file. The lane used to be a mutex held across test + build + deploy +
/// verify, and each command claimed it two or three times, so five runners
/// generated fifteen queue slots and a 20-minute build took over an hour.
/// It is a merge queue now — runners push a branch and leave, one worker
/// batches, tests once and deploys once — and this is where Om can see whether
/// time is going to queueing or to building.
///
/// The widget decides nothing. Title, subtitle, mode, every row label, every
/// duration string, the empty states and the metric sentences are built by
/// `deploy_lane_status()`; tones are backend-chosen names resolved through the
/// shared palette. It renders them in payload order.
class DeployLaneSection extends StatelessWidget {
  final Map<String, dynamic> data;
  const DeployLaneSection({super.key, required this.data});

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

    final lane = (data['lane'] as Map?)?.cast<String, dynamic>() ?? const {};
    final queue = (data['queue'] as Map?)?.cast<String, dynamic>() ?? const {};
    final batch = (data['batch'] as Map?)?.cast<String, dynamic>();
    final metrics =
        (data['metrics'] as Map?)?.cast<String, dynamic>() ?? const {};
    final waiting = (queue['rows'] as List?) ?? const [];
    final recent = (data['recent'] as List?) ?? const [];
    final stale = (data['stale'] as List?) ?? const [];

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

          // ── the lane itself ────────────────────────────────────────────
          SizedBox(height: Ds.space.x16),
          _row(
            (lane['label'] as String?) ?? '',
            (lane['detail'] as String?) ?? '',
            (lane['held_label'] as String?) ?? '',
            (lane['tone'] as String?) ?? 'neutral',
          ),
          // CHANGE #1822 — the RENEWAL line. The lane is held by liveness now
          // (a ticker renews a 2-minute TTL while the worker deploys), and a
          // lane that is quietly expiring must be readable here instead of
          // inferred from a wall of failed batches. Sentence, chip and tone
          // are deploy_lane_status()'s; nothing about hold time or renewals
          // is ever re-derived in Dart.
          if (((lane['renewal_label'] as String?) ?? '').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    (lane['renewal_label'] as String?) ?? '',
                    style: Ds.t.caption.copyWith(color: kTextLo),
                  ),
                ),
                if (((lane['renewal_chip'] as String?) ?? '').isNotEmpty) ...[
                  SizedBox(width: Ds.space.x8),
                  ToneChip(
                    label: (lane['renewal_chip'] as String?) ?? '',
                    tone: toneByName(
                      (lane['renewal_tone'] as String?) ?? 'neutral',
                    ),
                  ),
                ],
              ],
            ),
          ],

          // ── what is waiting ────────────────────────────────────────────
          SizedBox(height: Ds.space.x24),
          Text(
            (queue['label'] as String?) ?? '',
            style: Ds.t.body.copyWith(
              fontWeight: FontWeight.w600,
              color: kTextHi,
            ),
          ),
          // CHANGE #1674 — the batch WINDOW. A lane that is deliberately
          // waiting for a second branch reads as a stall unless it says so,
          // and the sentence is deploy_lane_status()'s, never Dart's.
          if (((queue['window_label'] as String?) ?? '').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(
              (queue['window_label'] as String?) ?? '',
              style: Ds.t.caption.copyWith(color: kTextLo),
            ),
          ],
          if (waiting.isEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(
              (queue['empty_hint'] as String?) ?? '',
              style: Ds.t.caption.copyWith(color: kTextLo),
            ),
          ] else
            for (final w in waiting) ...[
              SizedBox(height: Ds.space.x12),
              _row(
                ((w as Map)['label'] as String?) ?? '',
                (w['detail'] as String?) ?? '',
                (w['value_label'] as String?) ?? '',
                (w['tone'] as String?) ?? 'neutral',
              ),
            ],

          // ── the batch in flight, when there is one ─────────────────────
          if (batch != null) ...[
            SizedBox(height: Ds.space.x16),
            _row(
              (batch['label'] as String?) ?? '',
              ((batch['slowest_label'] as String?) ?? '') == '—'
                  ? ''
                  : (batch['slowest_label'] as String?) ?? '',
              (batch['value_label'] as String?) ?? '',
              (batch['tone'] as String?) ?? 'neutral',
            ),
            // CHANGE #1822 — how many times THIS batch renewed the lane, as
            // the backend worded it; an empty string draws nothing.
            if (((batch['renewal_label'] as String?) ?? '').isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(
                (batch['renewal_label'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
            ],
            // CHANGE #1674 — per-phase timings. "held 891s" never said WHICH
            // half; each phase names its own seconds and whether the lane was
            // held for it, and the backend already wrote both into the label.
            for (final ph in (batch['phases'] as List?) ?? const []) ...[
              SizedBox(height: Ds.space.x8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      ((ph as Map)['label'] as String?) ?? '',
                      style: Ds.t.caption.copyWith(color: kTextLo),
                    ),
                  ),
                  ToneChip(
                    label: ((ph)['phase'] as String?) ?? '',
                    tone: toneByName((ph['tone'] as String?) ?? 'neutral'),
                  ),
                ],
              ),
            ],
          ],

          // ── wait vs hold: is the fleet queueing or building? ───────────
          SizedBox(height: Ds.space.x24),
          Row(
            children: [
              Expanded(
                child: Text(
                  (metrics['heading'] as String?) ?? '',
                  style: Ds.t.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: kTextHi,
                  ),
                ),
              ),
              ToneChip(
                label: (metrics['target_label'] as String?) ?? '',
                tone: toneByName((metrics['tone'] as String?) ?? 'neutral'),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(
            (metrics['avg_hold_label'] as String?) ?? '',
            style: Ds.t.body.copyWith(color: kTextHi),
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            (metrics['avg_wait_label'] as String?) ?? '',
            style: Ds.t.caption.copyWith(color: kTextLo),
          ),

          // ── a claim still holding a slot past its TTL ──────────────────
          SizedBox(height: Ds.space.x24),
          Text(
            (data['stale_heading'] as String?) ?? '',
            style: Ds.t.body.copyWith(
              fontWeight: FontWeight.w600,
              color: kTextHi,
            ),
          ),
          if (stale.isEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(
              (data['stale_empty'] as String?) ?? '',
              style: Ds.t.caption.copyWith(color: kTextLo),
            ),
          ] else
            for (final s in stale) ...[
              SizedBox(height: Ds.space.x12),
              _row(
                ((s as Map)['label'] as String?) ?? '',
                (s['detail'] as String?) ?? '',
                (s['value_label'] as String?) ?? '',
                (s['tone'] as String?) ?? 'warning',
              ),
            ],

          // ── the measured history ───────────────────────────────────────
          SizedBox(height: Ds.space.x24),
          Text(
            (data['recent_heading'] as String?) ?? '',
            style: Ds.t.body.copyWith(
              fontWeight: FontWeight.w600,
              color: kTextHi,
            ),
          ),
          for (final r in recent) ...[
            SizedBox(height: Ds.space.x12),
            _row(
              ((r as Map)['label'] as String?) ?? '',
              (r['detail'] as String?) ?? '',
              (r['value_label'] as String?) ?? '',
              (r['tone'] as String?) ?? 'neutral',
            ),
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
