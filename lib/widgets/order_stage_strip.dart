// lib/widgets/order_stage_strip.dart — CMD #1839
//
// The customer's fifteen stages, in the TWO shapes the Orders tab needs, from
// the ONE payload `_order_stage_engine()` builds:
//
//   • OrderStageStrip — the condensed cumulative dot strip on the order card.
//     Fifteen dots and a connecting line, then one sentence underneath.
//   • OrderStageList  — the full list in the Track popup: every stage, its
//     backend timestamp, and the partial-progress count.
//
// NEITHER widget decides anything. `state` ('done' / 'current' / 'todo') is the
// backend's verdict — no timestamp is compared here, no count is computed here,
// no plural is formed here. "Packing 14 of 15" arrives as one finished string
// in `count_label`, and the strip's caption arrives as `caption`. A stage the
// backend did not send is not drawn, which is how a website order simply has no
// Lead dot rather than a permanently grey one.
//
// No supplier is named because no supplier is ever sent: the engine's payload
// has no supplier field at all.

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// One stage as the engine sent it. Every getter is a read, never a decision.
class OrderStage {
  final Map<String, dynamic> raw;
  const OrderStage(this.raw);

  String get key => (raw['key'] ?? '').toString();
  String get label => (raw['label'] ?? '').toString();
  String get state => (raw['state'] ?? '').toString();
  bool get isDone => state == 'done';
  bool get isCurrent => state == 'current';
  String get tsLabel => (raw['ts_label'] ?? '').toString();
  /// A stamp is present when the backend SENT one. An empty string is the
  /// explicit absence — never a dash, never an invented time.
  bool get hasTs => tsLabel.isNotEmpty;
  String get countLabel => (raw['count_label'] ?? '').toString();
  bool get hasCount => raw['has_count'] == true && countLabel.isNotEmpty;

  /// A per-stage sentence the backend may attach (the old timeline's
  /// pending-step note). Printed as it arrived, or not at all.
  String get note => (raw['note'] ?? '').toString();

  static List<OrderStage> listFrom(dynamic v) => (v as List?)
          ?.whereType<Map>()
          .map((e) => OrderStage(Map<String, dynamic>.from(e)))
          .toList() ??
      const <OrderStage>[];
}

Color _dotColour(OrderStage s) =>
    (s.isDone || s.isCurrent) ? Ds.c.brand : Ds.c.divider;

/// A single dot: solid green when done, a green hollow ring when current,
/// grey when still ahead.
class OrderStageDot extends StatelessWidget {
  final OrderStage stage;
  final double size;
  const OrderStageDot({super.key, required this.stage, required this.size});

  @override
  Widget build(BuildContext context) {
    final colour = _dotColour(stage);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // A hollow ring is the CURRENT stage; a filled disc is a finished one.
        color: stage.isCurrent ? Ds.c.surface : colour,
        border: Border.all(
            color: colour, width: stage.isCurrent ? 2 : 1),
      ),
    );
  }
}

/// The condensed strip on the order card. Dots only — the label underneath is
/// the backend's `caption`, which already carries "Packing 14 of 15" when the
/// stage is mixed and the plain stage name when it is not.
class OrderStageStrip extends StatelessWidget {
  final List<OrderStage> stages;
  final String caption;
  final String note;
  const OrderStageStrip({
    super.key,
    required this.stages,
    this.caption = '',
    this.note = '',
  });

  @override
  Widget build(BuildContext context) {
    if (stages.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // LayoutBuilder rather than a fixed width: fifteen dots have to sit on
        // a 360 px phone and on a 1280 px desktop without squeezing.
        LayoutBuilder(builder: (context, c) {
          final dot = c.maxWidth / (stages.length * 2.6) < Ds.space.x8
              ? Ds.space.x8
              : Ds.space.x12;
          return Row(
            children: [
              for (var i = 0; i < stages.length; i++) ...[
                OrderStageDot(stage: stages[i], size: dot),
                if (i < stages.length - 1)
                  Expanded(
                    child: Container(
                      height: 1,
                      margin: EdgeInsets.symmetric(horizontal: Ds.space.x4),
                      color: stages[i].isDone ? Ds.c.brand : Ds.c.divider,
                    ),
                  ),
              ],
            ],
          );
        }),
        if (caption.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(caption, style: Ds.t.caption.copyWith(color: Ds.c.brand)),
        ],
        if (note.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(note, style: Ds.t.caption),
        ],
      ],
    );
  }
}

/// The Track popup's full list: every stage the backend sent, in payload order,
/// with its own timestamp and — on the stage the order is actually on — the
/// partial-progress count.
class OrderStageList extends StatelessWidget {
  final List<OrderStage> stages;
  final String note;
  const OrderStageList({super.key, required this.stages, this.note = ''});

  @override
  Widget build(BuildContext context) {
    if (stages.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < stages.length; i++)
          _StageRow(
            stage: stages[i],
            last: i == stages.length - 1,
            note: stages[i].isCurrent ? note : '',
          ),
      ],
    );
  }
}

class _StageRow extends StatelessWidget {
  final OrderStage stage;
  final bool last;
  final String note;
  const _StageRow({required this.stage, required this.last, this.note = ''});

  @override
  Widget build(BuildContext context) {
    final colour = _dotColour(stage);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(children: [
          OrderStageDot(stage: stage, size: Ds.space.x12),
          if (!last)
            Expanded(
              child: Container(width: 2, color: colour),
            ),
        ]),
        SizedBox(width: Ds.space.x12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : Ds.space.x16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stage.label,
                  style: stage.isCurrent
                      ? Ds.t.bodyStrong.copyWith(color: Ds.c.brand)
                      : Ds.t.body.copyWith(
                          color: stage.isDone ? Ds.c.text : Ds.c.textSecondary),
                ),
                // The count sentence is the backend's, printed as it arrived.
                if (stage.hasCount) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(stage.countLabel,
                      style: Ds.t.caption.copyWith(color: Ds.c.brand)),
                ],
                if (stage.hasTs) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(stage.tsLabel, style: Ds.t.caption),
                ],
                if (stage.note.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(stage.note, style: Ds.t.caption),
                ],
                if (note.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(note, style: Ds.t.caption),
                ],
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
