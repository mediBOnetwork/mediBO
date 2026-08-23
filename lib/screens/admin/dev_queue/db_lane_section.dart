import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';

/// CHANGE #301 — the Database lane, on the Cron health screen.
///
/// The 1 GB instance stalled ~10 times in a week — 40 statement timeouts, cron
/// reporting "job startup timeout", trivial SETs taking 15 s — every time
/// several agents ran heavy database work in the same moment. `db_work_lock`
/// serialises exactly those steps and nothing else; this is where Om can see
/// it working.
///
/// The widget decides nothing. Headline, every stat, every lane caption, the
/// empty state, the guardrail sentence, the night window and each alert line
/// are strings built by `db_health_status()`; tones are backend-chosen names
/// resolved through the shared palette. It renders them in payload order.
class DbLaneSection extends StatelessWidget {
  final Map<String, dynamic> data;
  const DbLaneSection({super.key, required this.data});

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

    final stats = (data['stats'] as List?) ?? const [];
    final lanes = (data['lanes'] as List?) ?? const [];
    final held = (data['held'] as List?) ?? const [];
    final guard = (data['guard'] as Map?)?.cast<String, dynamic>() ?? const {};
    final window =
        (data['window'] as Map?)?.cast<String, dynamic>() ?? const {};
    final alerts =
        (data['alerts'] as Map?)?.cast<String, dynamic>() ?? const {};
    final recent = (alerts['recent'] as List?) ?? const [];

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
                label: (data['sampled_label'] as String?) ?? '',
                tone: toneByName((data['tone'] as String?) ?? 'neutral'),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(
            (data['headline'] as String?) ?? '',
            style: Ds.t.body.copyWith(color: kTextHi),
          ),
          if (stats.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                for (final s in stats)
                  _stat(
                    ((s as Map)['label'] as String?) ?? '',
                    '${s['value'] ?? ''}',
                  ),
              ],
            ),
          ],
          for (final l in lanes) ...[
            SizedBox(height: Ds.space.x16),
            _laneRow((l as Map).cast<String, dynamic>()),
          ],
          SizedBox(height: Ds.space.x16),
          if (held.isEmpty)
            Text(
              (data['held_empty'] as String?) ?? '',
              style: Ds.t.caption.copyWith(color: kTextLo),
            )
          else
            for (final h in held) ...[
              Text(
                ((h as Map)['label'] as String?) ?? '',
                style: Ds.t.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: kTextHi,
                ),
              ),
              SizedBox(height: Ds.space.x4),
              Text(
                (h['detail'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
              SizedBox(height: Ds.space.x8),
            ],
          SizedBox(height: Ds.space.x24),
          _line(
            (guard['label'] as String?) ?? '',
            (guard['value_label'] as String?) ?? '',
          ),
          SizedBox(height: Ds.space.x16),
          _line(
            (window['label'] as String?) ?? '',
            (window['value_label'] as String?) ?? '',
          ),
          SizedBox(height: Ds.space.x16),
          _line(
            (alerts['label'] as String?) ?? '',
            (alerts['value_label'] as String?) ?? '',
          ),
          if (recent.isEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              (alerts['quiet'] as String?) ?? '',
              style: Ds.t.caption.copyWith(color: kTextLo),
            ),
          ] else
            for (final a in recent) ...[
              SizedBox(height: Ds.space.x12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ToneChip(
                    label: ((a as Map)['severity'] as String?) ?? '',
                    tone: toneByName(
                      (a['severity'] as String?) == 'critical'
                          ? 'error'
                          : 'warning',
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${a['at_label'] ?? ''} · ${a['name'] ?? ''}',
                          style: Ds.t.caption.copyWith(
                            fontWeight: FontWeight.w600,
                            color: kTextHi,
                          ),
                        ),
                        SizedBox(height: Ds.space.x4),
                        Text(
                          '${a['detail'] ?? ''}',
                          style: Ds.t.caption.copyWith(color: kTextLo),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
        ],
      ),
    );
  }

  Widget _laneRow(Map<String, dynamic> l) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Text(
          (l['label'] as String?) ?? '',
          style: Ds.t.body.copyWith(
            fontWeight: FontWeight.w600,
            color: kTextHi,
          ),
        ),
      ),
      SizedBox(width: Ds.space.x8),
      ToneChip(
        label: (l['value_label'] as String?) ?? '',
        tone: toneByName((l['tone'] as String?) ?? 'neutral'),
      ),
    ],
  );

  Widget _line(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Ds.t.caption.copyWith(color: kTextLo)),
      SizedBox(height: Ds.space.x4),
      Text(value, style: Ds.t.body.copyWith(color: kTextHi)),
    ],
  );

  Widget _stat(String label, String value) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: Ds.space.x12,
      vertical: Ds.space.x8,
    ),
    decoration: BoxDecoration(
      color: kPageBg,
      borderRadius: Ds.r.rButton,
      border: Border.all(color: kBorder),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Ds.t.caption.copyWith(color: kTextLo)),
        SizedBox(height: Ds.space.x4),
        Text(
          value,
          style: Ds.t.body.copyWith(
            fontWeight: FontWeight.w600,
            color: kTextHi,
          ),
        ),
      ],
    ),
  );
}
