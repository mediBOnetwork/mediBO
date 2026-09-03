// lib/widgets/order_event_timeline.dart — CHANGE #689 (feature_gaps #75)
//
// The order timeline, drawn verbatim. ONE widget serves all three surfaces —
// the admin ops-board detail sheet, a partner's copy of the same sheet, and the
// customer's Track sheet — because there is only one payload and only one way
// to print it. The difference between an operator's view and a buyer's view is
// made in Postgres (`access`), not here: the buyer's payload simply arrives
// with no supplier name, no phone and no action, so the same code draws less.
//
// It renders `events` in the order it was given. It never sorts, never
// re-times, never re-tones and never decides that a step is late — every one
// of those is a string on the event.
//
// The action button calls the rpc the EVENT named with the args the EVENT
// carried. A new action kind is an INSERT in the backend, not a deploy here.

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/order_timeline_view.dart';

/// Maps the backend's tone word onto the token layer. An unknown tone renders
/// neutral rather than throwing — a tone this build has never heard of must
/// never white-screen an order.
class TimelineTone {
  static Color fg(String tone) {
    switch (tone) {
      case 'red':
        return Ds.c.danger;
      case 'amber':
        return Ds.c.warning;
      case 'green':
        return Ds.c.success;
      default:
        return Ds.c.textSecondary;
    }
  }

  static Color bg(String tone) {
    switch (tone) {
      case 'red':
        return Ds.c.dangerSoft;
      case 'amber':
        return Ds.c.warningSoft;
      case 'green':
        return Ds.c.successSoft;
      default:
        return Ds.c.bg;
    }
  }
}

/// Runs one action and hands back what the backend said. The host owns the
/// Supabase call so this widget stays renderable on the Dart VM.
typedef TimelineActRunner = Future<TimelineActionResult> Function(
  TimelineAction action,
  Map<String, dynamic> extraArgs,
);

class OrderEventTimeline extends StatefulWidget {
  final OrderTimelineView view;

  /// Null on a read-only surface. The backend has already decided whether an
  /// action may be offered (`can_act`, and `action.has` per event); a null
  /// runner is only about whether this HOST can run one.
  final TimelineActRunner? onAct;

  /// Called after an action returns a fresh payload, so the host can re-render.
  final void Function(Map<String, dynamic> timeline)? onRefreshed;

  const OrderEventTimeline({
    super.key,
    required this.view,
    this.onAct,
    this.onRefreshed,
  });

  @override
  State<OrderEventTimeline> createState() => _OrderEventTimelineState();
}

class _OrderEventTimelineState extends State<OrderEventTimeline> {
  String _busyKind = '';
  String _message = '';

  Future<void> _run(
    TimelineAction action, [
    Map<String, dynamic> extra = const {},
  ]) async {
    final runner = widget.onAct;
    if (runner == null || _busyKind.isNotEmpty) return;
    setState(() {
      _busyKind = action.kind;
      _message = '';
    });
    TimelineActionResult res;
    try {
      res = await runner(action, extra);
    } finally {
      if (mounted) setState(() => _busyKind = '');
    }
    if (!mounted) return;

    if (res.needsChoice) {
      final picked = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _ChoiceDialog(result: res),
      );
      if (picked == null) {
        if (res.choices.isEmpty && res.message.isNotEmpty) {
          setState(() => _message = res.message);
        }
        return;
      }
      await _run(action, {res.choiceKey: picked['id']?.toString() ?? ''});
      return;
    }

    setState(() => _message = res.message);
    if (res.timeline.isNotEmpty) widget.onRefreshed?.call(res.timeline);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    if (!v.visible) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (v.heading.isNotEmpty) ...[
          Text(v.heading, style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
        ],
        if (_message.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.infoSoft,
              borderRadius: Ds.r.rChip,
            ),
            child: Text(_message, style: Ds.t.caption),
          ),
          SizedBox(height: Ds.space.x12),
        ],
        if (v.isEmpty)
          Text(v.emptyLabel, style: Ds.t.caption)
        else
          for (final e in v.events) ...[
            _EventRow(
              event: e,
              busy: _busyKind.isNotEmpty && _busyKind == e.action.kind,
              onAct: widget.onAct == null ? null : () => _run(e.action),
            ),
            SizedBox(height: Ds.space.x8),
          ],
        if (v.privacyNote.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Text(v.privacyNote, style: Ds.t.caption),
        ],
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  final TimelineEvent event;
  final bool busy;
  final VoidCallback? onAct;

  const _EventRow({required this.event, required this.busy, this.onAct});

  @override
  Widget build(BuildContext context) {
    final toned = event.isCurrent || event.tone == 'red';
    return Container(
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: toned ? TimelineTone.bg(event.tone) : Ds.c.surface,
        borderRadius: Ds.r.rChip,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: EdgeInsets.only(top: Ds.space.x4),
                width: Ds.space.x8,
                height: Ds.space.x8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: TimelineTone.fg(event.tone),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(event.label, style: Ds.t.body),
                    if (event.hasDetail) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(event.detail, style: Ds.t.caption),
                    ],
                    if (event.actor.has) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(
                        [
                          event.actor.label,
                          event.actor.phone,
                        ].where((s) => s.isNotEmpty).join(' · '),
                        style: Ds.t.caption,
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (event.tsLabel.isNotEmpty)
                    Text(event.tsLabel, style: Ds.t.caption),
                  if (event.lateLabel.isNotEmpty)
                    Text(
                      event.lateLabel,
                      style: Ds.t.caption.copyWith(
                        color: TimelineTone.fg(event.tone),
                      ),
                    ),
                ],
              ),
            ],
          ),
          if (event.action.has && onAct != null) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height:
                  Ds.space.x32 + Ds.space.x16, // 48 - the minimum tap target
              child: OutlinedButton(
                onPressed: busy ? null : onAct,
                style: OutlinedButton.styleFrom(
                  foregroundColor: TimelineTone.fg(event.action.tone),
                  side: BorderSide(color: TimelineTone.fg(event.action.tone)),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rChip),
                ),
                child: Text(event.action.label),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The rider picker. The list, its title and its "nobody is free" sentence are
/// all the backend's — this dialog only returns the row that was tapped.
class _ChoiceDialog extends StatelessWidget {
  final TimelineActionResult result;

  const _ChoiceDialog({required this.result});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
      title: Text(result.title, style: Ds.t.subtitle),
      content: result.choices.isEmpty
          ? Text(result.message, style: Ds.t.caption)
          : SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in result.choices)
                    ListTile(
                      minVerticalPadding: Ds.space.x12,
                      title: Text(
                        c['label']?.toString() ?? '',
                        style: Ds.t.body,
                      ),
                      onTap: () => Navigator.of(context).pop(c),
                    ),
                ],
              ),
            ),
    );
  }
}
