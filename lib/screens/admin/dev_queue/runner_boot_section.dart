import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';

/// CHANGE #530 — Runner boot, on the Cron health screen.
///
/// It sits with the three lanes because it answers the same shape of question
/// they do: is this part of the fleet healthy right now, and if not, what is
/// holding it. A VM stop mid-build used to leave `.git/index.lock`, a
/// half-finished rebase and a row still marked `building`; the next worker
/// booted into that debris and every build after it inherited the damage.
/// `boot_doctor.sh` now runs before any claim, and a RED verdict means that
/// runner refuses to claim at all.
///
/// The widget decides nothing. The title, the subtitle, each verdict sentence,
/// each repair line, every check's label and detail, the counts and the empty
/// state are built by `runner_boot_status()`; tones are backend-chosen names
/// resolved through the shared palette. It renders them in payload order.
class RunnerBootSection extends StatelessWidget {
  final Map<String, dynamic> data;
  const RunnerBootSection({super.key, required this.data});

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

    final runners = (data['runners'] as List?) ?? const [];
    final recent = (data['recent'] as List?) ?? const [];

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
          SizedBox(height: Ds.space.x8),
          Text(
            (data['counts_label'] as String?) ?? '',
            style: Ds.t.caption.copyWith(
              fontWeight: FontWeight.w600,
              color: kTextHi,
            ),
          ),

          // ── the latest boot per runner ─────────────────────────────────
          if (runners.isEmpty) ...[
            SizedBox(height: Ds.space.x16),
            Text(
              (data['empty_label'] as String?) ?? '',
              style: Ds.t.caption.copyWith(color: kTextLo),
            ),
          ] else ...[
            SizedBox(height: Ds.space.x24),
            Text(
              (data['runners_head'] as String?) ?? '',
              style: Ds.t.body.copyWith(
                fontWeight: FontWeight.w600,
                color: kTextHi,
              ),
            ),
            for (final r in runners) ...[
              SizedBox(height: Ds.space.x12),
              _runner((r as Map).cast<String, dynamic>()),
            ],
          ],

          // ── the boot history ───────────────────────────────────────────
          if (recent.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            Text(
              (data['recent_head'] as String?) ?? '',
              style: Ds.t.body.copyWith(
                fontWeight: FontWeight.w600,
                color: kTextHi,
              ),
            ),
            for (final e in recent) ...[
              SizedBox(height: Ds.space.x12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${((e as Map)['at_label'] ?? '')} · ${e['agent'] ?? ''}',
                          style: Ds.t.caption.copyWith(
                            fontWeight: FontWeight.w600,
                            color: kTextHi,
                          ),
                        ),
                        SizedBox(height: Ds.space.x4),
                        Text(
                          '${e['detail'] ?? ''}',
                          style: Ds.t.caption.copyWith(color: kTextLo),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _runner(Map<String, dynamic> r) {
    final checks = (r['checks'] as List?) ?? const [];
    final repairs = (r['repairs'] as List?) ?? const [];
    // Only the FAILED checks are listed. A green boot's nine passing lines are
    // noise on a card whose whole job is "is anything wrong"; the verdict chip
    // already carries the good news.
    final failed = checks
        .whereType<Map>()
        .where((c) => c['ok'] != true)
        .toList(growable: false);

    return Container(
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: kPageBg,
        borderRadius: Ds.r.rButton,
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${r['agent'] ?? ''}',
                  style: Ds.t.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: kTextHi,
                  ),
                ),
              ),
              ToneChip(
                label: (r['verdict_label'] as String?) ?? '',
                tone: toneByName((r['tone'] as String?) ?? 'neutral'),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(
            '${r['at_label'] ?? ''} · ${r['reason_label'] ?? ''} · ${r['timing_label'] ?? ''}',
            style: Ds.t.caption.copyWith(color: kTextLo),
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            '${r['repairs_label'] ?? ''} · ${r['released_label'] ?? ''}',
            style: Ds.t.caption.copyWith(color: kTextLo),
          ),
          for (final rp in repairs) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              '${((rp as Map)['label'] ?? '')} — ${rp['detail'] ?? ''}',
              style: Ds.t.caption.copyWith(color: kTextHi),
            ),
          ],
          if ((r['failed_label'] as String?)?.isNotEmpty ?? false) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              r['failed_label'] as String,
              style: Ds.t.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: Ds.c.danger,
              ),
            ),
          ],
          for (final f in failed) ...[
            SizedBox(height: Ds.space.x4),
            Text(
              '${f['label'] ?? ''} — ${f['detail'] ?? ''}',
              style: Ds.t.caption.copyWith(color: Ds.c.danger),
            ),
          ],
        ],
      ),
    );
  }
}
