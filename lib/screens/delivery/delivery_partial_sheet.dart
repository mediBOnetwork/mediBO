// lib/screens/delivery/delivery_partial_sheet.dart — CMD #454 (feature_gaps #101)
//
// "A partial delivery records two numbers on the parcel and returns nothing to
// stock." delivery_partial wrote delivered_qty / returned_qty — two scalars —
// and closed the stop, so a 12-line order returning 3 strips was stored as
// "9/3" with a free-text note and nothing ever came back to stock or the bill.
//
// This is the surface for the fix: the rider names the LINES that are coming
// back and delivery_partial_lines() routes each one through the returns engine
// (credit) and the stock lot (goods).
//
// The screen decides nothing. Lines arrive in payload order, every label is a
// backend string, and the result message printed after submit is the RPC's own.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';

/// The sheet's ONLY decision, extracted so it can be tested without Supabase:
/// which lines are submitted, and at what quantity.
///
/// The rule the register cares about is here — an untouched line is OMITTED
/// from the payload, never sent as a zero. A zero would read as "the customer
/// kept all of it", which is a claim the rider never made.
class DeliveryPartialSelection {
  final Map<String, int> _returning = <String, int>{};

  int qtyFor(String orderItemId) => _returning[orderItemId] ?? 0;

  bool get isEmpty => _returning.isEmpty;

  /// Moves a line's returned quantity by [delta], clamped to [0, max].
  /// Reaching 0 drops the line entirely, so it goes back to being unanswered.
  void bump(String orderItemId, int max, int delta) {
    final next = (qtyFor(orderItemId) + delta).clamp(0, max);
    if (next == 0) {
      _returning.remove(orderItemId);
    } else {
      _returning[orderItemId] = next;
    }
  }

  /// The `p_lines` argument, answered lines only.
  List<Map<String, Object>> payload() => _returning.entries
      .map((e) => <String, Object>{'order_item_id': e.key, 'qty': e.value})
      .toList();
}

class DeliveryPartialSheet extends StatefulWidget {
  const DeliveryPartialSheet({
    super.key,
    required this.deliveryId,
    required this.lines,
    required this.photoPath,
    this.receiver,
    this.note,
  });

  /// The delivery being partially handed over.
  final String deliveryId;

  /// `[{order_item_id, product_name, quantity, qty_label}]` in payload order.
  final List<Map<String, dynamic>> lines;

  /// The door photo. delivery_partial_lines refuses without one.
  final String photoPath;

  final String? receiver;
  final String? note;

  /// Returns the RPC payload when a return was recorded, null when cancelled.
  static Future<Map<String, dynamic>?> open(
    BuildContext context, {
    required String deliveryId,
    required List<Map<String, dynamic>> lines,
    required String photoPath,
    String? receiver,
    String? note,
  }) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (_) => DeliveryPartialSheet(
        deliveryId: deliveryId,
        lines: lines,
        photoPath: photoPath,
        receiver: receiver,
        note: note,
      ),
    );
  }

  @override
  State<DeliveryPartialSheet> createState() => _DeliveryPartialSheetState();
}

class _DeliveryPartialSheetState extends State<DeliveryPartialSheet> {
  final DeliveryPartialSelection _sel = DeliveryPartialSelection();
  bool _busy = false;
  String _error = '';

  int _max(Map<String, dynamic> line) =>
      (line['quantity'] as num?)?.toInt() ?? 0;

  void _bump(String id, int max, int delta) =>
      setState(() => _sel.bump(id, max, delta));

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final res = await Supabase.instance.client.rpc(
        'delivery_partial_lines',
        params: {
          'p_delivery_id': widget.deliveryId,
          // ANSWERED lines only — an untouched line is omitted, never sent as 0.
          'p_lines': _sel.payload(),
          'p_note': widget.note,
          'p_photo': widget.photoPath,
          'p_receiver': widget.receiver,
        },
      );
      final map = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (map['ok'] == true) {
        if (mounted) Navigator.of(context).pop(map);
        return;
      }
      // The backend's own refusal wording, never a Dart fallback sentence.
      if (mounted) {
        setState(() {
          _error = map['message']?.toString() ?? '';
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = !_sel.isEmpty && !_busy;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(c('delivery.partial_title'), style: Ds.t.title),
          SizedBox(height: Ds.space.x4),
          Text(c('delivery.partial_hint'),
              textAlign: TextAlign.center, style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: widget.lines.length,
              separatorBuilder: (_, _) => Divider(height: 1, color: Ds.c.divider),
              itemBuilder: (_, i) => _LineRow(
                line: widget.lines[i],
                returning: _sel
                    .qtyFor(widget.lines[i]['order_item_id']?.toString() ?? ''),
                onBump: (d) => _bump(
                    widget.lines[i]['order_item_id']?.toString() ?? '',
                    _max(widget.lines[i]),
                    d),
              ),
            ),
          ),
          if (_error.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_error, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.space.x48,
            child: FilledButton(
              onPressed: canSubmit ? _submit : null,
              child: Text(c('delivery.partial_submit')),
            ),
          ),
        ]),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.returning,
    required this.onBump,
  });

  final Map<String, dynamic> line;
  final int returning;
  final void Function(int delta) onBump;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(line['product_name']?.toString() ?? '',
                maxLines: 2, overflow: TextOverflow.ellipsis, style: Ds.t.body),
            // The quantity sentence is the backend's, when it sent one.
            if ((line['qty_label']?.toString() ?? '').isNotEmpty)
              Text(line['qty_label'].toString(), style: Ds.t.caption),
          ]),
        ),
        SizedBox(width: Ds.space.x12),
        _StepButton(icon: Icons.remove, onTap: () => onBump(-1)),
        SizedBox(
          width: Ds.space.x48,
          child: Text('$returning',
              textAlign: TextAlign.center, style: Ds.t.bodyStrong),
        ),
        _StepButton(icon: Icons.add, onTap: () => onBump(1)),
      ]),
    );
  }
}

/// A 44x44 tap target, per the touch rule.
class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: SizedBox(
        width: Ds.space.x48,
        height: Ds.space.x48,
        child: Icon(icon, size: Ds.space.x24, color: Ds.c.brand),
      ),
    );
  }
}
