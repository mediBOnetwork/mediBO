import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../utils/render_log.dart';
import 'dev_queue_common.dart';

/// The Waiting economy panel (CHANGE #1819).
///
/// `dev_ctl_get().waiting` is `dev_wait_report()` verbatim: the title, the
/// chip and its tone, the since-line, every row label, value, sub-line and
/// tone, and the footnote are backend strings. This widget adds up nothing,
/// compares nothing and words nothing — the whole point of the change it ships
/// with is that a wait is measured in one place, so a second opinion computed
/// in Dart would be a second, disagreeing truth. A payload that says
/// `has: false` draws nothing at all.
class WaitingEconomyCard extends StatelessWidget {
  final Map<String, dynamic> payload;
  const WaitingEconomyCard({super.key, required this.payload});

  /// The payload speaks in tones (success / warning / danger / info);
  /// `statusTone` speaks in dev-queue statuses. One lookup, no judgement: an
  /// unknown tone stays neutral rather than being guessed from the value.
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
    if ((payload['has'] ?? false) != true) {
      RenderLog.write('c1819_wait_rows', 0);
      return const SizedBox.shrink();
    }
    final rows = (payload['rows'] as List?) ?? const [];
    // Reachability proof (CLAUDE.md): the live render-log is what says this
    // widget PAINTED — a string in the bundle only says it compiled.
    RenderLog.write('c1819_wait_rows', rows.length);
    final chip = '${payload['chip'] ?? ''}';
    final since = '${payload['since_line'] ?? ''}';
    final footnote = '${payload['footnote'] ?? ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.hourglass_disabled, size: Ds.space.x16, color: kTextLo),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Text('${payload['title'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ds.t.bodyStrong),
        ),
        if (chip.isNotEmpty)
          ToneChip(
              label: chip,
              tone: statusTone(toneKey('${payload['chip_tone'] ?? 'info'}'))),
      ]),
      if (since.isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(since, style: Ds.t.caption),
      ],
      SizedBox(height: Ds.space.x12),
      for (final raw in rows)
        _WaitRow(row: Map<String, dynamic>.from(raw as Map)),
      if (footnote.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Text(footnote, style: Ds.t.caption),
      ],
    ]);
  }
}

class _WaitRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const _WaitRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final sub = '${row['sub'] ?? ''}';
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${row['label'] ?? ''}', style: Ds.t.body),
            // An absent sub-line is OMITTED, never dashed: "—" reads as a
            // measurement of nothing, which is not what an absent line means.
            if (sub.isNotEmpty) Text(sub, style: Ds.t.caption),
          ]),
        ),
        SizedBox(width: Ds.space.x8),
        ToneChip(
            label: '${row['value'] ?? ''}',
            tone: statusTone(
                WaitingEconomyCard.toneKey('${row['tone'] ?? 'info'}'))),
      ]),
    );
  }
}
