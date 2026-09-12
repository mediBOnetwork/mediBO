// CHANGE #810 — one row of the admin Customers list.
//
// The same shape #753 landed on for suppliers, and for the same reason: a
// customer list is scanned for a NAME. So the row is the pharmacy name —
// allowed to wrap, never ellipsised — with one quiet line under it (city ·
// code) and a status dot. The only extra it carries is the churn flag, and
// only when the BACKEND said the flag applies: `churn.has`, never a date
// arithmetic done here.
//
// Every string is a payload field. There is no fallback wording in this file,
// because inventing one puts a second, staler answer on screen next to the
// server's.
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../screens/admin/customer_pipeline_screen.dart';

class CustomerConsoleRow extends StatelessWidget {
  final Map<String, dynamic> row;

  /// Tapping the row opens the customer page.
  final VoidCallback? onOpen;

  /// CMD #1886 — customers_stage_meta()'s chip for this row: {label, tone}.
  /// The registration funnel's word for where this customer actually is. Null
  /// (or a payload this build has not been sent) draws nothing at all.
  final dynamic stageChip;

  const CustomerConsoleRow(
      {super.key, required this.row, this.onOpen, this.stageChip});

  String _s(String key) => (row[key] as String?) ?? '';

  Map<String, dynamic> get _churn {
    final v = row['churn'];
    return v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};
  }

  Color _dot() {
    switch (_s('status_tone')) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      default:
        return Ds.c.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _s('subtitle');
    final status = _s('status_label');
    final churn = _churn;
    final churnLabel = (churn['label'] as String?) ?? '';
    final showChurn = churn['has'] == true && churnLabel.isNotEmpty;

    return InkWell(
      onTap: onOpen,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          border: Border(bottom: BorderSide(color: Ds.c.divider)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(
                  child: Text(_s('name'),
                      style: Ds.t.bodyStrong, softWrap: true)),
              if (stageChip != null) ...[
                SizedBox(width: Ds.space.x8),
                CustomerStageChip(chip: stageChip),
              ],
            ]),
            if (subtitle.isNotEmpty || status.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Row(children: [
                if (subtitle.isNotEmpty)
                  Flexible(
                    child: Text(subtitle,
                        style: Ds.t.caption, overflow: TextOverflow.ellipsis),
                  ),
                if (subtitle.isNotEmpty && status.isNotEmpty)
                  SizedBox(width: Ds.space.x8),
                if (status.isNotEmpty) ...[
                  Container(
                    width: Ds.space.x8,
                    height: Ds.space.x8,
                    decoration:
                        BoxDecoration(color: _dot(), shape: BoxShape.circle),
                  ),
                  SizedBox(width: Ds.space.x4),
                  Text(status, style: Ds.t.caption),
                ],
              ]),
            ],
            if (showChurn) ...[
              SizedBox(height: Ds.space.x4),
              Row(children: [
                Icon(Icons.schedule,
                    size: Ds.space.x12, color: Ds.c.warning),
                SizedBox(width: Ds.space.x4),
                Flexible(
                  child: Text(churnLabel,
                      style: Ds.t.caption.copyWith(color: Ds.c.warning),
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
