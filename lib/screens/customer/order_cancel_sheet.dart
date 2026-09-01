// CMD #452 — feature_gaps #130: a customer could not cancel their own order.
//
// The window, the reasons, the confirmation copy and the refusal sentence all
// arrive in `my_order_cancel_sheet()`. This sheet decides ONE thing: which
// reason the buyer tapped. It never reads `order.status` to work out whether
// cancelling is allowed, and it has no fallback wording — a missing string
// renders nothing.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/customer_care_service.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

/// Returns true when the order was actually cancelled, so the caller reloads.
Future<bool> showOrderCancelSheet(BuildContext context, String orderId) async {
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _OrderCancelSheet(orderId: orderId),
  );
  return done == true;
}

class _OrderCancelSheet extends StatefulWidget {
  final String orderId;
  const _OrderCancelSheet({required this.orderId});

  @override
  State<_OrderCancelSheet> createState() => _OrderCancelSheetState();
}

class _OrderCancelSheetState extends State<_OrderCancelSheet> {
  Map<String, dynamic>? _p;
  final _note = TextEditingController();
  String _reason = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await CustomerCare.cancelSheet(widget.orderId);
    if (!mounted) return;
    setState(() => _p = p);
    RenderLog.write('c452_cancel_sheet', p['can_cancel'] == true ? 1 : 0);
  }

  Future<void> _submit() async {
    if (_reason.isEmpty || _busy) return;
    setState(() => _busy = true);
    final res =
        await CustomerCare.cancel(widget.orderId, _reason, _note.text);
    if (!mounted) return;
    setState(() => _busy = false);
    final ok = res['ok'] == true;
    showToast(context, careStr(res, 'message'));
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return _SheetShell(
      child: p == null
          ? const _SheetSkeleton()
          : (p['ok'] != true || p['can_cancel'] != true)
              ? _Refusal(
                  message: careStr(p, 'message').isNotEmpty
                      ? careStr(p, 'message')
                      : careStr(p, 'note'))
              : _form(p),
    );
  }

  Widget _form(Map<String, dynamic> p) {
    final reasons = careRows(p['reasons']);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(careStr(p, 'title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x8),
        Text(careStr(p, 'body'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        Text(careStr(p, 'reason_label'), style: Ds.t.bodyStrong),
        SizedBox(height: Ds.space.x8),
        for (final r in reasons)
          _ReasonRow(
            label: careStr(r, 'label'),
            selected: _reason == careStr(r, 'code'),
            onTap: () => setState(() => _reason = careStr(r, 'code')),
          ),
        SizedBox(height: Ds.space.x16),
        Text(careStr(p, 'note_label'), style: Ds.t.bodyStrong),
        SizedBox(height: Ds.space.x8),
        TextField(
          controller: _note,
          minLines: 2,
          maxLines: 4,
          style: Ds.t.body,
          decoration: InputDecoration(
            filled: true,
            fillColor: Ds.c.bg,
            border: OutlineInputBorder(
                borderRadius: Ds.r.rButton, borderSide: BorderSide.none),
          ),
        ),
        SizedBox(height: Ds.space.x24),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: FilledButton(
            onPressed: (_reason.isEmpty || _busy) ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: Ds.c.danger,
              shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            ),
            child: Text(careStr(p, 'cta')),
          ),
        ),
        SizedBox(height: Ds.space.x8),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(careStr(p, 'keep_cta'),
                style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
          ),
        ),
      ],
    );
  }
}

class _ReasonRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ReasonRow(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rButton,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
        child: Row(children: [
          Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? Ds.c.brand : Ds.c.textSecondary),
          SizedBox(width: Ds.space.x12),
          Expanded(child: Text(label, style: Ds.t.body)),
        ]),
      ),
    );
  }
}

/// The rounded sheet body every customer-care sheet sits in.
class _SheetShell extends StatelessWidget {
  final Widget child;
  const _SheetShell({required this.child});

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.88),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
        ),
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x24),
        child: SingleChildScrollView(child: child),
      ),
    );
  }
}

class _SheetSkeleton extends StatelessWidget {
  const _SheetSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w) => Container(
          width: w,
          height: Ds.space.x16,
          margin: EdgeInsets.only(bottom: Ds.space.x12),
          decoration:
              BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rButton),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [bar(180), bar(260), bar(220), bar(140)],
    );
  }
}

/// The backend's own refusal sentence, with no Dart wording behind it.
class _Refusal extends StatelessWidget {
  final String message;
  const _Refusal({required this.message});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message, style: Ds.t.body),
        SizedBox(height: Ds.space.x16),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton)),
            child: const Icon(Icons.close, size: 18),
          ),
        ),
      ],
    );
  }
}

/// Shared by the help and return sheets so all three look like one surface.
class CareSheetShell extends StatelessWidget {
  final Widget child;
  const CareSheetShell({super.key, required this.child});
  @override
  Widget build(BuildContext context) => _SheetShell(child: child);
}

class CareSheetSkeleton extends StatelessWidget {
  const CareSheetSkeleton({super.key});
  @override
  Widget build(BuildContext context) => const _SheetSkeleton();
}

class CareRefusal extends StatelessWidget {
  final String message;
  const CareRefusal({super.key, required this.message});
  @override
  Widget build(BuildContext context) => _Refusal(message: message);
}

class CareReasonRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const CareReasonRow(
      {super.key,
      required this.label,
      required this.selected,
      required this.onTap});
  @override
  Widget build(BuildContext context) =>
      _ReasonRow(label: label, selected: selected, onTap: onTap);
}
