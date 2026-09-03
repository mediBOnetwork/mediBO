import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../screens/orders/order_hold_sheet.dart';
import 'delivery_proof_card.dart';

/// CHANGE #630 — the customer's Orders tab, in the pieces that hold a contract.
///
/// The tab used to be a control panel per row: a five-chip strip that ran off
/// the right edge of a 360 px phone, an Edit button, an actions row, a help box
/// and a Reorder button on every card, cancelled orders included. Part A of
/// this change is one rule — ONE CARD, ONE TRUTH, ONE THING TO TAP — and the
/// only way that rule survives the next feature is if the card is incapable of
/// computing anything.
///
/// So everything in this file is a renderer. There is no money formatting, no
/// pluralising, no status mapping, no stage inference and no choice of which
/// action an order deserves. Every one of those arrives as a finished string
/// or a plain fact from `my_orders_screen_v2()` / `customer_order_detail()`.

/// One row of `my_orders_screen_v2().orders[]`.
class CustomerOrderCard {
  final String id;
  final String orderCode;
  final String dateLabel;
  final String itemCountLabel;

  /// PART A3 — the money, ALREADY WORDED. `₹0.00` used to print as a price and
  /// read like a bug. Zero is never a price here: on a live order it means the
  /// rate is not fixed yet ("Rate on confirmation"), and on a finished one it
  /// means no bill was raised ("Not billed"). Two facts, two sentences, and
  /// neither of them chosen on this side of the wire.
  final String amountLabel;

  /// Whether that string is a rupee amount — a fact from the payload, NOT a
  /// test on the string. The card only uses it to pick a weight.
  final bool amountIsMoney;

  /// PART A3/A7 — the real stage in plain words, and the four-step line the
  /// sentence sits on. The nine internal states are the warehouse's vocabulary;
  /// the compression to four happened server-side.
  final String stageKey;
  final String stageLabel;
  final bool progressShow;
  final List<Map<String, dynamic>> progressSteps;

  /// PART A4 — the ONE action, named by the backend from the order's
  /// situation. `situation` is carried purely so a misroute is visible in the
  /// render-log; nothing renders it.
  final String actionKey;
  final String actionLabel;
  final String actionTone;
  final String situation;

  final bool placedByAdmin;
  final String placedByAdminLabel;

  /// CHANGE #691 (register row 122) — the arrival window, already worded
  /// ("Arriving 4:10–4:30 pm"). Absent (`has:false`) on every order that is not
  /// on a rider's van right now, which is the only reason this card ever hides
  /// it. There is no clock arithmetic on this side of the wire.
  final Map<String, dynamic> eta;

  /// CHANGE #708 — the hold, exactly as `order_hold_state()` sent it. `held`
  /// is the fact; `badge` is the sentence (it already carries the reason, or
  /// the date it resumes). The card never decides which of those to print and
  /// never words either of them. Absent block = no hold, no badge, no chip.
  final Map<String, dynamic> hold;

  /// `order_hold_sheet()`, carried on the row so the card knows whether Hold
  /// is even offerable here — the stage gate is the BACKEND's, and a chip that
  /// opens onto a refusal is worse than no chip.
  final Map<String, dynamic> holdSheet;

  const CustomerOrderCard({
    required this.id,
    required this.orderCode,
    required this.dateLabel,
    required this.itemCountLabel,
    required this.amountLabel,
    required this.amountIsMoney,
    required this.stageKey,
    required this.stageLabel,
    required this.progressShow,
    required this.progressSteps,
    required this.actionKey,
    required this.actionLabel,
    required this.actionTone,
    required this.situation,
    required this.placedByAdmin,
    required this.placedByAdminLabel,
    this.eta = const {},
    this.hold = const {},
    this.holdSheet = const {},
  });

  factory CustomerOrderCard.fromPayload(Map<String, dynamic> row) {
    final prog = (row['progress'] as Map?)?.cast<String, dynamic>() ?? const {};
    final act =
        (row['primary_action'] as Map?)?.cast<String, dynamic>() ?? const {};
    return CustomerOrderCard(
      id: (row['id'] ?? '').toString(),
      orderCode: (row['order_code'] ?? '').toString(),
      dateLabel: (row['date_label'] ?? '').toString(),
      itemCountLabel: (row['item_count_label'] ?? '').toString(),
      amountLabel: (row['amount_label'] ?? '').toString(),
      amountIsMoney: row['amount_is_money'] == true,
      stageKey: (row['stage_key'] ?? '').toString(),
      stageLabel: (row['stage_label'] ?? '').toString(),
      // The progress line shows when the BACKEND says so — never because the
      // steps array happens to be non-empty.
      progressShow: prog['show'] == true,
      progressSteps: ((prog['steps'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList(),
      actionKey: (act['key'] ?? '').toString(),
      actionLabel: (act['label'] ?? '').toString(),
      actionTone: (act['tone'] ?? '').toString(),
      situation: (row['situation'] ?? '').toString(),
      placedByAdmin: row['placed_by_admin'] == true,
      placedByAdminLabel: (row['placed_by_admin_label'] ?? '').toString(),
      eta: row['eta'] is Map
          ? Map<String, dynamic>.from(row['eta'] as Map)
          : const {},
      hold: row['hold'] is Map
          ? Map<String, dynamic>.from(row['hold'] as Map)
          : const {},
      holdSheet: row['hold_sheet'] is Map
          ? Map<String, dynamic>.from(row['hold_sheet'] as Map)
          : const {},
    );
  }
}

/// PART B — the change window, exactly as `customer_order_detail()` sent it.
///
/// Om's rule: a customer may edit or cancel ONLY while the order has not
/// entered sourcing. The window closes the moment the inquiry starts, and when
/// order hours close. The decision is `_order_change_gate()`'s and the actions
/// are ABSENT when it is shut — there is no disabled button here to tap and be
/// refused by, and no Dart branch that could disagree with the server.
class OrderChangeWindow {
  /// Verbatim from the payload. Deliberately NOT re-derived from the order's
  /// status: if the backend says the window is open on an order this build
  /// would have guessed was closed, the backend is right.
  final bool open;

  /// The backend's own sentence for why it is shut ("Sourcing has started —
  /// contact support to change this order"). Empty while it is open.
  final String note;

  /// Every door this buyer has, in payload order, with the payload's labels.
  /// A shut window sends none.
  final List<Map<String, dynamic>> actions;

  const OrderChangeWindow(
      {required this.open, required this.note, required this.actions});

  factory OrderChangeWindow.fromDetail(Map<String, dynamic> payload) {
    final gate =
        (payload['change_window'] as Map?)?.cast<String, dynamic>() ?? const {};
    return OrderChangeWindow(
      open: gate['open'] == true,
      note: (payload['window_note'] ?? '').toString(),
      actions: ((payload['actions'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((a) => Map<String, dynamic>.from(a))
          .toList(),
    );
  }
}

/// PART A3/A4 — the card. Code and date, how many, how much (or the honest
/// sentence in place of it), where it actually is, and one button.
class OrderCardLean extends StatelessWidget {
  final CustomerOrderCard card;

  /// Tapping the card body opens the order. Everything that used to be a chip
  /// on this row lives in there.
  final VoidCallback onOpen;

  /// The primary action was tapped; the caller routes the backend's key.
  final ValueChanged<String> onAction;

  /// CHANGE #708 — the hold door was tapped. Defaults to opening the shared
  /// sheet, so the affordance works on every surface this card is used on
  /// without each of them wiring a router case.
  final ValueChanged<String>? onHoldTap;

  const OrderCardLean(
      {super.key,
      required this.card,
      required this.onOpen,
      required this.onAction,
      this.onHoldTap});

  void _openHold(BuildContext context, String orderId) {
    final tap = onHoldTap;
    if (tap != null) {
      tap(orderId);
      return;
    }
    showOrderHoldSheet(context, orderId);
  }

  /// The word on the hold door, always the backend's. Empty when there is no
  /// door: not held, and not holdable at this stage.
  static String _holdDoorLabel(CustomerOrderCard c) {
    final sheet = c.holdSheet;
    if (c.hold['held'] == true) {
      return (sheet['resume_submit_label'] ?? '').toString();
    }
    if (sheet['can_hold'] == true) return (sheet['title'] ?? '').toString();
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final outline = card.actionTone != 'brand';
    return Material(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
      child: InkWell(
        borderRadius: Ds.r.rCard,
        onTap: onOpen,
        child: Ink(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1,
          ),
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(card.orderCode,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.subtitle),
                  ),
                  SizedBox(width: Ds.space.x8),
                  Text(card.dateLabel, style: Ds.t.caption),
                ],
              ),
              SizedBox(height: Ds.space.x4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                      child: Text(card.itemCountLabel, style: Ds.t.caption)),
                  SizedBox(width: Ds.space.x8),
                  Flexible(
                    child: Text(
                      card.amountLabel,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          card.amountIsMoney ? Ds.t.bodyStrong : Ds.t.caption,
                    ),
                  ),
                ],
              ),
              // CHANGE #708 — parked. The badge is the payload's own sentence
              // and it sits ABOVE the stage word, because "on hold" is the
              // more important truth: the stage is where it will carry on
              // from, not where it is going next.
              if (card.hold['held'] == true) ...[
                SizedBox(height: Ds.space.x12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _HoldBadge(text: (card.hold['badge'] ?? '').toString()),
                ),
              ],
              SizedBox(height: Ds.space.x12),
              Text(card.stageLabel, style: Ds.t.body),
              // CHANGE #691 (register row 122) — the stage word said "Out for
              // delivery" and stopped there. The window sits under it, and only
              // when the backend sent one.
              if (card.eta['has'] == true) ...[
                SizedBox(height: Ds.space.x8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DeliveryEtaLine(eta: card.eta),
                ),
              ],
              if (card.placedByAdmin && card.placedByAdminLabel.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(card.placedByAdminLabel,
                    style: Ds.t.caption.copyWith(color: Ds.c.warning)),
              ],
              if (card.progressShow && card.progressSteps.isNotEmpty) ...[
                SizedBox(height: Ds.space.x12),
                OrderProgressLine(steps: card.progressSteps),
              ],
              // CHANGE #708 — the hold door. It appears only when the BACKEND
              // says this order may be held (the stage gate) or is already
              // held; there is no disabled button here to tap and be refused
              // by. Tapping opens the one sheet both roles share.
              if (_holdDoorLabel(card).isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _openHold(context, card.id),
                    style: TextButton.styleFrom(
                      foregroundColor: card.hold['held'] == true
                          ? Ds.c.brand
                          : Ds.c.textSecondary,
                      minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
                    ),
                    child: Text(_holdDoorLabel(card)),
                  ),
                ),
              ],
              // ONE action. An order with no action sent renders no button at
              // all rather than falling back to a word written here.
              if (card.actionLabel.isNotEmpty) ...[
                SizedBox(height: Ds.space.x16),
                SizedBox(
                  width: double.infinity,
                  height: Ds.touch.minTarget,
                  child: outline
                      ? OutlinedButton(
                          onPressed: () => onAction(card.actionKey),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Ds.c.brand,
                            side: BorderSide(color: Ds.c.brand),
                            shape: RoundedRectangleBorder(
                                borderRadius: Ds.r.rButton),
                          ),
                          child: Text(card.actionLabel),
                        )
                      : FilledButton(
                          onPressed: () => onAction(card.actionKey),
                          style: FilledButton.styleFrom(
                            backgroundColor: Ds.c.brand,
                            shape: RoundedRectangleBorder(
                                borderRadius: Ds.r.rButton),
                          ),
                          child: Text(card.actionLabel),
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// PART A7 — the four steps a pharmacy understands. Which four, what they are
/// called and which one this order is on all arrive in the payload; this draws
/// dots and joins them, in payload order.
class OrderProgressLine extends StatelessWidget {
  final List<Map<String, dynamic>> steps;
  const OrderProgressLine({super.key, required this.steps});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StepDot(state: (steps[i]['state'] ?? '').toString()),
                    if (i < steps.length - 1)
                      Expanded(
                        child: Container(
                          height: 1,
                          color: (steps[i]['state'] ?? '') == 'done'
                              ? Ds.c.brand
                              : Ds.c.divider,
                        ),
                      ),
                  ],
                ),
                SizedBox(height: Ds.space.x4),
                Padding(
                  padding: EdgeInsets.only(right: Ds.space.x4),
                  child: Text(
                    (steps[i]['label'] ?? '').toString(),
                    maxLines: 2,
                    style: (steps[i]['state'] ?? '') == 'current'
                        ? Ds.t.caption.copyWith(color: Ds.c.brand)
                        : Ds.t.caption,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StepDot extends StatelessWidget {
  final String state;
  const _StepDot({required this.state});

  @override
  Widget build(BuildContext context) {
    final done = state == 'done';
    final current = state == 'current';
    return Container(
      width: Ds.space.x12,
      height: Ds.space.x12,
      margin: EdgeInsets.only(right: Ds.space.x4),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done || current ? Ds.c.brand : Ds.c.divider,
        border: current ? Border.all(color: Ds.c.brand, width: 2) : null,
      ),
    );
  }
}

/// PART A2 / A5 — one chip, used by the list's filter row and by the order
/// detail's tab strip. The label and (for filters) the count are the payload's;
/// this never pluralises, never abbreviates and never sorts.
class OrdersFilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  const OrdersFilterChip(
      {super.key,
      required this.label,
      required this.count,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        decoration: BoxDecoration(
          color: selected ? Ds.c.brand : Ds.c.bg,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
        ),
        child: Text(
          count > 0 ? '$label ($count)' : label,
          style:
              Ds.t.bodyStrong.copyWith(color: selected ? Ds.c.surface : Ds.c.text),
        ),
      ),
    );
  }
}

/// CHANGE #708 — the parked badge. One sentence, the payload's own, in the
/// warning tone every held surface uses. It computes nothing: no date
/// arithmetic, no reason mapping, no plural.
class _HoldBadge extends StatelessWidget {
  final String text;
  const _HoldBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: Ds.c.warningSoft,
        borderRadius: Ds.r.rChip,
      ),
      child: Text(text, style: Ds.t.caption.copyWith(color: Ds.c.warning)),
    );
  }
}
