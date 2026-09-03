// lib/screens/admin/ops_board_view.dart — CHANGE #688
//
// The PURE half of the ops board: given the `ops_board()` payload it draws the
// board, and that is all it does. No Supabase, no timers, no platform library —
// which is what lets test/protected/ops_board_test.dart render it on the Dart
// VM with a hand-written payload.
//
// It computes NOTHING. The clock ("35d 9h over"), the SLA ("SLA 1h"), the tone
// word ("Breached"), the owner, the next action, the chip captions and the
// empty state are all strings the backend sent. The ORDER of the rows is the
// payload's order — ops_board() already sorted them red → amber → green, most
// overdue first, and re-sorting here would be a second opinion about which
// order is worst.
//
// The only thing decided in Dart is which token a tone name maps to, and that
// is a lookup on the design layer, not a colour written down.

import 'package:flutter/material.dart';

import '../../design_tokens.dart';

/// Maps the backend's tone word onto the token layer. An unknown tone renders
/// neutral rather than throwing — a new tone from the backend must never white-
/// screen the board.
class OpsTone {
  static Color fg(String? tone) {
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

  static Color bg(String? tone) {
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

List<Map<String, dynamic>> opsRows(dynamic v) => v is List
    ? v.map((e) => Map<String, dynamic>.from(e as Map)).toList()
    : const <Map<String, dynamic>>[];

String _s(Map<String, dynamic> m, String k) => m[k]?.toString() ?? '';

/// The whole board, drawn from one payload.
class OpsBoardView extends StatelessWidget {
  final Map<String, dynamic> payload;

  /// Row tap → the order's stage timeline. Carries the backend's own order_id.
  final ValueChanged<Map<String, dynamic>>? onTapRow;

  /// Only ever shown when the payload says `can_edit_sla`.
  final VoidCallback? onEditSla;

  const OpsBoardView({
    super.key,
    required this.payload,
    this.onTapRow,
    this.onEditSla,
  });

  @override
  Widget build(BuildContext context) {
    // A refusal is the backend's sentence, printed as it came.
    if (payload['ok'] == false) {
      return _Centered(
        title: _s(payload, 'title'),
        message: _s(payload, 'message'),
      );
    }

    final rows = opsRows(payload['rows']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(payload: payload, onEditSla: onEditSla),
        if (rows.isEmpty)
          Expanded(
            child: _Centered(
              title: _s(payload, 'empty_title'),
              message: _s(payload, 'empty_message'),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x24),
              itemCount: rows.length,
              separatorBuilder: (_, _) => SizedBox(height: Ds.space.x12),
              itemBuilder: (_, i) => OpsBoardRow(
                row: rows[i],
                onTap: onTapRow == null ? null : () => onTapRow!(rows[i]),
              ),
            ),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final Map<String, dynamic> payload;
  final VoidCallback? onEditSla;

  const _Header({required this.payload, this.onEditSla});

  @override
  Widget build(BuildContext context) {
    final chips = opsRows(payload['chips']);
    return Container(
      width: double.infinity,
      color: Ds.c.surface,
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_s(payload, 'title'), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x4),
              Text(
                [_s(payload, 'zone_label'), _s(payload, 'updated_label')]
                    .where((e) => e.isNotEmpty)
                    .join(' · '),
                style: Ds.t.caption,
              ),
            ]),
          ),
          // Shown only when the BACKEND says this caller may edit an SLA.
          if (payload['can_edit_sla'] == true && onEditSla != null)
            TextButton(
              onPressed: onEditSla,
              child: Text(_s(payload, 'sla_button'),
                  style: Ds.t.body.copyWith(color: Ds.c.brand)),
            ),
        ]),
        SizedBox(height: Ds.space.x12),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final ch in chips)
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                  color: OpsTone.bg(ch['tone']?.toString()),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(_s(ch, 'label'),
                    style: Ds.t.caption
                        .copyWith(color: OpsTone.fg(ch['tone']?.toString()))),
              ),
          ],
        ),
      ]),
    );
  }
}

/// One order. Everything on it is a backend string.
class OpsBoardRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback? onTap;

  const OpsBoardRow({super.key, required this.row, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tone = row['tone']?.toString();
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rCard,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        // IntrinsicHeight so the tone stripe is exactly as tall as the card:
        // inside a ListView the card's height is unbounded, and a stretched Row
        // in an unbounded box is an infinite-height assertion.
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // The tone stripe — the whole reason the worst row reads as worst
          // from across the room.
          Container(
            width: Ds.space.x4,
            decoration: BoxDecoration(
              color: OpsTone.fg(tone),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(Ds.r.card),
                bottomLeft: Radius.circular(Ds.r.card),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(Ds.space.x16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(_s(row, 'order_code'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Ds.t.body
                                .copyWith(fontWeight: FontWeight.w700)),
                      ),
                      SizedBox(width: Ds.space.x8),
                      Text(_s(row, 'amount_display'),
                          style:
                              Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
                    ]),
                    SizedBox(height: Ds.space.x4),
                    Text(_s(row, 'customer'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.caption),
                    SizedBox(height: Ds.space.x12),
                    Wrap(
                      spacing: Ds.space.x8,
                      runSpacing: Ds.space.x8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _Pill(text: _s(row, 'stage_label'), tone: null),
                        _Pill(text: _s(row, 'clock_label'), tone: tone),
                        if (_s(row, 'sla_label').isNotEmpty)
                          Text(_s(row, 'sla_label'), style: Ds.t.caption),
                        if (_s(row, 'entered_label').isNotEmpty)
                          Text(_s(row, 'entered_label'), style: Ds.t.caption),
                      ],
                    ),
                    SizedBox(height: Ds.space.x8),
                    Row(children: [
                      Expanded(
                        child: Text(_s(row, 'next_action'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Ds.t.caption.copyWith(color: Ds.c.text)),
                      ),
                      SizedBox(width: Ds.space.x8),
                      Text(_s(row, 'owner_label'), style: Ds.t.caption),
                    ]),
                  ]),
            ),
          ),
        ]),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final String? tone;

  const _Pill({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: tone == null ? Ds.c.bg : OpsTone.bg(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(text,
          style: Ds.t.caption.copyWith(
              color: tone == null ? Ds.c.text : OpsTone.fg(tone),
              fontWeight: FontWeight.w600)),
    );
  }
}

class _Centered extends StatelessWidget {
  final String title;
  final String message;

  const _Centered({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (title.isNotEmpty)
            Text(title, textAlign: TextAlign.center, style: Ds.t.subtitle),
          if (message.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(message, textAlign: TextAlign.center, style: Ds.t.caption),
          ],
        ]),
      ),
    );
  }
}

/// The row tap target: one order's stage timeline, drawn from
/// `ops_order_detail()`. Same contract — every label is the payload's.
class OpsOrderDetailView extends StatelessWidget {
  final Map<String, dynamic> payload;

  const OpsOrderDetailView({super.key, required this.payload});

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return _Centered(
        title: _s(payload, 'title'),
        message: _s(payload, 'message'),
      );
    }
    final steps = opsRows(payload['steps']);
    return SingleChildScrollView(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_s(payload, 'order_code'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x4),
        Text(
          [
            _s(payload, 'customer'),
            _s(payload, 'amount_display'),
            _s(payload, 'zone_label'),
          ].where((e) => e.isNotEmpty).join(' · '),
          style: Ds.t.caption,
        ),
        SizedBox(height: Ds.space.x4),
        Text(_s(payload, 'placed_label'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        Text(_s(payload, 'timeline_title'), style: Ds.t.body),
        SizedBox(height: Ds.space.x12),
        for (final st in steps) ...[
          Container(
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: st['is_current'] == true
                  ? OpsTone.bg(st['tone']?.toString())
                  : Ds.c.surface,
              borderRadius: Ds.r.rChip,
            ),
            child: Row(children: [
              Container(
                width: Ds.space.x8,
                height: Ds.space.x8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: st['reached'] == true
                      ? OpsTone.fg(st['tone']?.toString())
                      : Ds.c.divider,
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s(st, 'label'), style: Ds.t.body),
                      if (_s(st, 'entered_label').isNotEmpty)
                        Text(_s(st, 'entered_label'), style: Ds.t.caption),
                    ]),
              ),
              SizedBox(width: Ds.space.x8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                if (_s(st, 'spent_label').isNotEmpty)
                  Text(_s(st, 'spent_label'),
                      style: Ds.t.caption
                          .copyWith(color: OpsTone.fg(st['tone']?.toString()))),
                if (_s(st, 'sla_label').isNotEmpty)
                  Text(_s(st, 'sla_label'), style: Ds.t.caption),
              ]),
            ]),
          ),
          SizedBox(height: Ds.space.x8),
        ],
      ]),
    );
  }
}
