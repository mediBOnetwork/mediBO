import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';

/// CHANGE #755 — the self-healing breaker's face.
///
/// Everything here arrives already decided by `runner_health_card()`, which
/// rides along on the `dev_ctl_get` payload the control strip already polls:
/// the score, the wording, every tone name, every formatted number and the
/// trip/resume history. This file chooses no colour, formats no value and
/// writes no sentence — it lays the payload out and nothing else.
///
/// Why it exists: #641's breaker could pause the fleet but never resume it, so
/// the only thing Om could see was a red badge with no way to know whether the
/// database had recovered. This card answers the three questions that matters:
/// how healthy is it, how many builds is that worth, and what happens next.

/// Backend tones use the design-token vocabulary (`danger`); the Dev Queue's
/// chip palette calls the same state `error`. One alias, no new colour.
Tone _tone(Object? name) =>
    toneByName(name.toString() == 'danger' ? 'error' : name.toString());

class RunnerHealthCard extends StatelessWidget {
  final Map<String, dynamic> health;

  /// CHANGE #1593 — "why is it not climbing, right now?". The card's own
  /// numbers are the LAST probe's; this asks the backend to decide again with
  /// the current vitals and shows the answer. Absent callback = no affordance,
  /// so an older screen renders exactly as before.
  final VoidCallback? onWhy;

  const RunnerHealthCard({super.key, required this.health, this.onWhy});

  bool get _has => (health['has'] ?? false) == true;

  Map<String, dynamic> get _probe =>
      (health['probe'] as Map?)?.cast<String, dynamic>() ?? const {};

  List<Map<String, dynamic>> get _metrics => ((health['metrics'] as List?) ?? const [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  /// CHANGE #1593 — the autoscaler's own account of itself. Absent on any
  /// payload written before this change, and the card simply does not draw it.
  Map<String, dynamic> get _auto =>
      (health['autoscale'] as Map?)?.cast<String, dynamic>() ?? const {};

  List<Map<String, dynamic>> get _history => ((health['history'] as List?) ?? const [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  @override
  Widget build(BuildContext context) {
    if (health.isEmpty) return const SizedBox.shrink();
    final tone = _tone(health['tone']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── header: what the score is, and the one sentence about what is next ──
      Row(children: [
        Icon(Icons.monitor_heart_outlined,
            size: Ds.space.x16 + Ds.space.x4, color: Ds.c.textSecondary),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Text('${health['title'] ?? ''}',
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
        ),
        _scorePill(tone),
      ]),
      SizedBox(height: Ds.space.x8),
      // CHANGE #1593 — this line IS the brake. `next_action` is the probe's own
      // "holding at N — <why>", so a fleet that is not climbing says which of
      // the six brakes is holding it rather than repeating that the database is
      // healthy, which it was for all 48 probes it spent stuck at 3.
      Text('${health['next_action'] ?? ''}', style: Ds.t.caption),
      // The ladder, when the probe recorded one: where it is, what it has
      // proven, and the cap it is allowed to reach.
      if ((_auto['has'] ?? false) == true &&
          '${_auto['ladder_label'] ?? ''}'.isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        InkWell(
          onTap: onWhy,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
            child: Row(children: [
              Icon(Icons.stairs_outlined,
                  size: Ds.t.captionSize + Ds.space.x4,
                  color: Ds.c.textSecondary),
              SizedBox(width: Ds.space.x4),
              Flexible(
                child: Text('${_auto['ladder_label']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.caption),
              ),
              if (onWhy != null) ...[
                SizedBox(width: Ds.space.x4),
                Icon(Icons.help_outline,
                    size: Ds.t.captionSize + Ds.space.x4,
                    color: Ds.c.textSecondary),
              ],
            ]),
          ),
        ),
      ],
      SizedBox(height: Ds.space.x12),

      // ── the three live numbers ──
      Row(children: [
        Expanded(
            child: _stat('${health['semaphore_label'] ?? ''}',
                '${health['semaphore_display'] ?? ''}')),
        Expanded(
            child: _stat('${health['streak_label'] ?? ''}',
                '${health['streak_display'] ?? ''}')),
      ]),
      SizedBox(height: Ds.space.x12),

      // ── the measured inputs ──
      if (_has)
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [for (final m in _metrics) _metricChip(m)],
        ),
      SizedBox(height: Ds.space.x12),

      // ── probe cadence: the proof it is parked, not free-running ──
      Row(children: [
        Icon(Icons.timer_outlined, size: Ds.t.captionSize + Ds.space.x4,
            color: Ds.c.textSecondary),
        SizedBox(width: Ds.space.x4),
        Expanded(
          child: Text(
              '${_probe['display'] ?? ''} · ${_probe['last_display'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ds.t.caption),
        ),
      ]),

      SizedBox(height: Ds.space.x24),

      // ── trips and resumes ──
      Text('${health['history_title'] ?? ''}',
          style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600)),
      SizedBox(height: Ds.space.x8),
      if (_history.isEmpty)
        Text('${health['history_empty'] ?? ''}', style: Ds.t.caption)
      else
        for (final h in _history) _historyRow(h),
    ]);
  }

  /// The score itself, in the tone the backend picked for it.
  Widget _scorePill(Tone tone) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration: BoxDecoration(
            color: tone.bg, borderRadius: BorderRadius.circular(Ds.r.chip)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${health['score_label'] ?? ''}',
              style: Ds.t.caption.copyWith(color: tone.fg)),
          SizedBox(width: Ds.space.x8),
          Text('${health['score_display'] ?? ''}',
              style: Ds.t.body
                  .copyWith(color: tone.fg, fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _stat(String label, String value) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Ds.t.caption),
        SizedBox(height: Ds.space.x4),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
      ]);

  Widget _metricChip(Map<String, dynamic> m) {
    final tone = _tone(m['tone']);
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(
          color: tone.bg, borderRadius: BorderRadius.circular(Ds.r.chip)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('${m['label'] ?? ''}',
            style: Ds.t.caption.copyWith(color: tone.fg)),
        SizedBox(width: Ds.space.x8),
        Text('${m['value'] ?? ''}',
            style: Ds.t.caption
                .copyWith(color: tone.fg, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _historyRow(Map<String, dynamic> h) {
    final tone = _tone(h['tone']);
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: Ds.space.x8,
          height: Ds.space.x8,
          margin: EdgeInsets.only(top: Ds.space.x4, right: Ds.space.x8),
          decoration: BoxDecoration(color: tone.fg, shape: BoxShape.circle),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('${h['kind_label'] ?? ''}',
                  style: Ds.t.caption
                      .copyWith(color: tone.fg, fontWeight: FontWeight.w700)),
              SizedBox(width: Ds.space.x8),
              Text('${h['at_display'] ?? ''}', style: Ds.t.caption),
            ]),
            Text('${h['reason'] ?? ''}', style: Ds.t.caption),
          ]),
        ),
      ]),
    );
  }
}

/// The one-glance version for the collapsed control strip: the score in its
/// tone, so a paused or degraded fleet is visible without opening anything.
class RunnerHealthChip extends StatelessWidget {
  final Map<String, dynamic> health;
  const RunnerHealthChip({super.key, required this.health});

  @override
  Widget build(BuildContext context) {
    if ((health['has'] ?? false) != true) return const SizedBox.shrink();
    final tone = _tone(health['tone']);
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(
          color: tone.bg, borderRadius: BorderRadius.circular(Ds.r.chip)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.monitor_heart_outlined,
            size: Ds.t.captionSize, color: tone.fg),
        SizedBox(width: Ds.space.x4),
        Text('${health['score_display'] ?? ''}',
            style: Ds.t.caption
                .copyWith(color: tone.fg, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}
