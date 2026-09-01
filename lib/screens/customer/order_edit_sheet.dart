// CHANGE #408 — editing an order in the window between placing it and the
// inquiry engine asking anybody.
//
// The window is the BACKEND's answer, never a status string this sheet
// interprets: `order_edit_state()` returns `can_edit`, and when it is false it
// also returns the reason and the sentence to show. The moment the waterfall
// starts, `can_edit` goes false and the affordance disappears — and the write
// is refused too, so hiding the button is a courtesy, not the guard.
//
// The whole basket is sent on save. Add, remove and change-quantity are
// therefore one call and one transaction on the server, which is what makes
// the rewrite atomic.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import 'customer_staff_screen.dart' show CustomerRpc, custRows, custStr, custTone;

/// One editable line. `productId` and `quantity` are all the server is sent —
/// the name and price come back from the catalogue, never from here.
class OrderEditLine {
  final int productId;
  final String name;
  int quantity;
  OrderEditLine({required this.productId, required this.name, required this.quantity});
}

/// The button the orders screen draws. It renders NOTHING unless the backend
/// said the window is open, and its label is the backend's.
class OrderEditButton extends StatelessWidget {
  final Map<String, dynamic> state;
  final VoidCallback onTap;
  const OrderEditButton({super.key, required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (state['can_edit'] != true) return const SizedBox.shrink();
    final label = custStr(state, 'button_label');
    if (label.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c408_order_edit_button', 1);

    return SizedBox(
      height: Ds.touch.minTarget,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Ds.c.brand),
          foregroundColor: Ds.c.brand,
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
        ),
        onPressed: onTap,
        child: Text(label),
      ),
    );
  }
}

/// The pure view. Hand it a payload and the lines being edited; it draws them.
class OrderEditView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final List<OrderEditLine> lines;
  final void Function(OrderEditLine line, int quantity) onQty;
  final void Function(OrderEditLine line) onRemove;
  final VoidCallback onSave;
  final VoidCallback onAddTap;
  final bool busy;

  const OrderEditView({
    super.key,
    required this.payload,
    required this.lines,
    required this.onQty,
    required this.onRemove,
    required this.onSave,
    required this.onAddTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c408_order_edit_sheet', lines.length);
    return Padding(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(custStr(payload, 'title'), style: Ds.t.title),
          SizedBox(height: Ds.space.x4),
          Text(custStr(payload, 'subtitle'), style: Ds.t.caption),
          if (custStr(payload, 'window_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            _Pill(text: custStr(payload, 'window_label')),
          ],
          SizedBox(height: Ds.space.x24),
          if (lines.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
              child: Text(custStr(payload, 'empty_message'), style: Ds.t.caption),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: lines.length,
                separatorBuilder: (_, _) =>
                    Divider(color: Ds.c.divider, height: Ds.space.x24),
                itemBuilder: (_, i) => _LineRow(
                  line: lines[i],
                  qtyLabel: custStr(payload, 'qty_label'),
                  removeLabel: custStr(payload, 'remove_label'),
                  onQty: (q) => onQty(lines[i], q),
                  onRemove: () => onRemove(lines[i]),
                ),
              ),
            ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Ds.c.divider),
                foregroundColor: Ds.c.text,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: busy ? null : onAddTap,
              child: Text(custStr(payload, 'add_label')),
            ),
          ),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: busy || lines.isEmpty ? null : onSave,
              child: Text(custStr(payload, 'save_label')),
            ),
          ),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  final OrderEditLine line;
  final String qtyLabel;
  final String removeLabel;
  final ValueChanged<int> onQty;
  final VoidCallback onRemove;

  const _LineRow({
    required this.line,
    required this.qtyLabel,
    required this.removeLabel,
    required this.onQty,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Text(line.name, style: Ds.t.body)),
          SizedBox(width: Ds.space.x12),
          _Stepper(quantity: line.quantity, label: qtyLabel, onChanged: onQty),
          SizedBox(width: Ds.space.x8),
          IconButton(
            tooltip: removeLabel,
            onPressed: onRemove,
            icon: Icon(Icons.delete_outline, color: Ds.c.danger),
            constraints: BoxConstraints(
                minWidth: Ds.touch.minTarget, minHeight: Ds.touch.minTarget),
          ),
        ],
      );
}

class _Stepper extends StatelessWidget {
  final int quantity;
  final String label;
  final ValueChanged<int> onChanged;
  const _Stepper(
      {required this.quantity, required this.label, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Ds.c.bg,
          borderRadius: Ds.r.rButton,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Tap(
              icon: Icons.remove,
              // 1 is the floor: emptying a line is Remove, and emptying the
              // whole basket is a cancellation, which is a different feature.
              onTap: quantity > 1 ? () => onChanged(quantity - 1) : null,
            ),
            SizedBox(
              width: Ds.space.x32,
              child: Text('$quantity',
                  textAlign: TextAlign.center, style: Ds.t.bodyStrong),
            ),
            _Tap(icon: Icons.add, onTap: () => onChanged(quantity + 1)),
          ],
        ),
      );
}

class _Tap extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _Tap({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: SizedBox(
          width: Ds.touch.minTarget,
          height: Ds.touch.minTarget,
          child: Icon(icon,
              size: Ds.space.x16,
              color: onTap == null ? Ds.c.textSecondary : Ds.c.text),
        ),
      );
}

class _Pill extends StatelessWidget {
  final String text;
  const _Pill({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration:
            BoxDecoration(color: Ds.c.successSoft, borderRadius: Ds.r.rChip),
        child: Text(text,
            style: Ds.t.caption.copyWith(color: Ds.c.success)),
      );
}

// ── the live sheet ──────────────────────────────────────────────────────────

/// Opens the edit sheet for [orderId]. Returns true when anything was saved,
/// so the caller can refetch. Never opens when the backend says the window is
/// shut — that decision is made before the sheet is built.
Future<bool> showOrderEditSheet(
  BuildContext context,
  String orderId, {
  CustomerRpc? rpc,
}) async {
  Future<Map<String, dynamic>> call(String fn, Map<String, dynamic> p) async {
    if (rpc != null) return rpc(fn, p);
    final raw = await Supabase.instance.client.rpc(fn, params: p);
    return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  }

  final state = await call('order_edit_state', {'p_order_id': orderId});
  if (!context.mounted) return false;
  if (state['can_edit'] != true) {
    final msg = custStr(state, 'message');
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
    return false;
  }

  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (_) => _OrderEditSheet(state: state, orderId: orderId, call: call),
  );
  return saved == true;
}

class _OrderEditSheet extends StatefulWidget {
  final Map<String, dynamic> state;
  final String orderId;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call;
  const _OrderEditSheet(
      {required this.state, required this.orderId, required this.call});

  @override
  State<_OrderEditSheet> createState() => _OrderEditSheetState();
}

class _OrderEditSheetState extends State<_OrderEditSheet> {
  late List<OrderEditLine> _lines;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _lines = [
      for (final r in custRows(widget.state['lines']))
        OrderEditLine(
          productId: int.tryParse(custStr(r, 'product_id')) ?? 0,
          name: custStr(r, 'product_name'),
          quantity: int.tryParse(custStr(r, 'quantity')) ?? 1,
        ),
    ];
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final r = await widget.call('order_edit_apply', {
      'p_order_id': widget.orderId,
      'p_lines': [
        for (final l in _lines)
          {'product_id': l.productId, 'quantity': l.quantity}
      ],
    });
    if (!mounted) return;
    setState(() => _busy = false);
    final msg = custStr(r, 'message');
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: custTone(r['tone']),
      ));
    }
    if (r['ok'] == true) Navigator.of(context).pop(true);
  }

  Future<void> _add() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      builder: (_) => _AddItemSheet(
          hint: custStr(widget.state, 'search_hint'), call: widget.call),
    );
    if (picked == null || !mounted) return;
    final pid = int.tryParse((picked['id'] ?? '').toString()) ?? 0;
    if (pid == 0) return;
    setState(() {
      final at = _lines.indexWhere((l) => l.productId == pid);
      if (at >= 0) {
        _lines[at].quantity += 1;
      } else {
        _lines.add(OrderEditLine(
            productId: pid,
            name: (picked['product_name'] ?? '').toString(),
            quantity: 1));
      }
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: OrderEditView(
          payload: widget.state,
          lines: _lines,
          busy: _busy,
          onQty: (l, q) => setState(() => l.quantity = q),
          onRemove: (l) => setState(() => _lines.remove(l)),
          onAddTap: _add,
          onSave: _save,
        ),
      );
}

/// Search-and-pick, on the same RPC the bulk upload screen already uses.
class _AddItemSheet extends StatefulWidget {
  final String hint;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call;
  const _AddItemSheet({required this.hint, required this.call});

  @override
  State<_AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends State<_AddItemSheet> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _rows = const [];
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String term) async {
    if (term.trim().length < 2) {
      setState(() => _rows = const []);
      return;
    }
    setState(() => _busy = true);
    final r = await widget.call(
        'medicine_search_available', {'p_term': term, 'p_limit': 20});
    if (!mounted) return;
    setState(() {
      _busy = false;
      _rows = custRows(r['rows']);
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _ctrl,
                autofocus: true,
                style: Ds.t.body,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: Ds.t.caption,
                  filled: true,
                  fillColor: Ds.c.bg,
                  border: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.divider),
                  ),
                ),
                onChanged: _search,
              ),
              SizedBox(height: Ds.space.x12),
              if (_busy)
                Padding(
                  padding: EdgeInsets.all(Ds.space.x24),
                  child: const CircularProgressIndicator(),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _rows.length,
                    separatorBuilder: (_, _) =>
                        Divider(color: Ds.c.divider, height: Ds.space.x4),
                    itemBuilder: (_, i) => ListTile(
                      title: Text(custStr(_rows[i], 'product_name'),
                          style: Ds.t.body),
                      onTap: () => Navigator.of(context).pop(_rows[i]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}
