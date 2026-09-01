// CHANGE #400 (2/3) — the settlement acknowledgement card.
//
// ONE widget, rendered on BOTH statements. The partner's copy and the admin's
// copy of the same period can therefore never drift: the backend's
// _stl_ack_block() decides the heading, the state label, its tone, and which
// actions exist. `can_act` is only ever true for the partner who owns the
// period; `can_resolve` is only ever true for an admin looking at a dispute.
//
// The freeze is a FLAG the payout path reads (settlement_settle refuses a
// disputed period in AUTOMATIC route mode) — this card never deducts, hides or
// recomputes a rupee. It prints what it was sent.

import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import 'partner_ui.dart';

class SettlementAckCard extends StatelessWidget {
  const SettlementAckCard({
    super.key,
    required this.ack,
    this.onAgree,
    this.onDispute,
    this.onResolve,
  });

  /// The payload's `ack` block. An empty map renders nothing at all — a build
  /// that predates the backend block must not draw an empty shell.
  final Map<String, dynamic> ack;

  /// Supplied only where the action is possible; the card still obeys the
  /// payload's own can_act / can_resolve before drawing a button.
  final void Function(String note)? onAgree;
  final void Function(String note)? onDispute;
  final VoidCallback? onResolve;

  String _s(Object? v) => v == null ? '' : v.toString();

  Future<void> _disputeSheet(BuildContext context) async {
    final ctrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_s(ack['dispute_label']), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              decoration:
                  InputDecoration(hintText: _s(ack['note_hint'])),
            ),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(_s(ack['dispute_label'])),
              ),
            ),
          ],
        ),
      ),
    );
    if (ok == true) onDispute?.call(ctrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    if (ack.isEmpty) return const SizedBox.shrink();
    final canAct = ack['can_act'] == true;
    final canResolve = ack['can_resolve'] == true;
    final note = _s(ack['note']);
    final byLabel = _s(ack['by_label']);
    final frozenText = _s(ack['frozen_text']);
    final hint = _s(ack['hint']);

    return PartnerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_s(ack['heading']), style: Ds.t.subtitle),
              ),
              PartnerChip(
                text: _s(ack['state_label']),
                tone: _s(ack['state_tone']),
              ),
            ],
          ),
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(hint, style: Ds.t.caption),
          ],
          if (byLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(byLabel, style: Ds.t.caption),
          ],
          if (note.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(note, style: Ds.t.body),
          ],
          if (frozenText.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(frozenText,
                style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          if (canAct && (onAgree != null || onDispute != null)) ...[
            SizedBox(height: Ds.space.x16),
            Row(
              children: [
                if (onAgree != null)
                  Expanded(
                    child: SizedBox(
                      height: Ds.touch.minTarget,
                      child: FilledButton(
                        onPressed: () => onAgree!(''),
                        child: Text(_s(ack['agree_label'])),
                      ),
                    ),
                  ),
                if (onAgree != null && onDispute != null)
                  SizedBox(width: Ds.space.x12),
                if (onDispute != null)
                  Expanded(
                    child: SizedBox(
                      height: Ds.touch.minTarget,
                      child: OutlinedButton(
                        onPressed: () => _disputeSheet(context),
                        child: Text(_s(ack['dispute_label'])),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (canResolve && onResolve != null) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: onResolve,
                child: Text(_s(ack['resolve_label'])),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
