import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../utils/render_log.dart';
import 'dev_queue_common.dart';

/// CMD #1940 — the deploy-lock waiter queue, drawn on the Runner-control card.
///
/// THE APP RENDERS. IT NEVER DECIDES. Everything here is
/// `dev_ctl_get().deploy_wait` — `deploy_wait_card()` on the control plane:
/// the holder line, the waiters in the BACKEND's order carrying their own
/// position / next-check strings, and the interval sentence. `has:false`, or an
/// absent block on an older payload, draws nothing. The only tap is the
/// intervals editor, which opens the Pool settings sheet (one `pool_set`).
class DeployWaitBlock extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback? onEditIntervals;
  const DeployWaitBlock({super.key, required this.data, this.onEditIntervals});

  /// The waiters exactly as sent — never re-sorted here (position is theirs).
  static List<Map<String, dynamic>> waitersOf(Map<String, dynamic> data) =>
      ((data['waiters'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();

  Map<String, dynamic> get _holder =>
      (data['holder'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _intervals =>
      (data['intervals'] as Map?)?.cast<String, dynamic>() ?? const {};

  @override
  Widget build(BuildContext context) {
    if (data['has'] != true) return const SizedBox.shrink();
    final waiters = waitersOf(data);
    RenderLog.write('c1940_deploy_wait_block', 1);
    RenderLog.write('c1940_deploy_waiters', waiters.length);
    final title = (data['title'] ?? '').toString();
    final countLabel = (data['count_label'] ?? '').toString();
    final holderLabel = (_holder['label'] ?? '').toString();
    final holderDetail = (_holder['detail'] ?? '').toString();
    final holderTone = toneByName((_holder['tone'] ?? 'neutral').toString());
    final intervals = (_intervals['label'] ?? '').toString();
    final urgent = (_intervals['urgent_label'] ?? '').toString();
    final push = (_intervals['push_label'] ?? '').toString();
    final edit = (_intervals['edit_label'] ?? '').toString();
    final caption = Ds.t.caption.copyWith(color: Ds.c.textSecondary);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.hourglass_top_outlined,
              size: Ds.space.x16, color: Ds.c.textSecondary),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Text(title,
                style: Ds.t.caption
                    .copyWith(fontWeight: FontWeight.w700, color: Ds.c.text)),
          ),
          if (onEditIntervals != null)
            Tooltip(
              message: edit,
              child: InkWell(
                onTap: onEditIntervals,
                borderRadius: Ds.r.rChip,
                child: SizedBox(
                  width: Ds.touch.minTarget,
                  height: Ds.touch.minTarget,
                  child: Icon(Icons.tune, size: Ds.space.x24, color: Ds.c.brand),
                ),
              ),
            ),
        ]),
        SizedBox(height: Ds.space.x8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (holderLabel.isNotEmpty) ...[
            ToneChip(label: holderLabel, tone: holderTone),
            SizedBox(width: Ds.space.x8),
          ],
          Expanded(
            child: Text(holderDetail,
                style: caption, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ]),
        SizedBox(height: Ds.space.x8),
        Text(countLabel, style: caption),
        for (final w in waiters) _WaiterRow(w),
        SizedBox(height: Ds.space.x12),
        if (intervals.isNotEmpty) Text(intervals, style: caption),
        if (urgent.isNotEmpty) Text(urgent, style: caption),
        if (push.isNotEmpty) Text(push, style: caption),
      ]),
    );
  }
}

/// One waiter: its position pill (or its kind, for a lease / red-base sleeper),
/// the command label and the backend's one-line detail (agent · kind · waited ·
/// next check). Every string is the payload's own.
class _WaiterRow extends StatelessWidget {
  final Map<String, dynamic> w;
  const _WaiterRow(this.w);

  @override
  Widget build(BuildContext context) {
    final pos = (w['position_label'] ?? '').toString();
    final kindLabel = (w['kind_label'] ?? '').toString();
    final label = (w['label'] ?? '').toString();
    final detail = (w['detail'] ?? '').toString();
    final tone = toneByName((w['tone'] ?? 'neutral').toString());
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x8),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        child: Row(children: [
          ToneChip(label: pos.isNotEmpty ? pos : kindLabel, tone: tone),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: Ds.t.body
                        .copyWith(fontWeight: FontWeight.w500, color: Ds.c.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(detail,
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// The Pool-settings field for `worker_pool.deploy_wait.minutes_by_position`
/// is typed as "2, 5, 5, 10". This parses it — and ONLY parses it: an empty or
/// malformed entry yields null so the caller keeps the backend's stored list
/// instead of inventing one. Values are minutes; the backend re-reads the list
/// on every check and repeats the last value past the end.
List<int>? parseMinutesByPosition(String text) {
  final parts = text
      .split(RegExp(r'[,\s·]+'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  final out = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n <= 0) return null;
    out.add(n);
  }
  return out;
}
