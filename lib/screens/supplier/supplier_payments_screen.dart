// CHANGE #527 · feature_gaps #62 — the supplier's payment statement.
//
// Before this screen a supplier could not see what was owed, what was paid,
// against which PO, or what was outstanding: supplier_payments had no read
// policy and the only payment view in the product was one PO's admin panel.
//
// Every rupee, every date, every plural and every column heading on this page
// is a string from `supplier_my_payments()`. Nothing is summed, formatted or
// worded here — the screen prints the payload and asks for the next page.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : <Map<String, dynamic>>[];

String _str(Map<String, dynamic> m, String k) {
  final v = m[k];
  return v == null ? '' : v.toString();
}

Color _tone(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    default:
      return Ds.c.info;
  }
}

Color _toneSoft(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    default:
      return Ds.c.infoSoft;
  }
}

class SupplierPaymentsScreen extends StatefulWidget {
  const SupplierPaymentsScreen({super.key});

  @override
  State<SupplierPaymentsScreen> createState() => _SupplierPaymentsScreenState();
}

class _SupplierPaymentsScreenState extends State<SupplierPaymentsScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  final Set<String> _open = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client
          .rpc('supplier_my_payments', params: <String, dynamic>{});
      if (!mounted) return;
      final m = _map(res);
      setState(() {
        _data = m;
        _error = m['ok'] == true ? null : _str(m, 'message');
        _loading = false;
      });
      RenderLog.write('c527_supplier_payments', _rows(m['orders']).length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data ?? <String, dynamic>{};
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_str(d, 'title'))),
      body: _loading
          ? _skeleton()
          : _error != null
              ? _errorState(_error!)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      if (_str(d, 'subtitle').isNotEmpty)
                        Text(_str(d, 'subtitle'), style: Ds.t.caption),
                      SizedBox(height: Ds.space.x16),
                      _summary(_rows(d['summary'])),
                      SizedBox(height: Ds.space.x24),
                      if (_rows(d['orders']).isEmpty)
                        Text(_str(d, 'empty'), style: Ds.t.bodySecondary)
                      else
                        for (final o in _rows(d['orders'])) _orderCard(o),
                    ],
                  ),
                ),
    );
  }

  Widget _summary(List<Map<String, dynamic>> tiles) => Wrap(
        spacing: Ds.space.x12,
        runSpacing: Ds.space.x12,
        children: [
          for (final t in tiles)
            Container(
              width: (MediaQuery.of(context).size.width - Ds.space.x48) / 2,
              padding: EdgeInsets.all(Ds.space.x16),
              decoration: BoxDecoration(
                color: _toneSoft(_str(t, 'tone')),
                borderRadius: Ds.r.rCard,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_str(t, 'label'), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x4),
                  Text(_str(t, 'value'),
                      style: Ds.t.subtitle
                          .copyWith(color: _tone(_str(t, 'tone')))),
                ],
              ),
            ),
        ],
      );

  Widget _orderCard(Map<String, dynamic> o) {
    final id = _str(o, 'order_id');
    final open = _open.contains(id);
    final payments = _rows(o['payments']);
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(children: [
        InkWell(
          onTap: () => setState(
              () => open ? _open.remove(id) : _open.add(id)),
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: Column(children: [
              Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_str(o, 'order_code'), style: Ds.t.bodyStrong),
                      Text(_str(o, 'date_label'), style: Ds.t.caption),
                    ],
                  ),
                ),
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                      color: _toneSoft(_str(o, 'due_tone')),
                      borderRadius: Ds.r.rChip),
                  child: Text(_str(o, 'status_label'),
                      style: Ds.t.caption
                          .copyWith(color: _tone(_str(o, 'due_tone')))),
                ),
              ]),
              SizedBox(height: Ds.space.x12),
              Row(children: [
                Expanded(child: Text(_str(o, 'payable_display'),
                    style: Ds.t.body, textAlign: TextAlign.left)),
                Expanded(child: Text(_str(o, 'paid_display'),
                    style: Ds.t.body, textAlign: TextAlign.center)),
                Expanded(
                  child: Text(_str(o, 'due_display'),
                      style: Ds.t.bodyStrong
                          .copyWith(color: _tone(_str(o, 'due_tone'))),
                      textAlign: TextAlign.right),
                ),
              ]),
              SizedBox(height: Ds.space.x4),
              Row(children: [
                Expanded(child: Text(_str(o, 'payments_label'),
                    style: Ds.t.caption)),
                Icon(open ? Icons.expand_less : Icons.expand_more,
                    color: Ds.c.textSecondary),
              ]),
            ]),
          ),
        ),
        if (open && payments.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x16, 0, Ds.space.x16, Ds.space.x16),
            child: Column(children: [
              for (final p in payments)
                Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x8),
                  child: Row(children: [
                    Expanded(
                      child: Text(_str(p, 'at_label'), style: Ds.t.caption),
                    ),
                    Expanded(
                      child: Text(_str(p, 'kind'),
                          style: Ds.t.caption, textAlign: TextAlign.center),
                    ),
                    Expanded(
                      child: Text(_str(p, 'amount_display'),
                          style: Ds.t.body, textAlign: TextAlign.right),
                    ),
                  ]),
                ),
            ]),
          ),
      ]),
    );
  }

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              height: Ds.touch.minTarget * 2,
              margin: EdgeInsets.only(bottom: Ds.space.x12),
              decoration: BoxDecoration(
                  color: Ds.c.surface, borderRadius: Ds.r.rCard),
            ),
        ],
      );

  Widget _errorState(String msg) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(msg, style: Ds.t.bodySecondary, textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: _load,
                child: Text(c('supplier_pay.retry')),
              ),
            ),
          ]),
        ),
      );
}
