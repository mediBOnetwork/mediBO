import 'package:flutter/material.dart';

enum DisputeState { needsYou, waiting, resourcing, exchange, resolved }

DisputeState disputeStateOf(Map<String, dynamic> d) {
  final kind = d['kind']?.toString() ?? 'short';
  final status = d['status']?.toString() ?? '';
  final rebuyStarted = d['rebuy_started'] as bool? ?? false;
  if (status == 'resolved') return DisputeState.resolved;
  if (kind == 'short' && status == 'denied' && !rebuyStarted) return DisputeState.needsYou;
  if (status == 'reminder_sent' || status == 'shop_logged') return DisputeState.waiting;
  if (kind == 'short' && status == 'accepted_missing') return DisputeState.resourcing;
  if (kind == 'wrong_item' && status == 'denied') return DisputeState.resourcing;
  if (kind == 'wrong_item' && status == 'accepted_missing') return DisputeState.exchange;
  return DisputeState.waiting;
}

class DisputeView {
  final DisputeState state;
  final Color dot;
  final String label;
  final String subline;

  const DisputeView({
    required this.state,
    required this.dot,
    required this.label,
    required this.subline,
  });

  static DisputeView of(Map<String, dynamic> d) {
    final s = disputeStateOf(d);
    final kind = d['kind']?.toString() ?? 'short';
    final resOutcome = d['resolution_outcome']?.toString() ?? '';
    switch (s) {
      case DisputeState.needsYou:
        return const DisputeView(
          state: DisputeState.needsYou,
          dot: Color(0xFFC0392B),
          label: 'Needs your decision',
          subline: 'Supplier says they supplied it — your call',
        );
      case DisputeState.waiting:
        return const DisputeView(
          state: DisputeState.waiting,
          dot: Color(0xFF6D5BD0),
          label: 'Waiting on supplier',
          subline: 'Reminder sent — no reply yet',
        );
      case DisputeState.resourcing:
        return DisputeView(
          state: DisputeState.resourcing,
          dot: const Color(0xFFB26A00),
          label: 'Being re-sourced',
          subline: kind == 'short'
              ? 'Confirmed missing → re-ordering'
              : 'Out of stock → re-ordering',
        );
      case DisputeState.exchange:
        return const DisputeView(
          state: DisputeState.exchange,
          dot: Color(0xFF1B7A43),
          label: 'Exchange coming',
          subline: 'Supplier sending the correct item',
        );
      case DisputeState.resolved:
        final outcomeText = resOutcome == 'agree_supplier'
            ? 'Agreed with supplier'
            : resOutcome == 're_source'
                ? 'Re-sourced'
                : '';
        return DisputeView(
          state: DisputeState.resolved,
          dot: const Color(0xFF6B7280),
          label: 'Resolved',
          subline: outcomeText.isNotEmpty ? 'Closed · $outcomeText' : 'Closed',
        );
    }
  }
}
