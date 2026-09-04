import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import 'dev_queue_common.dart';

/// The Context economy panel (CHANGE #1197).
///
/// `dev_ctl_get().context` is `dev_context_metrics()` verbatim: the title, the
/// threshold chip, every row label, every value, every sub-line and every tone
/// are backend strings. Nothing in here computes a percentage, a ratio, a token
/// count or a plural — the widget lays rows out and prints what it was sent.
/// A payload that says `has: false` draws nothing at all.
class ContextEconomyCard extends StatelessWidget {
  final Map<String, dynamic> payload;
  const ContextEconomyCard({super.key, required this.payload});

  /// The payload speaks in tones (success / warning / danger / info);
  /// `statusTone` speaks in dev-queue statuses. This is the only mapping, and
  /// it is a lookup, not a judgement — an unknown tone stays neutral rather
  /// than being guessed at from the value.
  static String toneKey(String tone) {
    switch (tone) {
      case 'success':
        return 'completed';
      case 'warning':
        return 'pending';
      case 'danger':
        return 'failed';
      default:
        return 'building';
    }
  }

  @override
  Widget build(BuildContext context) {
    if ((payload['has'] ?? false) != true) return const SizedBox.shrink();
    final rows = (payload['rows'] as List?) ?? const [];
    final threshold = '${payload['threshold_label'] ?? ''}';
    final since = '${payload['since_label'] ?? ''}';
    final footnote = '${payload['footnote'] ?? ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.compress, size: Ds.space.x16, color: kTextLo),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Text('${payload['title'] ?? c('dev_queue.ctx_section')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ds.t.bodyStrong),
        ),
        if (threshold.isNotEmpty)
          ToneChip(label: threshold, tone: statusTone('pending')),
      ]),
      if (since.isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(since, style: Ds.t.caption),
      ],
      SizedBox(height: Ds.space.x12),
      if (rows.isEmpty)
        Text(c('dev_queue.ctx_empty'), style: Ds.t.caption)
      else
        for (final raw in rows)
          _ContextRow(row: Map<String, dynamic>.from(raw as Map)),
      if (footnote.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Text(footnote, style: Ds.t.caption),
      ],
    ]);
  }
}

class _ContextRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const _ContextRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final sub = '${row['sub'] ?? ''}';
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${row['label'] ?? ''}', style: Ds.t.body),
            if (sub.isNotEmpty) Text(sub, style: Ds.t.caption),
          ]),
        ),
        SizedBox(width: Ds.space.x8),
        ToneChip(
            label: '${row['value'] ?? ''}',
            tone: statusTone(
                ContextEconomyCard.toneKey('${row['tone'] ?? 'info'}'))),
      ]),
    );
  }
}
