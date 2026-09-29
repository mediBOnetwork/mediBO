// CMD #2250 — "WHERE CUSTOMERS PAY" (design frames 1 and 4).
//
// One RPC, pay_payee_screen(), draws the whole block: the account rows with
// their type / Pay-button / merchant-QR chips, the "What customers see now"
// card and the + Add UPI entry point. Making a personal UPI active is the
// BACKEND's decision to warn about: upi_make_active returns confirm_personal
// with the sheet's own copy, and only a confirmed second call switches.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'add_upi_screen.dart';
import 'payment_ui.dart';

class PaymentPayeeSection extends StatefulWidget {
  /// Tests stub the RPCs; production leaves them null.
  final Future<Map<String, dynamic>> Function()? screenRpc;
  final Future<Map<String, dynamic>> Function(String id, bool confirm)?
      activateRpc;
  const PaymentPayeeSection({super.key, this.screenRpc, this.activateRpc});

  @override
  State<PaymentPayeeSection> createState() => PaymentPayeeSectionState();
}

class PaymentPayeeSectionState extends State<PaymentPayeeSection> {
  Map<String, dynamic>? _p;
  bool _loading = true;
  String? _error;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _rpcScreen() async {
    if (widget.screenRpc != null) return widget.screenRpc!();
    final r = await Supabase.instance.client.rpc('pay_payee_screen');
    return Map<String, dynamic>.from(r as Map);
  }

  Future<Map<String, dynamic>> _rpcActivate(String id, bool confirm) async {
    if (widget.activateRpc != null) return widget.activateRpc!(id, confirm);
    final r = await Supabase.instance.client.rpc('upi_make_active',
        params: {'p_id': id, 'p_confirm': confirm});
    return Map<String, dynamic>.from(r as Map);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await _rpcScreen();
      if (!mounted) return;
      setState(() {
        _p = p;
        _loading = false;
      });
      RenderLog.write('c2250_payee_rows', payRows(p['rows']).length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Public so the host screen's pull-to-refresh reaches it.
  Future<void> reload() => _load();

  Future<void> _activate(Map<String, dynamic> row, {bool confirm = false}) async {
    final id = payStr(row, 'id');
    if (id.isEmpty) return;
    setState(() => _busyId = id);
    try {
      final r = await _rpcActivate(id, confirm);
      if (!mounted) return;
      if (r['error'] == 'confirm_personal') {
        setState(() => _busyId = null);
        final block = Map<String, dynamic>.from(r['confirm'] as Map);
        final go = await _askPersonal(block);
        if (go == true) await _activate(row, confirm: true);
        return;
      }
      setState(() {
        _busyId = null;
        if (r['screen'] is Map) {
          _p = Map<String, dynamic>.from(r['screen'] as Map);
        }
      });
      final msg = payStr(r, 'message');
      if (msg.isNotEmpty && mounted) showToast(context, msg);
      if (r['screen'] == null) await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      showToast(context, e.toString(), isError: true);
    }
  }

  Future<bool?> _askPersonal(Map<String, dynamic> b) {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Ds.c.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(payStr(b, 'title'),
                  style: Ds.t.title.copyWith(fontWeight: FontWeight.w700)),
              SizedBox(height: Ds.space.x4),
              Text(payStr(b, 'subtitle'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              PayBanner({
                'tone': 'warning',
                'title': payStr(b, 'warn_title'),
                'body': payStr(b, 'warn_body'),
              }),
              SizedBox(height: Ds.space.x24),
              Row(children: [
                Expanded(
                  child: Semantics(
                    identifier: 'upi_keep_business',
                    child: PayPrimaryButton(
                        label: payStr(b, 'cancel_label'),
                        outlined: true,
                        onPressed: () => Navigator.of(ctx).pop(false)),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: Semantics(
                    identifier: 'upi_switch_anyway',
                    child: PayPrimaryButton(
                        label: payStr(b, 'confirm_label'),
                        onPressed: () => Navigator.of(ctx).pop(true)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAdd() async {
    final p = _p;
    if (p == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddUpiScreen(form: Map<String, dynamic>.from(p['form'] as Map)),
      ),
    );
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const PaySkeleton();
    final p = _p;
    if (p == null || p['ok'] != true) {
      return PayError(
        message: payStr(p ?? const {}, 'message').isNotEmpty
            ? payStr(p!, 'message')
            : (_error ?? ''),
        retryLabel: payStr(p ?? const {}, 'add_label'),
        onRetry: _load,
      );
    }
    final rows = payRows(p['rows']);
    final see = (p['see'] is Map)
        ? Map<String, dynamic>.from(p['see'] as Map)
        : <String, dynamic>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PaySectionLabel(payStr(p, 'section_label')),
        if (rows.isEmpty)
          PayEmpty(
              label: payStr(p, 'empty_label'), hint: payStr(p, 'empty_hint'))
        else
          PayCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: Ds.c.divider),
                  _accountRow(rows[i]),
                ],
              ],
            ),
          ),
        SizedBox(height: Ds.space.x16),
        if ((see['lines'] is List) && (see['lines'] as List).isNotEmpty)
          PayCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(payStr(see, 'title'),
                    style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
                SizedBox(height: Ds.space.x12),
                for (final l in (see['lines'] as List))
                  Padding(
                    padding: EdgeInsets.only(bottom: Ds.space.x8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.check, size: Ds.space.x16, color: Ds.c.brand),
                        SizedBox(width: Ds.space.x8),
                        Expanded(child: Text(l.toString(), style: Ds.t.caption)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        SizedBox(height: Ds.space.x16),
        Semantics(
          identifier: 'upi_add_open',
          child: PayPrimaryButton(
              label: payStr(p, 'add_label'), outlined: true, onPressed: _openAdd),
        ),
      ],
    );
  }

  Widget _accountRow(Map<String, dynamic> r) {
    final active = r['is_active'] == true;
    final busy = _busyId == payStr(r, 'id');
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      color: active ? Ds.c.successSoft : Ds.c.surface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            r['is_business'] == true
                ? Icons.storefront_outlined
                : Icons.person_outline,
            size: Ds.space.x24,
            color: Ds.c.textSecondary,
          ),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(payStr(r, 'pn'),
                    style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
                SizedBox(height: Ds.space.x4),
                Text(payStr(r, 'pa'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.caption),
                SizedBox(height: Ds.space.x8),
                Wrap(
                  spacing: Ds.space.x8,
                  runSpacing: Ds.space.x8,
                  children: [
                    PayChip(payStr(r, 'type_label'),
                        tone: r['is_business'] == true ? 'success' : 'info'),
                    PayChip(payStr(r, 'pay_label'), tone: r['pay_tone']),
                    PayChip(payStr(r, 'qr_label'),
                        tone: r['has_merchant'] == true ? 'success' : 'muted'),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x8),
          if (active)
            PayChip(payStr(r, 'state_label'), tone: 'success')
          else
            Semantics(
              identifier: 'upi_make_active',
              child: SizedBox(
                height: Ds.touch.minTarget,
                child: TextButton(
                  onPressed: busy ? null : () => _activate(r),
                  child: Text(payStr(r, 'state_label'),
                      style: Ds.t.caption.copyWith(
                          color: Ds.c.brand, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
