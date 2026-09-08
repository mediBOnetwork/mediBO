import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
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

  /// CMD #368 — saving a threshold. Null in a read-only context; the Cron
  /// health screen passes the callback that POSTs `db_admission_set` and then
  /// reloads, so the numbers on screen are always the SERVER's, not a local
  /// optimistic copy.
  final Future<void> Function(Map<String, dynamic> patch)? onAdmissionPatch;
  const DbLaneSection({
    super.key,
    required this.data,
    this.onAdmissionPatch,
  });

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
    final admission =
        (data['admission'] as Map?)?.cast<String, dynamic>() ?? const {};
    final violations =
        (data['violations'] as Map?)?.cast<String, dynamic>() ?? const {};
    final violRecent = (violations['recent'] as List?) ?? const [];

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
          if (admission.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            Divider(color: kBorder, height: Ds.space.x24),
            _AdmissionBlock(data: admission, onPatch: onAdmissionPatch),
          ],
          SizedBox(height: Ds.space.x24),
          _line(
            (guard['label'] as String?) ?? '',
            (guard['value_label'] as String?) ?? '',
          ),
          if (violations.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _line(
                    (violations['label'] as String?) ?? '',
                    (violations['value_label'] as String?) ?? '',
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                ToneChip(
                  label: '${violRecent.length}',
                  tone: toneByName(
                    (violations['tone'] as String?) ?? 'neutral',
                  ),
                ),
              ],
            ),
            for (final v in violRecent) ...[
              SizedBox(height: Ds.space.x8),
              Text(
                '${(v as Map)['at_label'] ?? ''} · ${v['label'] ?? ''}',
                style: Ds.t.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color: kTextHi,
                ),
              ),
              Text(
                '${v['detail'] ?? ''}',
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
            ],
          ],
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

/// CMD #368 — Runner admission control, edited in place.
///
/// The card decides nothing. Headline, every threshold label, every hint, the
/// empty state and the "claims held back" lines are strings built by
/// `db_admission_status()` (folded into `db_health_status().admission`). Tapping
/// a threshold opens a sheet with a number field; saving calls
/// `db_admission_set(patch)` and the whole Cron health screen reloads, so what
/// comes back on screen is what the SERVER stored, never a local guess.
class _AdmissionBlock extends StatelessWidget {
  final Map<String, dynamic> data;
  final Future<void> Function(Map<String, dynamic> patch)? onPatch;
  const _AdmissionBlock({required this.data, this.onPatch});

  @override
  Widget build(BuildContext context) {
    final toggle = (data['toggle'] as Map?)?.cast<String, dynamic>() ?? const {};
    final thresholds = (data['thresholds'] as List?) ?? const [];
    final recent = (data['recent'] as List?) ?? const [];
    final editable = onPatch != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                (data['label'] as String?) ?? '',
                style: Ds.t.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: kTextHi,
                ),
              ),
            ),
            SizedBox(width: Ds.space.x8),
            if (editable)
              Switch(
                value: toggle['value'] == true,
                activeColor: kBrand,
                onChanged: (v) => onPatch!({'enabled': v}),
              )
            else
              ToneChip(
                label: '${toggle['value'] == true}',
                tone: toneByName((data['tone'] as String?) ?? 'neutral'),
              ),
          ],
        ),
        SizedBox(height: Ds.space.x4),
        Text(
          (data['value_label'] as String?) ?? '',
          style: Ds.t.body.copyWith(color: kTextHi),
        ),
        SizedBox(height: Ds.space.x4),
        Text(
          (toggle['hint'] as String?) ?? '',
          style: Ds.t.caption.copyWith(color: kTextLo),
        ),
        SizedBox(height: Ds.space.x12),
        for (final t in thresholds)
          _ThresholdRow(
            data: (t as Map).cast<String, dynamic>(),
            onPatch: onPatch,
          ),
        SizedBox(height: Ds.space.x12),
        Text(
          (data['source_label'] as String?) ?? '',
          style: Ds.t.caption.copyWith(color: kTextLo),
        ),
        SizedBox(height: Ds.space.x4),
        Text(
          (data['updated_label'] as String?) ?? '',
          style: Ds.t.caption.copyWith(color: kTextLo),
        ),
        SizedBox(height: Ds.space.x16),
        Text(
          (data['recent_heading'] as String?) ?? '',
          style: Ds.t.caption.copyWith(color: kTextLo),
        ),
        SizedBox(height: Ds.space.x4),
        if (recent.isEmpty)
          Text(
            (data['recent_empty'] as String?) ?? '',
            style: Ds.t.caption.copyWith(color: kTextLo),
          )
        else
          for (final r in recent) ...[
            SizedBox(height: Ds.space.x8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ToneChip(
                  label: ((r as Map)['at_label'] as String?) ?? '',
                  tone: toneByName((r['tone'] as String?) ?? 'warning'),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: Text(
                    '${r['label'] ?? ''} — ${r['detail'] ?? ''}',
                    style: Ds.t.caption.copyWith(color: kTextLo),
                  ),
                ),
              ],
            ),
          ],
      ],
    );
  }
}

/// One editable threshold. Value, unit, bounds and the sentence explaining why
/// the number is what it is all come from the payload.
class _ThresholdRow extends StatelessWidget {
  final Map<String, dynamic> data;
  final Future<void> Function(Map<String, dynamic> patch)? onPatch;
  const _ThresholdRow({required this.data, this.onPatch});

  @override
  Widget build(BuildContext context) {
    final key = (data['key'] as String?) ?? '';
    final label = (data['label'] as String?) ?? '';
    final hint = (data['hint'] as String?) ?? '';
    final unit = (data['unit'] as String?) ?? '';
    final value = '${data['value'] ?? ''}';

    return InkWell(
      onTap: onPatch == null ? null : () => _edit(context, key, label, hint),
      borderRadius: Ds.r.rButton,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.space.x48),
        padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Ds.t.body.copyWith(color: kTextHi)),
                  SizedBox(height: Ds.space.x4),
                  Text(hint, style: Ds.t.caption.copyWith(color: kTextLo)),
                ],
              ),
            ),
            SizedBox(width: Ds.space.x12),
            Text(
              unit == '%' ? '$value%' : '$value $unit',
              style: Ds.t.body.copyWith(
                fontWeight: FontWeight.w600,
                color: kTextHi,
              ),
            ),
            if (onPatch != null) ...[
              SizedBox(width: Ds.space.x8),
              Icon(Icons.edit_outlined, size: 16, color: kTextLo),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    String key,
    String label,
    String hint,
  ) async {
    final ctrl = TextEditingController(text: '${data['value'] ?? ''}');
    final saved = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Container(
          padding: EdgeInsets.all(Ds.space.x24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Ds.t.subtitle.copyWith(
                  fontWeight: FontWeight.w700,
                  color: kTextHi,
                ),
              ),
              SizedBox(height: Ds.space.x8),
              Text(hint, style: Ds.t.caption.copyWith(color: kTextLo)),
              SizedBox(height: Ds.space.x16),
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: kPageBg,
                  border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                ),
              ),
              SizedBox(height: Ds.space.x24),
              SizedBox(
                width: double.infinity,
                height: Ds.space.x48,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: kBrand),
                  onPressed: () =>
                      Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
                  child: Text(c('dev_queue.admission_save')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != null && onPatch != null) await onPatch!({key: saved});
  }
}
