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
import '../../models/order_timeline_view.dart';
import '../../widgets/delivery_proof_card.dart';
import '../../widgets/order_event_timeline.dart';

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

/// CMD #1845 — a key ALIAS, not a decision: the backend sends the deadline
/// wording under its new name and under the old `sla_*` name, so a browser
/// still holding the previous bundle keeps printing. Nothing is composed here.
String _deadlineText(Map<String, dynamic> m, String preferred, String legacy) {
  final v = _s(m, preferred);
  return v.isNotEmpty ? v : _s(m, legacy);
}

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
              // CMD #1845 — the button is "Stage deadline settings" now. Both
              // keys carry the same backend string; the old one is read second
              // so a payload from before the rename still prints something.
              child: Text(_deadlineText(payload, 'deadline_button', 'sla_button'),
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
                        // CHANGE #708 — a parked order says so on the board,
                        // in the backend's own sentence. Its SLA clock is
                        // already paused server-side, so the two never argue.
                        if ((row['hold'] as Map?)?['held'] == true)
                          _Pill(
                              text: ((row['hold'] as Map?)?['badge'] ?? '')
                                  .toString(),
                              tone: 'amber'),
                        _Pill(text: _s(row, 'clock_label'), tone: tone),
                        // CMD #1845 — "Deadline 12:00 PM" (a clock stage) or
                        // "Deadline 30m" (a duration one), computed and worded
                        // by ops_board().
                        if (_deadlineText(row, 'deadline_label', 'sla_label')
                            .isNotEmpty)
                          Text(_deadlineText(row, 'deadline_label', 'sla_label'),
                              style: Ds.t.caption),
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

  /// CHANGE #689 (feature_gaps #75) — the order_timeline() payload for the SAME
  /// order. The SLA steps above answer "which stage is breaching"; this answers
  /// "what actually happened, who did it, and who do I ring". Absent (the RPC
  /// refused, or nobody has the matrix key) the block simply does not render —
  /// the detail sheet is the ops board's, with or without it.
  final Map<String, dynamic> timeline;

  /// Runs one timeline action. Null on a surface that cannot act.
  final TimelineActRunner? onTimelineAct;

  /// Handed the fresh payload an action returned.
  final void Function(Map<String, dynamic>)? onTimelineRefreshed;

  /// CHANGE #708 — opens the shared hold sheet for this order. Null on a
  /// surface that only reads, and then the hold panel does not render at all.
  final VoidCallback? onHold;

  /// CHANGE #708 — releases the reserved stock, with the reason the panel
  /// collected. Null when the payload says this login may not.
  final Future<void> Function(String reason)? onReleaseStock;

  const OpsOrderDetailView({
    super.key,
    required this.payload,
    this.timeline = const {},
    this.onTimelineAct,
    this.onTimelineRefreshed,
    this.onHold,
    this.onReleaseStock,
  });

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return _Centered(
        title: _s(payload, 'title'),
        message: _s(payload, 'message'),
      );
    }
    final steps = opsRows(payload['steps']);
    final hold = (payload['hold'] as Map?)?.cast<String, dynamic>() ?? const {};
    final holdSheet =
        (payload['hold_sheet'] as Map?)?.cast<String, dynamic>() ?? const {};
    final holdStock =
        (payload['hold_stock'] as Map?)?.cast<String, dynamic>() ?? const {};
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
        // CHANGE #708 — hold, resume, and the stock a parked order is still
        // reserving. Every word here is the payload's; the panel decides only
        // WHERE it sits.
        if (onHold != null && (hold['held'] == true || holdSheet['can_hold'] == true))
          OpsHoldPanel(
            hold: hold,
            sheet: holdSheet,
            stock: holdStock,
            onHold: onHold!,
            onReleaseStock: onReleaseStock,
          ),
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
                if (_deadlineText(st, 'deadline_label', 'sla_label').isNotEmpty)
                  Text(_deadlineText(st, 'deadline_label', 'sla_label'),
                      style: Ds.t.caption),
              ]),
            ]),
          ),
          SizedBox(height: Ds.space.x8),
        ],
        // CHANGE #691 (register row 126) — the ops timeline (#75) ends with the
        // SAME proof block the customer is shown, from the same RPC field, so
        // support is never looking at less than the person they are talking to.
        DeliveryProofCard(
          proof: (payload['proof'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        // CHANGE #689 (feature_gaps #75) — and then the whole story: every
        // event from every table, the actor on each one, and the one-tap
        // action on the step this order is waiting on.
        if (timeline.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          OrderEventTimeline(
            view: OrderTimelineView.from(timeline),
            onAct: onTimelineAct,
            onRefreshed: onTimelineRefreshed,
          ),
        ],
      ]),
    );
  }
}

/// CHANGE #708 — the hold panel on the ops order card.
///
/// Three facts, all of them the payload's: whether this order is parked (and
/// the sentence that says why), the one door — Hold or Resume, labelled by the
/// backend — and the stock the hold is still reserving, with a release that is
/// only offered when the payload says this login may (`can_release`).
///
/// It renders. It does not decide who may act, what the button says, how many
/// units are reserved or how that number reads.
class OpsHoldPanel extends StatefulWidget {
  final Map<String, dynamic> hold;
  final Map<String, dynamic> sheet;
  final Map<String, dynamic> stock;
  final VoidCallback onHold;
  final Future<void> Function(String reason)? onReleaseStock;

  const OpsHoldPanel({
    super.key,
    required this.hold,
    required this.sheet,
    required this.stock,
    required this.onHold,
    this.onReleaseStock,
  });

  @override
  State<OpsHoldPanel> createState() => _OpsHoldPanelState();
}

class _OpsHoldPanelState extends State<OpsHoldPanel> {
  final TextEditingController _reason = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  String _sk(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  Future<void> _release() async {
    final fn = widget.onReleaseStock;
    if (fn == null || _reason.text.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    await fn(_reason.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _reason.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final held = widget.hold['held'] == true;
    final label = held
        ? _sk(widget.sheet, 'resume_submit_label')
        : _sk(widget.sheet, 'title');
    final canRelease =
        widget.stock['can_release'] == true && widget.onReleaseStock != null;

    return Container(
      margin: EdgeInsets.only(top: Ds.space.x16),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: held ? Ds.c.warningSoft : Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (held) ...[
          Text(_sk(widget.hold, 'badge'), style: Ds.t.body),
          if (_sk(widget.hold, 'held_by_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_sk(widget.hold, 'held_by_label'), style: Ds.t.caption),
          ],
          if (_sk(widget.hold, 'note').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_sk(widget.hold, 'note'), style: Ds.t.caption),
          ],
          if (_sk(widget.hold, 'auto_cancel_note').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_sk(widget.hold, 'auto_cancel_note'), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x12),
        ],
        if (label.isNotEmpty)
          SizedBox(
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              onPressed: widget.onHold,
              child: Text(label),
            ),
          ),

        // The stock a parked order is still holding, and the way to hand it
        // back. Absent whenever the payload sent no reserved lines.
        if (widget.stock['has'] == true) ...[
          SizedBox(height: Ds.space.x16),
          Text(_sk(widget.stock, 'heading'), style: Ds.t.body),
          SizedBox(height: Ds.space.x4),
          Text(_sk(widget.stock, 'total_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          for (final line in opsRows(widget.stock['rows']))
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Row(children: [
                Expanded(
                    child: Text((line['line'] ?? '').toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.caption)),
                SizedBox(width: Ds.space.x8),
                Text((line['bag_label'] ?? '').toString(),
                    style: Ds.t.caption),
              ]),
            ),
          if (canRelease) ...[
            SizedBox(height: Ds.space.x8),
            Text(_sk(widget.stock, 'release_note'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            TextField(
              controller: _reason,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                  hintText: _sk(widget.stock, 'release_reason_label')),
            ),
            SizedBox(height: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed:
                    _reason.text.trim().isEmpty || _busy ? null : _release,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.danger,
                  side: BorderSide(color: Ds.c.danger),
                ),
                child: Text(_sk(widget.stock, 'release_label')),
              ),
            ),
          ],
        ],
      ]),
    );
  }
}

/// ── CMD #1845 — the Stage deadlines sheet ─────────────────────────────────
///
/// The pure half of the sheet: given the `ops_sla_config_get()` payload it
/// draws the stage list, the mode switch, the working week and the save
/// button, and it decides nothing. Every word — the title, the mode names, the
/// day names, the "Due 12:00 PM" preview, the save caption and the read-only
/// sentence — is a string the backend sent.
///
/// The two things it cannot do alone are handed back to the host:
///   * [formatTime] — a time the user has just PICKED still has to be worded by
///     the backend (ops_time_label), because a 12-hour string written in Dart
///     is exactly the rule this change exists to enforce.
///   * [onSave] — one RPC, one payload, and the host reports the result.
/// showTimePicker itself stays here: it is Material, not data, and it is forced
/// to 12-hour so a device set to 24-hour cannot smuggle "16:30" onto the screen.
class StageDeadlineSheetView extends StatefulWidget {
  final Map<String, dynamic> config;
  final int? zoneId;

  /// Asks the backend for the 12-hour wording of an hour/minute the user picked.
  final Future<String> Function(int hour, int minute) formatTime;

  /// Sends the sheet back. Returns the RPC's own reply.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> payload)
      onSave;

  const StageDeadlineSheetView({
    super.key,
    required this.config,
    required this.formatTime,
    required this.onSave,
    this.zoneId,
  });

  @override
  State<StageDeadlineSheetView> createState() => _StageDeadlineSheetViewState();
}

class _StageDeadlineSheetViewState extends State<StageDeadlineSheetView> {
  // Per stage: what the sheet currently holds. Seeded from the payload and
  // never recomputed from it again, so a pick survives a rebuild.
  final Map<String, String> _mode = {};
  final Map<String, int?> _hour = {};
  final Map<String, int?> _minute = {};
  final Map<String, String> _timeText = {};
  final Map<String, TextEditingController> _minutesCtrl = {};
  final Set<int> _days = <int>{};

  bool _saving = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    for (final r in opsRows(widget.config['rows'])) {
      final k = _s(r, 'stage_key');
      if (k.isEmpty) continue;
      _mode[k] = _s(r, 'mode').isEmpty ? 'clock' : _s(r, 'mode');
      _hour[k] = (r['due_hour'] as num?)?.toInt();
      _minute[k] = (r['due_minute'] as num?)?.toInt();
      _timeText[k] = _s(r, 'due_time_display');
      _minutesCtrl[k] = TextEditingController(
          text: (r['sla_minutes'] as num?)?.toInt().toString() ?? '');
    }
    final week = widget.config['week'];
    for (final d in opsRows(week is Map ? week['days'] : null)) {
      final n = (d['n'] as num?)?.toInt();
      if (n != null && d['on'] == true) _days.add(n);
    }
  }

  @override
  void dispose() {
    for (final c in _minutesCtrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _canEdit => widget.config['can_edit'] == true;

  Future<void> _pick(String stageKey) async {
    final picked = await showTimePicker(
      context: context,
      initialTime:
          TimeOfDay(hour: _hour[stageKey] ?? 12, minute: _minute[stageKey] ?? 0),
      helpText: _s(widget.config, 'time_picker_title'),
      // 12-hour, always — the app's time format is a product rule, not the
      // device's setting.
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: false),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (picked == null) return;
    final label = await widget.formatTime(picked.hour, picked.minute);
    if (!mounted) return;
    setState(() {
      _hour[stageKey] = picked.hour;
      _minute[stageKey] = picked.minute;
      _timeText[stageKey] = label;
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _message = '';
    });
    final rows = <Map<String, dynamic>>[];
    for (final r in opsRows(widget.config['rows'])) {
      final k = _s(r, 'stage_key');
      if (k.isEmpty) continue;
      rows.add({
        'stage_key': k,
        'mode': _mode[k],
        'due_hour': _hour[k],
        'due_minute': _minute[k],
        'sla_minutes': int.tryParse(_minutesCtrl[k]?.text.trim() ?? ''),
        'amber_pct': r['amber_pct'],
      });
    }
    final res = await widget.onSave({
      'zone_id': widget.zoneId,
      'rows': rows,
      'week_days': (_days.toList()..sort()),
    });
    if (!mounted) return;
    if (res['ok'] == true) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _message = res['message']?.toString() ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final cfg = widget.config;
    final rows = opsRows(cfg['rows']);
    final modes = opsRows(cfg['modes']);
    final week = cfg['week'] is Map
        ? Map<String, dynamic>.from(cfg['week'] as Map)
        : const <String, dynamic>{};
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(
            alignment: Alignment.centerLeft,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_s(cfg, 'title'), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x4),
              Text(
                  [
                    _s(cfg, 'subtitle'),
                    _s(cfg, 'zone_label'),
                    _s(cfg, 'date_label')
                  ].where((e) => e.isNotEmpty).join(' · '),
                  style: Ds.t.caption),
            ]),
          ),
          SizedBox(height: Ds.space.x24),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final r in rows) ...[
                _StageDeadlineRow(
                  row: r,
                  modes: modes,
                  mode: _mode[_s(r, 'stage_key')] ?? 'clock',
                  timeText: _timeText[_s(r, 'stage_key')] ?? '',
                  minutesCtrl: _minutesCtrl[_s(r, 'stage_key')],
                  timeLabel: _s(cfg, 'time_label'),
                  minutesLabel: _s(cfg, 'minutes_label'),
                  enabled: _canEdit && !_saving,
                  onMode: (m) =>
                      setState(() => _mode[_s(r, 'stage_key')] = m),
                  onPickTime: () => _pick(_s(r, 'stage_key')),
                ),
                SizedBox(height: Ds.space.x16),
              ],
              if (week.isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                Text(_s(week, 'title'), style: Ds.t.body),
                SizedBox(height: Ds.space.x4),
                Text(_s(week, 'subtitle'), style: Ds.t.caption),
                SizedBox(height: Ds.space.x12),
                Wrap(
                  spacing: Ds.space.x8,
                  runSpacing: Ds.space.x8,
                  children: [
                    for (final d in opsRows(week['days']))
                      _DayChip(
                        label: _s(d, 'label'),
                        on: _days.contains((d['n'] as num?)?.toInt() ?? -1),
                        enabled: _canEdit && !_saving,
                        onTap: () {
                          final n = (d['n'] as num?)?.toInt();
                          if (n == null) return;
                          setState(() =>
                              _days.contains(n) ? _days.remove(n) : _days.add(n));
                        },
                      ),
                  ],
                ),
              ],
            ]),
          ),
          if (_message.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_message, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: (!_canEdit || _saving) ? null : _save,
              child: Text(_canEdit
                  ? _s(cfg, 'save_label')
                  : _s(cfg, 'readonly_message')),
            ),
          ),
        ]),
      ),
    );
  }
}

/// One stage. The mode buttons come from the payload's `modes`, so a third mode
/// added in SQL appears here with no deploy.
class _StageDeadlineRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> modes;
  final String mode;
  final String timeText;
  final TextEditingController? minutesCtrl;
  final String timeLabel;
  final String minutesLabel;
  final bool enabled;
  final ValueChanged<String> onMode;
  final VoidCallback onPickTime;

  const _StageDeadlineRow({
    required this.row,
    required this.modes,
    required this.mode,
    required this.timeText,
    required this.minutesCtrl,
    required this.timeLabel,
    required this.minutesLabel,
    required this.enabled,
    required this.onMode,
    required this.onPickTime,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_s(row, 'label'), style: Ds.t.body),
      Text(
          [_s(row, 'owner_label'), _s(row, 'source_label'), _s(row, 'preview_label')]
              .where((e) => e.isNotEmpty)
              .join(' · '),
          style: Ds.t.caption),
      SizedBox(height: Ds.space.x8),
      Row(children: [
        Expanded(
          child: Wrap(
            spacing: Ds.space.x8,
            children: [
              for (final m in modes)
                _ModeChip(
                  label: _s(m, 'label'),
                  selected: _s(m, 'key') == mode,
                  enabled: enabled,
                  onTap: () => onMode(_s(m, 'key')),
                ),
            ],
          ),
        ),
        SizedBox(width: Ds.space.x12),
        if (mode == 'duration')
          SizedBox(
            width: Ds.touch.minTarget * 2,
            child: TextField(
              controller: minutesCtrl,
              enabled: enabled,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.right,
              style: Ds.t.body,
              decoration: InputDecoration(
                isDense: true,
                hintText: minutesLabel,
                contentPadding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x8, vertical: Ds.space.x8),
              ),
            ),
          )
        else
          SizedBox(
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              onPressed: enabled ? onPickTime : null,
              child: Text(timeText.isEmpty ? timeLabel : timeText,
                  style: Ds.t.body.copyWith(color: Ds.c.brand)),
            ),
          ),
      ]),
    ]);
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
        decoration: BoxDecoration(
          color: selected ? Ds.c.successSoft : Ds.c.bg,
          borderRadius: Ds.r.rChip,
        ),
        child: Text(label,
            style: Ds.t.caption
                .copyWith(color: selected ? Ds.c.brand : Ds.c.textSecondary)),
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  final String label;
  final bool on;
  final bool enabled;
  final VoidCallback onTap;

  const _DayChip({
    required this.label,
    required this.on,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(
            minHeight: Ds.touch.minTarget, minWidth: Ds.touch.minTarget),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
        decoration: BoxDecoration(
          color: on ? Ds.c.successSoft : Ds.c.bg,
          borderRadius: Ds.r.rChip,
        ),
        child: Text(label,
            style: Ds.t.caption
                .copyWith(color: on ? Ds.c.brand : Ds.c.textSecondary)),
      ),
    );
  }
}
