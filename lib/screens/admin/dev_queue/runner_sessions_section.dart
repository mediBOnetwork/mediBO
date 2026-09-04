import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';

/// CHANGE #1268 — Runner sessions, on the Cron health screen.
///
/// Two failures shared one cause: a slot could be handed a second spec while a
/// build was still open (runner-4 held #850 and was given #985), and two live
/// sessions could both answer to the agent id runner-1, so the steering bridge
/// typed one build's replies into the other session (#1016 and #1055). This is
/// where Om sees the guards holding: who is registered, what each one is
/// building, and every conflict the guards refused.
///
/// The widget decides nothing. Title, sub-line, every row label, sub-line,
/// value, beat time and the conflict caption are strings from
/// `dev_agent_sessions_status()`; tones are backend-chosen names resolved
/// through the shared palette. Rows render in payload order.
class RunnerSessionsSection extends StatelessWidget {
  final Map<String, dynamic> data;
  const RunnerSessionsSection({super.key, required this.data});

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
    if (data['has'] != true) return const SizedBox.shrink();

    final rows = (data['rows'] as List?) ?? const [];
    final incidents = (data['incidents'] as List?) ?? const [];

    return DqCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((data['title'] as String?) ?? '', style: Ds.t.subtitle),
          if (((data['sub'] as String?) ?? '').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(data['sub'] as String,
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ],
          SizedBox(height: Ds.space.x12),
          for (final r in rows) ...[
            _row((r as Map).cast<String, dynamic>()),
            SizedBox(height: Ds.space.x8),
          ],
          SizedBox(height: Ds.space.x4),
          Row(children: [
            ToneChip(
              label: (data['incident_label'] as String?) ?? '',
              tone: toneByName((data['incident_tone'] as String?) ?? 'neutral'),
            ),
          ]),
          for (final i in incidents) ...[
            SizedBox(height: Ds.space.x8),
            _row((i as Map).cast<String, dynamic>()),
          ],
          if (((data['footnote'] as String?) ?? '').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(data['footnote'] as String,
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ],
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final sub = (r['sub'] as String?) ?? '';
    final beat = (r['beat'] as String?) ?? '';
    final value = (r['value'] as String?) ?? '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text((r['label'] as String?) ?? '', style: Ds.t.body),
              if (sub.isNotEmpty)
                Text(sub,
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
              // An absent beat is omitted, never dashed.
              if (beat.isNotEmpty)
                Text(beat,
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            ],
          ),
        ),
        if (value.isNotEmpty)
          ToneChip(
            label: value,
            tone: toneByName((r['tone'] as String?) ?? 'neutral'),
          ),
      ],
    );
  }
}
