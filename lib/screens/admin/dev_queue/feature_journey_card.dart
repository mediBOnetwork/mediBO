import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../utils/render_log.dart';
import 'dev_queue_common.dart';

/// CMD #2075 — the command's OWN browser journey, on the command detail screen.
///
/// THE APP RENDERS. IT NEVER DECIDES. `dev_cmd_qa_detail().feature_journey`
/// (built by `_dev_feature_journey_card` on the control plane) carries the
/// title, the status chip label + tone, the gate's own sentence (`detail`),
/// the lane rows (`rows[]`: label / value / tone), the plan lines (`lines[]`),
/// the evidence paths (`links[]`) and the rerun hint. This widget places those
/// strings on screen in payload order and computes nothing: a status that is
/// 'passed' but stale, a plan that is invalid, a lane that never ran — every
/// one of those words is the backend's, and the finish gate reads the same
/// function, so what Om sees here is exactly what blocks or frees the row.
class FeatureJourneyCard extends StatelessWidget {
  final Map<String, dynamic> fj;
  const FeatureJourneyCard({super.key, required this.fj});

  static List<Map<String, dynamic>> _list(dynamic v) => (v as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const [];

  static List<String> _strings(dynamic v) =>
      (v as List?)?.map((e) => e.toString()).toList() ?? const [];

  @override
  Widget build(BuildContext context) {
    final title = (fj['title'] ?? '').toString();
    final statusLabel = (fj['status_label'] ?? '').toString();
    final statusTone = (fj['status_tone'] ?? 'neutral').toString();
    final detail = (fj['detail'] ?? '').toString();
    final rows = _list(fj['rows']);
    final lines = _strings(fj['lines']);
    final links = _list(fj['links']);
    final stepsTitle = (fj['steps_title'] ?? '').toString();
    final hint = (fj['hint'] ?? '').toString();
    RenderLog.write('devq_feature_journey', statusTone);
    return Semantics(
      identifier: 'devq_feature_journey',
      container: true,
      child: Container(
        margin: EdgeInsets.only(bottom: Ds.space.x12),
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: kPageBg,
          borderRadius: Ds.r.rButton,
          border: Border.all(color: kBorder),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(title,
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
            ),
            SizedBox(width: Ds.space.x8),
            ToneChip(label: statusLabel, tone: toneByName(statusTone)),
          ]),
          if (detail.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(detail, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
          if (rows.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            for (final r in rows) _row(r),
          ],
          if (lines.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            if (stepsTitle.isNotEmpty)
              Text(stepsTitle,
                  style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700)),
            for (final l in lines)
              Padding(
                padding: EdgeInsets.only(top: Ds.space.x4),
                child: Text(l, style: Ds.t.caption.copyWith(color: kTextLo)),
              ),
          ],
          if (links.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            for (final l in links)
              Padding(
                padding: EdgeInsets.only(top: Ds.space.x4),
                child: Text(
                    '${(l['label'] ?? '').toString()}: ${(l['path'] ?? '').toString()}',
                    style: Ds.t.caption.copyWith(color: kTextLo)),
              ),
          ],
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(hint, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
        ]),
      ),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final label = (r['label'] ?? '').toString();
    final value = (r['value'] ?? '').toString();
    final tone = (r['tone'] ?? 'neutral').toString();
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: Ds.space.x32 * 3,
          child: Text(label, style: Ds.t.caption.copyWith(color: kTextLo)),
        ),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Text(value,
              style: Ds.t.caption.copyWith(
                  color: toneByName(tone).fg, fontWeight: FontWeight.w500)),
        ),
      ]),
    );
  }
}
