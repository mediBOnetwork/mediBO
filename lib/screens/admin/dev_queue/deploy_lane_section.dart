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

  /// CMD #1961 — a Recently completed row opens that command. The screen owns
  /// the navigation; this widget only hands back the id the backend sent.
  final void Function(int commandId)? onOpenCommand;
  const DeployLaneSection({super.key, required this.data, this.onOpenCommand});

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
    // CMD #1961 — RECENTLY COMPLETED, where Recent batches used to be. The
    // batch table stopped moving on 7 Sep when #1859 turned the merge lane off,
    // so the card reported a six-day-old "Last batch failed" as the state of a
    // lane that had deployed all week. Every string here (heading, each row's
    // label, its CHANGE #/duration/tokens line, the empty state and the
    // footnote) is deploy_recent_completed()'s. has:false draws nothing.
    final completed =
        (data['completed'] as Map?)?.cast<String, dynamic>() ?? const {};
    final completedRows = (completed['rows'] as List?) ?? const [];
    final stale = (data['stale'] as List?) ?? const [];
    // CMD #1866 — the WAIT GATE's own decisions. #1863 parked on the deploy
    // lock its own deploy was holding and cold-read its whole context; the only
    // record was four dev_context_event rows you had to infer the mode from.
    // Every string here (title, subtitle, chip, each row's verdict and
    // sentence) is dev_wait_gate_recent()'s. has:false draws nothing at all.
    final gate = (data['gate'] as Map?)?.cast<String, dynamic>() ?? const {};
    final gateRows = (gate['rows'] as List?) ?? const [];
    // CMD #1973 — DIRECT DEPLOYS, and where each one's time went. The key has
    // been on this payload since #1859 but as a bare array with no strings to
    // draw, so nothing rendered it and a 21-minute lock hold was invisible in
    // the app — the only place it showed was direct_deploy.journal, on the box.
    // deploy_direct_panel() now ships the heading, the sentence, each row's
    // line and the two chips (prep off the lock, lock held) already judged.
    // A backend still on the #1859 shape sends a bare ARRAY here. That is not
    // a crash to inherit: an unrecognised shape draws nothing.
    final direct = data['direct'] is Map
        ? (data['direct'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final directRows = (direct['rows'] as List?) ?? const [];

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
          // CMD #1961 — and the LIVE holder chip beside it: "#1962 · runner-2 ·
          // 9m 25s · frees in ~15m 35s" when the lock is held, "Lock free" when
          // it is not. One backend string, one backend tone; the chips wrap on a
          // narrow phone instead of overflowing the row.
          if (((lane['lock_label'] as String?) ?? '').isNotEmpty ||
              ((lane['holder_chip'] as String?) ?? '').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                if (((lane['lock_label'] as String?) ?? '').isNotEmpty)
                  ToneChip(
                    label: (lane['lock_label'] as String?) ?? '',
                    tone: toneByName(
                      (lane['lock_tone'] as String?) ?? 'neutral',
                    ),
                  ),
                if (((lane['holder_chip'] as String?) ?? '').isNotEmpty)
                  ToneChip(
                    label: (lane['holder_chip'] as String?) ?? '',
                    tone: toneByName(
                      (lane['holder_chip_tone'] as String?) ?? 'neutral',
                    ),
                  ),
              ],
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

          // ── direct deploys: prep off the lock vs the lock itself ───────
          if (direct['has'] == true) ...[
            SizedBox(height: Ds.space.x24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    (direct['heading'] as String?) ?? '',
                    style: Ds.t.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: kTextHi,
                    ),
                  ),
                ),
                if (((direct['target_label'] as String?) ?? '').isNotEmpty) ...[
                  SizedBox(width: Ds.space.x8),
                  ToneChip(
                    label: (direct['target_label'] as String?) ?? '',
                    tone: toneByName('neutral'),
                  ),
                ],
              ],
            ),
            SizedBox(height: Ds.space.x4),
            Text(
              (direct['subtitle'] as String?) ?? '',
              style: Ds.t.caption.copyWith(color: kTextLo),
            ),
            if (directRows.isEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(
                (direct['empty'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
            ] else
              for (final d in directRows.whereType<Map>()) ...[
                SizedBox(height: Ds.space.x12),
                _DirectRow(
                  row: d.cast<String, dynamic>(),
                  onOpen: onOpenCommand,
                ),
              ],
            if (((direct['footnote'] as String?) ?? '').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(
                (direct['footnote'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
            ],
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

          // ── what finished, and what it cost ────────────────────────────
          // CMD #1961. One compact row per completed command: #id · title,
          // then CHANGE #n · duration · tokens as the backend worded it.
          // Tapping a row opens that command.
          if (completed['has'] == true) ...[
            SizedBox(height: Ds.space.x24),
            Text(
              (completed['heading'] as String?) ?? '',
              style: Ds.t.body.copyWith(
                fontWeight: FontWeight.w600,
                color: kTextHi,
              ),
            ),
            if (completedRows.isEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(
                (completed['empty_label'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
            ] else
              for (final r in completedRows.whereType<Map>()) ...[
                SizedBox(height: Ds.space.x12),
                _CompletedRow(
                  row: r.cast<String, dynamic>(),
                  onOpen: onOpenCommand,
                ),
              ],
            if (((completed['footnote'] as String?) ?? '').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(
                (completed['footnote'] as String?) ?? '',
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

/// One Recently completed row: #id · title on one line, then the backend's
/// CHANGE #n · duration · tokens line, with the change chip on the right.
/// It computes nothing — not the duration, not the token figure, not the chip
/// word — and the whole row is one ≥44px tap target onto that command.
class _CompletedRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final void Function(int commandId)? onOpen;
  const _CompletedRow({required this.row, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final id = row['command_id'];
    final label = (row['label'] as String?) ?? '';
    final sub = (row['sub_label'] as String?) ?? '';
    final when = (row['when_label'] as String?) ?? '';
    final value = (row['value_label'] as String?) ?? '';
    final tone = toneByName((row['tone'] as String?) ?? 'neutral');
    final body = ConstrainedBox(
      constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: Ds.t.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: kTextHi,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (sub.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(
                    sub,
                    style: Ds.t.caption.copyWith(color: kTextLo),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (when.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(
                    when,
                    style: Ds.t.caption.copyWith(color: kTextLo),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: Ds.space.x8),
          if (value.isNotEmpty) ToneChip(label: value, tone: tone),
        ],
      ),
    );
    if (onOpen == null || id is! int) return body;
    return InkWell(
      onTap: () => onOpen!(id),
      borderRadius: Ds.r.rCard,
      child: body,
    );
  }
}

/// CMD #1973 — one direct deploy, with the two numbers that matter kept apart:
/// how long its prep ran with the deploy lock FREE, and how long it actually
/// held the lock. Before this command both were one 21-minute lump and only the
/// second one blocks every other runner.
///
/// The widget judges nothing. The label, the phase line, both chip captions and
/// the hold tone (success under 5 min, warning under 10, danger above) are
/// deploy_direct_recent()'s. The chips WRAP rather than overflow, because a
/// 360px phone is the viewport this is read on.
class _DirectRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final void Function(int commandId)? onOpen;
  const _DirectRow({required this.row, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final id = row['command_id'];
    final label = (row['label'] as String?) ?? '';
    final line = (row['line'] as String?) ?? '';
    final prep = (row['prep_label'] as String?) ?? '';
    final hold = (row['hold_label'] as String?) ?? '';
    final rebuilt = (row['rebuilt_label'] as String?) ?? '';
    // CMD #1991 — WHERE THIS DEPLOY'S TIME WENT. "test 1m 24s · build 3m 41s ·
    // upload 29s · cache kept" is one string built by
    // _deploy_direct_phases_label(); the tone beside it is the backend's own
    // verdict against the build+upload target, never a threshold compared here.
    // A deploy from before the phases were measured sends '' and draws nothing.
    final phases = (row['phases_label'] as String?) ?? '';
    final body = ConstrainedBox(
      constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Ds.t.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: kTextHi,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(width: Ds.space.x8),
              if (hold.isNotEmpty)
                ToneChip(
                  label: hold,
                  tone: toneByName((row['hold_tone'] as String?) ?? 'neutral'),
                ),
            ],
          ),
          if (line.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(line, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
          if (prep.isNotEmpty || rebuilt.isNotEmpty || phases.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                if (phases.isNotEmpty)
                  ToneChip(
                    label: phases,
                    tone: toneByName(
                      (row['phases_tone'] as String?) ?? 'neutral',
                    ),
                  ),
                if (prep.isNotEmpty)
                  ToneChip(label: prep, tone: toneByName('success')),
                if (rebuilt.isNotEmpty)
                  ToneChip(label: rebuilt, tone: toneByName('warning')),
              ],
            ),
          ],
        ],
      ),
    );
    if (onOpen == null || id is! int) return body;
    return InkWell(
      onTap: () => onOpen!(id),
      borderRadius: Ds.r.rCard,
      child: body,
    );
  }
}
