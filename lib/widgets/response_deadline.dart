// CHANGE #687 · feature_gaps #68 — the response countdown.
//
// One widget for four surfaces: the supplier inquiry tab, the public
// /inquiry/<token> link page, the admin inquiry tab and the supplier's purchase
// order card. All four read the SAME backend block — `deadline_block()` — so
// the wording, the tone and the poll rate are identical everywhere by
// construction rather than by four people remembering to match.
//
// Nothing here computes anything. There is no Timer arithmetic on deadline_at,
// no mm:ss formatting, no "less than two minutes means orange": the backend
// sends `label`, `value_label`, `deadline_label`, `tone`, `expired` and its own
// `refresh_s`, and this file prints them and re-asks on that cadence. That is
// the same contract order_hours_card.dart already holds — see DESIGN.md and the
// max-backend rule.
//
// Payload (deadline_block):
//   has            bool    — false => render nothing at all (settled, or no clock)
//   title          string  — "Response deadline" / "Reply deadline"
//   label          string  — "Reply in" | "Overdue by"
//   value_label    string  — "7m 11s" — already formatted, print verbatim
//   deadline_label string  — "Reply by 10:29 AM" — IST, already formatted
//   expired        bool
//   expired_note   string  — one line of backend copy, only when expired
//   tone           string  — info | warning | danger
//   refresh_s      int     — how often the surface should re-ask

import 'dart:async';

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

String _str(Map<String, dynamic> m, String k) {
  final v = m[k];
  return v == null ? '' : v.toString();
}

/// The backend names a tone; this turns one into a token colour and never
/// guesses one from the numbers.
Color _tone(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'brand':
      return Ds.c.brand;
    default:
      return Ds.c.info;
  }
}

Color _toneSoft(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'brand':
      return Ds.c.brandSoft;
    default:
      return Ds.c.infoSoft;
  }
}

/// The full-width card form — used above a list of items the supplier is being
/// asked about (supplier tab, link page) and above the accept buttons on a PO.
class ResponseDeadline extends StatefulWidget {
  const ResponseDeadline({
    super.key,
    required this.block,
    this.onRefresh,
    this.renderKey = 'c687_deadline',
    this.dense = false,
  });

  /// The backend's `deadline` block. `has:false` (or an empty map) renders
  /// nothing — absence is explicit, never inferred from a missing timestamp.
  final Map<String, dynamic> block;

  /// Called on the backend's own `refresh_s` so the countdown stays live. The
  /// surface re-fetches its payload; this widget never recomputes one.
  final Future<void> Function()? onRefresh;

  final String renderKey;
  final bool dense;

  @override
  State<ResponseDeadline> createState() => _ResponseDeadlineState();
}

class _ResponseDeadlineState extends State<ResponseDeadline> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(covariant ResponseDeadline old) {
    super.didUpdateWidget(old);
    if (_str(old.block, 'refresh_s') != _str(widget.block, 'refresh_s') ||
        old.onRefresh != widget.onRefresh) {
      _arm();
    }
  }

  /// The poll rate is the backend's decision, not a constant in this file.
  /// Missing or unreadable => no timer at all rather than a guessed interval.
  void _arm() {
    _tick?.cancel();
    _tick = null;
    if (widget.onRefresh == null) return;
    if (widget.block['has'] != true) return;
    final s = widget.block['refresh_s'];
    final secs = s is num ? s.toInt() : int.tryParse('$s');
    if (secs == null || secs <= 0) return;
    _tick = Timer.periodic(Duration(seconds: secs), (_) async {
      final cb = widget.onRefresh;
      if (cb == null || !mounted) return;
      await cb();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    if (b['has'] != true) return const SizedBox.shrink();

    final tone = _str(b, 'tone');
    final fg = _tone(tone);
    final label = _str(b, 'label');
    final value = _str(b, 'value_label');
    final byLabel = _str(b, 'deadline_label');
    final note = _str(b, 'expired_note');
    final title = _str(b, 'title');

    RenderLog.write(widget.renderKey, tone);

    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(Icons.schedule, size: Ds.space.x16, color: fg),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Text(
            title.isEmpty ? label : title,
            style: TextStyle(
              fontSize: Ds.t.captionSize,
              fontWeight: FontWeight.w600,
              color: Ds.c.textSecondary,
            ),
          ),
        ),
        Container(
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12, vertical: Ds.space.x4),
          decoration: BoxDecoration(
            color: _toneSoft(tone),
            borderRadius: Ds.r.rChip,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (label.isNotEmpty) ...[
              Text(label,
                  style: TextStyle(
                    fontSize: Ds.t.captionSize,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  )),
              SizedBox(width: Ds.space.x4),
            ],
            Text(value,
                style: TextStyle(
                  fontSize: Ds.t.bodySize,
                  fontWeight: FontWeight.w700,
                  color: fg,
                )),
          ]),
        ),
      ],
    );

    if (widget.dense) return head;

    return Container(
      margin: EdgeInsets.symmetric(vertical: Ds.space.x8),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        head,
        if (byLabel.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(byLabel,
              style: TextStyle(
                fontSize: Ds.t.captionSize,
                fontWeight: FontWeight.w400,
                color: Ds.c.textSecondary,
              )),
        ],
        if (note.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(note,
              style: TextStyle(
                fontSize: Ds.t.captionSize,
                fontWeight: FontWeight.w500,
                color: fg,
              )),
        ],
      ]),
    );
  }
}

/// The chip form — one line inside a row that already has its own frame (an
/// admin table row, a compact list tile). Same payload, same strings.
class ResponseDeadlineChip extends StatelessWidget {
  const ResponseDeadlineChip({super.key, required this.block});

  final Map<String, dynamic> block;

  @override
  Widget build(BuildContext context) {
    final b = block;
    if (b['has'] != true) return const SizedBox.shrink();
    final tone = _str(b, 'tone');
    final label = _str(b, 'label');
    final value = _str(b, 'value_label');
    RenderLog.write('c687_deadline_chip', tone);
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: _toneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(
        label.isEmpty ? value : '$label $value',
        style: TextStyle(
          fontSize: Ds.t.captionSize,
          fontWeight: FontWeight.w500,
          color: _tone(tone),
        ),
      ),
    );
  }
}

/// Reads the `deadline` block out of any payload that carries one, so no caller
/// has to remember the key or the shape.
Map<String, dynamic> deadlineOf(Object? payload) =>
    _map(_map(payload)['deadline']);

/// The supplier's response record as one chip — "Answered in time 67%".
/// Payload: `supplier_response_stats()` (rate_label, rate_value, rate_tone,
/// median_label, median_value, has). Same rule as everything above: the
/// percentage and the duration are already strings when they arrive.
class ResponseStatsChip extends StatelessWidget {
  const ResponseStatsChip({super.key, required this.stats, this.showMedian = true});

  final Map<String, dynamic> stats;
  final bool showMedian;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    if (s['has'] != true) return const SizedBox.shrink();
    final tone = _str(s, 'rate_tone');
    final rate = _str(s, 'rate_value');
    final rateLabel = _str(s, 'rate_label');
    final median = _str(s, 'median_value');
    if (rate.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c687_response_stats', tone);
    final text = showMedian && median.isNotEmpty
        ? '$rateLabel $rate · $median'
        : '$rateLabel $rate';
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: _toneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: Ds.t.captionSize,
          fontWeight: FontWeight.w500,
          color: _tone(tone),
        ),
      ),
    );
  }
}
