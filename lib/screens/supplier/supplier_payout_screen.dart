// CHANGE #402 — the supplier's own bank / UPI screen.
//
// Payout details used to be typed from memory by whoever recorded a payment.
// This screen submits them ONCE, and what it shows is the backend's state
// machine, not a local guess: `active` is what mediBO pays into today,
// `pending` is waiting for a human at mediBO to approve it, and `history` is
// every set that came before — never overwritten, so an old payment stays
// answerable.
//
// The name check is penny-drop-free: the backend scores the account name
// against the names already on the supplier's profile and sends back a line and
// a tone. This file prints them and scores nothing.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/supplier_account_state.dart';
import '../../utils/render_log.dart';

class SupplierPayoutView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final Map<String, TextEditingController> controllers;
  final VoidCallback onSubmit;
  final bool busy;

  const SupplierPayoutView({
    super.key,
    required this.payload,
    required this.controllers,
    required this.onSubmit,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return _Refusal(message: supplierStr(payload, 'message'));
    }
    final active = payload['active'] is Map ? supplierMap(payload['active']) : null;
    final pending = payload['pending'] is Map ? supplierMap(payload['pending']) : null;
    final history = supplierRows(payload['history']);
    final canEdit = payload['can_edit'] == true;
    RenderLog.write('c402_payout_view', history.length + (active == null ? 0 : 1));

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(supplierStr(payload, 'title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x4),
        Text(supplierStr(payload, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),

        // In use now — absence is explicit, never an empty card.
        Text(supplierStr(payload, 'active_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (active == null)
          _Empty(text: supplierStr(payload, 'empty'))
        else
          _DetailCard(detail: active),

        if (pending != null) ...[
          SizedBox(height: Ds.space.x24),
          Text(supplierStr(payload, 'pending_heading'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          _DetailCard(detail: pending, note: supplierStr(payload, 'pending_note')),
        ],

        SizedBox(height: Ds.space.x24),
        if (canEdit)
          _FormCard(
            payload: payload,
            controllers: controllers,
            onSubmit: onSubmit,
            busy: busy,
          )
        else
          Text(supplierStr(payload, 'readonly_note'), style: Ds.t.caption),

        SizedBox(height: Ds.space.x24),
        Text(supplierStr(payload, 'history_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (history.isEmpty)
          Text(supplierStr(payload, 'history_empty'), style: Ds.t.caption)
        else
          for (final h in history) ...[
            _DetailCard(detail: h),
            SizedBox(height: Ds.space.x12),
          ],
      ],
    );
  }
}

/// One set of details. Every rupee-adjacent string — the masked account, the
/// status word, the name-match verdict — arrives formatted.
class _DetailCard extends StatelessWidget {
  final Map<String, dynamic> detail;
  final String note;
  const _DetailCard({required this.detail, this.note = ''});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(supplierStr(detail, 'account_name'),
                    style: Ds.t.bodyStrong),
              ),
              _Pill(
                text: supplierStr(detail, 'status_label'),
                tone: supplierStr(detail, 'status_tone'),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          if (supplierStr(detail, 'account_number_masked').isNotEmpty)
            _Line(
              value: supplierStr(detail, 'account_number_masked'),
              extra: supplierStr(detail, 'ifsc'),
            ),
          if (supplierStr(detail, 'bank_name').isNotEmpty)
            _Line(value: supplierStr(detail, 'bank_name')),
          if (supplierStr(detail, 'upi_vpa').isNotEmpty)
            _Line(value: supplierStr(detail, 'upi_vpa')),
          if (supplierStr(detail, 'match_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              supplierStr(detail, 'match_label'),
              style: Ds.t.caption
                  .copyWith(color: supplierTone(detail['match_tone'])),
            ),
          ],
          SizedBox(height: Ds.space.x8),
          Text(supplierStr(detail, 'submitted_label'), style: Ds.t.caption),
          if (supplierStr(detail, 'reviewed_label').isNotEmpty)
            Text(supplierStr(detail, 'reviewed_label'), style: Ds.t.caption),
          if (supplierStr(detail, 'review_note').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(supplierStr(detail, 'review_note'), style: Ds.t.caption),
          ],
          if (note.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(note, style: Ds.t.caption.copyWith(color: Ds.c.warning)),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final String value;
  final String extra;
  const _Line({required this.value, this.extra = ''});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x4),
        child: Text(extra.isEmpty ? value : '$value · $extra',
            style: Ds.t.body),
      );
}

/// The form is `fields[]` in payload order — a field the backend adds tomorrow
/// appears without a deploy, and one it drops disappears the same way.
class _FormCard extends StatelessWidget {
  final Map<String, dynamic> payload;
  final Map<String, TextEditingController> controllers;
  final VoidCallback onSubmit;
  final bool busy;

  const _FormCard({
    required this.payload,
    required this.controllers,
    required this.onSubmit,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    final fields = supplierRows(payload['fields']);
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(supplierStr(payload, 'form_heading'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          for (final f in fields) ...[
            _Field(
              controller: controllers[supplierStr(f, 'key')] ??
                  TextEditingController(),
              label: supplierStr(f, 'label'),
              hint: supplierStr(f, 'hint'),
            ),
            SizedBox(height: Ds.space.x12),
          ],
          SizedBox(height: Ds.space.x4),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: busy ? null : onSubmit,
              child: Text(supplierStr(payload, 'submit_label')),
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        style: Ds.t.body,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle: Ds.t.caption,
          filled: true,
          fillColor: Ds.c.bg,
          contentPadding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12, vertical: Ds.space.x12),
          border: OutlineInputBorder(
            borderRadius: Ds.r.rButton,
            borderSide: BorderSide(color: Ds.c.divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: Ds.r.rButton,
            borderSide: BorderSide(color: Ds.c.divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: Ds.r.rButton,
            borderSide: BorderSide(color: Ds.c.brand),
          ),
        ),
      );
}

class _Pill extends StatelessWidget {
  final String text;
  final String tone;
  const _Pill({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: supplierToneSoft(tone),
          borderRadius: Ds.r.rChip,
        ),
        child: Text(text,
            style: Ds.t.caption.copyWith(color: supplierTone(tone))),
      );
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty({required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
        child: Text(text, style: Ds.t.caption),
      );
}

class _Refusal extends StatelessWidget {
  final String message;
  const _Refusal({required this.message});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Center(child: Text(message, style: Ds.t.bodySecondary)),
      );
}

// ── the live screen ─────────────────────────────────────────────────────────

class SupplierPayoutScreen extends StatefulWidget {
  /// Test seam. Null in production -> the real RPCs.
  final SupplierRpc? rpc;
  const SupplierPayoutScreen({super.key, this.rpc});

  @override
  State<SupplierPayoutScreen> createState() => _SupplierPayoutScreenState();
}

class _SupplierPayoutScreenState extends State<SupplierPayoutScreen> {
  Map<String, dynamic>? _payload;
  final Map<String, TextEditingController> _ctrl = {};
  bool _busy = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : SupplierApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final p = await _call('supplier_payout_get', const {});
    if (!mounted) return;
    for (final f in supplierRows(p['fields'])) {
      _ctrl.putIfAbsent(supplierStr(f, 'key'), TextEditingController.new);
    }
    setState(() => _payload = p);
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final r = await _call('supplier_payout_submit', {
      'p_account_name': _ctrl['account_name']?.text ?? '',
      'p_account_number': _ctrl['account_number']?.text ?? '',
      'p_ifsc': _ctrl['ifsc']?.text ?? '',
      'p_bank_name': _ctrl['bank_name']?.text ?? '',
      'p_upi_vpa': _ctrl['upi_vpa']?.text ?? '',
    });
    if (!mounted) return;
    setState(() => _busy = false);
    final msg = supplierStr(r, 'message');
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: supplierTone(r['tone']),
      ));
    }
    if (r['ok'] == true) {
      for (final c in _ctrl.values) {
        c.clear();
      }
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(p == null ? '' : supplierStr(p, 'title')),
        backgroundColor: Ds.c.surface,
      ),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : SupplierPayoutView(
              payload: p,
              controllers: _ctrl,
              busy: _busy,
              onSubmit: _submit,
            ),
    );
  }
}
