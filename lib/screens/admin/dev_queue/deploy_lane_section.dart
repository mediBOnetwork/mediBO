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
    // CHANGE #1823 — the critical-path smoke verdict. has:false draws nothing;
    // the sentence, the tone and the verdict word are merge_batch_smoke_status()'s.
    final smoke = (data['smoke'] as Map?)?.cast<String, dynamic>() ?? const {};
    final queue = (data['queue'] as Map?)?.cast<String, dynamic>() ?? const {};
    final batch = (data['batch'] as Map?)?.cast<String, dynamic>();
    final metrics =
        (data['metrics'] as Map?)?.cast<String, dynamic>() ?? const {};
    final waiting = (queue['rows'] as List?) ?? const [];
    final recent = (data['recent'] as List?) ?? const [];
    // CHANGE #1836 — the recent BATCHES and their real notes. Six batches failed
    // in a row on 6 Sep while this card could only ever show the one that was
    // open, so the hour was legible in merge_worker.journal and nowhere else.
    // has:false draws nothing at all.
    final batches =
        (data['batches'] as Map?)?.cast<String, dynamic>() ?? const {};
    final batchRows = (batches['rows'] as List?) ?? const [];
    final stale = (data['stale'] as List?) ?? const [];
    // CMD #1866 — the WAIT GATE's own decisions. #1863 parked on the deploy
    // lock its own deploy was holding and cold-read its whole context; the only
    // record was four dev_context_event rows you had to infer the mode from.
    // Every string here (title, subtitle, chip, each row's verdict and
    // sentence) is dev_wait_gate_recent()'s. has:false draws nothing at all.
    final gate = (data['gate'] as Map?)?.cast<String, dynamic>() ?? const {};
    final gateRows = (gate['rows'] as List?) ?? const [];

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
          // CMD #1866 — WHOSE deploy holds the lock. "deploy lock — #1863 (own)"
          // and "deploy lock — #1864" are one backend string with one backend
          // tone; ownership is never re-derived here from a holder name.
          if (((lane['lock_label'] as String?) ?? '').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Align(
              alignment: Alignment.centerLeft,
              child: ToneChip(
                label: (lane['lock_label'] as String?) ?? '',
                tone: toneByName((lane['lock_tone'] as String?) ?? 'neutral'),
              ),
            ),
          ],

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

          // ── the critical-path smoke verdict (CHANGE #1823) ─────────────
          // It used to live only in merge_worker.journal, as "could not run
          // (exit 2) — not treated as a failure" on every single batch.
          if (smoke['has'] == true) ...[
            SizedBox(height: Ds.space.x12),
            _row(
              (smoke['label'] as String?) ?? '',
              (smoke['detail'] as String?) ?? '',
              (smoke['verdict'] as String?) ?? '',
              (smoke['tone'] as String?) ?? 'neutral',
            ),
          ],

          // ── the wait gate (CMD #1866) ─────────────────────────────────
          // Which blockers the gate saw, who held them, and what it decided:
          // mine / free / sleep / hold / park-refused / park. A park is the only
          // decision that costs a cold re-read, so it is the only red one.
          if (gate['has'] == true) ...[
            SizedBox(height: Ds.space.x24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    (gate['title'] as String?) ?? '',
                    style: Ds.t.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: kTextHi,
                    ),
                  ),
                ),
                if (((gate['chip'] as String?) ?? '').isNotEmpty) ...[
                  SizedBox(width: Ds.space.x8),
                  ToneChip(
                    label: (gate['chip'] as String?) ?? '',
                    tone: toneByName((gate['chip_tone'] as String?) ?? 'neutral'),
                  ),
                ],
              ],
            ),
            SizedBox(height: Ds.space.x4),
            Text(
              (gate['subtitle'] as String?) ?? '',
              style: Ds.t.caption.copyWith(color: kTextLo),
            ),
            if (((gate['parks_24h_label'] as String?) ?? '').isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(
                (gate['parks_24h_label'] as String?) ?? '',
                style: Ds.t.caption.copyWith(
                  color: toneByName(
                    (gate['parks_24h_tone'] as String?) ?? 'neutral',
                  ).fg,
                ),
              ),
            ],
            for (final g in gateRows) ...[
              SizedBox(height: Ds.space.x12),
              _row(
                ((g as Map)['label'] as String?) ?? '',
                (g['detail'] as String?) ?? '',
                (g['value'] as String?) ?? '',
                (g['tone'] as String?) ?? 'neutral',
              ),
            ],
          ],

          // ── recent batches, and whether they are failing in a row ──────
          // CHANGE #1836. Every string here is deploy_lane_batches()' — the
          // streak sentence, each batch's value word ("worker died — retried"
          // for an expired batch, which is a dead worker and not a verdict) and
          // the note, which is now the error line deploy.sh actually printed
          // rather than its exit code. Nothing is recomputed from `status`.
          if (batches['has'] == true) ...[
            SizedBox(height: Ds.space.x24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    (batches['heading'] as String?) ?? '',
                    style: Ds.t.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: kTextHi,
                    ),
                  ),
                ),
                if (((batches['streak_label'] as String?) ?? '').isNotEmpty)
                  ToneChip(
                    label: (batches['streak_label'] as String?) ?? '',
                    tone: toneByName(
                      (batches['streak_tone'] as String?) ?? 'neutral',
                    ),
                  ),
              ],
            ),
            if (batchRows.isEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(
                (batches['empty_label'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
            ] else
              for (final b in batchRows) ...[
                SizedBox(height: Ds.space.x12),
                _row(
                  ((b as Map)['label'] as String?) ?? '',
                  (b['sub_label'] as String?) ?? '',
                  (b['value_label'] as String?) ?? '',
                  (b['tone'] as String?) ?? 'neutral',
                ),
                if (((b['when_label'] as String?) ?? '').isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(
                    (b['when_label'] as String?) ?? '',
                    style: Ds.t.caption.copyWith(color: kTextLo),
                  ),
                ],
              ],
            if (((batches['footnote'] as String?) ?? '').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(
                (batches['footnote'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
            ],
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
