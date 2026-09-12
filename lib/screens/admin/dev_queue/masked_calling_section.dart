import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';

/// CHANGE #404 — Masked calling, on the Cron health screen.
///
/// It sits with the three lanes because it answers the same kind of question
/// they do: not "what happened" but "is this thing actually on right now". Two
/// people on an order are connected through a DID; this is where Om reads which
/// provider is carrying that, how many numbers the pool holds, and — while the
/// stub is still answering — exactly what has to be bought and configured at
/// Exotel before real calls flow.
///
/// The widget decides nothing. The title, the subtitle, every row label, every
/// value string, every tone and every line of the to-do list are built by
/// `call_setup_status()`. Switching to Exotel is an UPDATE to `call_config`, and
/// this card changes its own words on the next read with no deploy.
class MaskedCallingSection extends StatelessWidget {
  final Map<String, dynamic> data;
  const MaskedCallingSection({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    // ok:false is the backend refusing (not a crash) and it ships its own
    // sentence — render that, never a locally worded one.
    if (data['ok'] != true) {
      final err = (data['error'] as String?) ?? '';
      if (err.isEmpty) return const SizedBox.shrink();
      return DqCard(child: Text(err, style: Ds.t.body.copyWith(color: Ds.c.danger)));
    }

    final rows = (data['rows'] as List?) ?? const [];
    final todo = (data['todo'] as List?) ?? const [];
    final tone = toneByName((data['tone'] as String?) ?? 'neutral');
    final todoTitle = (data['todo_title'] as String?) ?? '';

    return DqCard(
      accent: tone.fg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text((data['title'] as String?) ?? '', style: Ds.t.subtitle),
              ),
              if (rows.isNotEmpty)
                ToneChip(
                  label: ((rows.first as Map)['value'] ?? '').toString(),
                  tone: tone,
                ),
            ],
          ),
          if (((data['subtitle'] as String?) ?? '').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(data['subtitle'] as String, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x12),
          for (final r in rows) ...[
            _row((r as Map).cast<String, dynamic>()),
            SizedBox(height: Ds.space.x8),
          ],
          if (todo.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            if (todoTitle.isNotEmpty) ...[
              Text(todoTitle, style: Ds.t.bodyStrong),
              SizedBox(height: Ds.space.x8),
            ],
            // Numbered because these are ordered steps, and the order is the
            // backend's — this loop never sorts or filters them.
            for (var i = 0; i < todo.length; i++) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: Ds.space.x24,
                    child: Text('${i + 1}.', style: Ds.t.caption),
                  ),
                  Expanded(child: Text('${todo[i]}', style: Ds.t.caption)),
                ],
              ),
              SizedBox(height: Ds.space.x8),
            ],
          ],
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final value = (r['value'] ?? '').toString();
    return Row(
      children: [
        Expanded(child: Text((r['label'] ?? '').toString(), style: Ds.t.caption)),
        if (value.isNotEmpty)
          ToneChip(label: value, tone: toneByName((r['tone'] as String?) ?? 'neutral')),
      ],
    );
  }
}
