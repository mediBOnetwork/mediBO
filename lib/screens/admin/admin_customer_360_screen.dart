import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// CHANGE #396 — Customer 360.
///
/// One pharmacy, whole, from ONE call. `customer_360(customer_id)` composes
/// identity and zone, lifetime and monthly value, the discount slab actually
/// applied, every order with its own money, payments and outstanding, disputes
/// and returns, the margin earned from them (#319's P&L view), delivery
/// success and the WhatsApp thread — already worded, already formatted, already
/// toned. There is no stitching here and no second RPC: this file lays the
/// payload out and nothing else.
class AdminCustomer360Screen extends StatefulWidget {
  final String customerId;

  const AdminCustomer360Screen({super.key, required this.customerId});

  /// Test seam — feed payloads in without Supabase.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcOverride;

  @override
  State<AdminCustomer360Screen> createState() => _AdminCustomer360ScreenState();
}

class _AdminCustomer360ScreenState extends State<AdminCustomer360Screen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) {
    final o = AdminCustomer360Screen.rpcOverride;
    if (o != null) return o(fn, params);
    return params == null
        ? Supabase.instance.client.rpc(fn)
        : Supabase.instance.client.rpc(fn, params: params);
  }

  Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final m = _asMap(await _rpc('customer_360', {
        'p_customer_id': widget.customerId,
        'p_wa_limit': 40,
      }));
      if (!mounted) return;
      setState(() {
        _d = m;
        _loading = false;
      });
      RenderLog.write('c396_customer360', 'painted');
      RenderLog.write('c396_c360_orders',
          '${((m['orders'] as Map?)?['rows'] as List?)?.length ?? 0}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Color _tone(String? tone) {
    switch (tone) {
      case 'brand':
        return Ds.c.brand;
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.text;
    }
  }

  Color _toneSoft(String? tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.bg;
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final refused = d != null && d['ok'] == false;
    final header = _asMap(d?['header']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(refused || header.isEmpty
            ? (d?['title'] ?? '').toString()
            : (header['name'] ?? '').toString()),
      ),
      body: _loading
          ? _skeleton()
          : refused
              ? _centered((d['message'] ?? '').toString())
              : _error.isNotEmpty
                  ? _retry()
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _body(d ?? const <String, dynamic>{}),
                    ),
    );
  }

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 7; i++)
            Container(
              height: Ds.space.x48,
              margin: EdgeInsets.only(bottom: Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                border: Border.all(color: Ds.c.divider),
              ),
            ),
        ],
      );

  Widget _centered(String text) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child:
              Text(text, style: Ds.t.bodySecondary, textAlign: TextAlign.center),
        ),
      );

  Widget _retry() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error,
                  style: Ds.t.bodySecondary, textAlign: TextAlign.center),
              SizedBox(height: Ds.space.x16),
              FilledButton(
                  onPressed: _load,
                  child: Text((_d?['retry_label'] ?? '').toString())),
            ],
          ),
        ),
      );

  Widget _body(Map<String, dynamic> d) {
    final header = _asMap(d['header']);
    final slab = _asMap(d['slab']);
    final credit = _asMap(d['credit']);
    final orders = _asMap(d['orders']);
    final payments = _asMap(d['payments']);
    final disputes = _asMap(d['disputes']);
    final margin = _asMap(d['margin']);
    final delivery = _asMap(d['delivery']);
    final wa = _asMap(d['whatsapp']);
    final months = (d['months'] as List?) ?? const [];
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        _identity(header, credit),
        SizedBox(height: Ds.space.x24),
        _tiles((d['tiles'] as List?) ?? const []),
        SizedBox(height: Ds.space.x24),
        _slabCard(slab, _asMap(d['section_labels'])['slab']?.toString() ?? ''),
        if (months.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          _monthsCard(months, (d['months_label'] ?? '').toString()),
        ],
        SizedBox(height: Ds.space.x24),
        _marginCard(margin),
        SizedBox(height: Ds.space.x24),
        _deliveryCard(delivery),
        SizedBox(height: Ds.space.x24),
        _paymentsCard(payments),
        SizedBox(height: Ds.space.x24),
        _ordersCard(orders),
        SizedBox(height: Ds.space.x24),
        _disputesCard(disputes),
        SizedBox(height: Ds.space.x24),
        _whatsappCard(wa),
        SizedBox(height: Ds.space.x32),
      ],
    );
  }

  Widget _card({required String title, required List<Widget> children}) =>
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty) ...[
              Text(title, style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x12),
            ],
            ...children,
          ],
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 2, child: Text(k, style: Ds.t.caption)),
            SizedBox(width: Ds.space.x12),
            Expanded(flex: 3, child: Text(v, style: Ds.t.body)),
          ],
        ),
      );

  Widget _chip(String label, String tone) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration:
            BoxDecoration(color: _toneSoft(tone), borderRadius: Ds.r.rChip),
        child: Text(label, style: Ds.t.caption.copyWith(color: _tone(tone))),
      );

  Widget _identity(Map<String, dynamic> h, Map<String, dynamic> credit) => _card(
        title: '',
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text((h['name'] ?? '').toString(), style: Ds.t.title),
              ),
              SizedBox(width: Ds.space.x12),
              _chip((h['status_label'] ?? '').toString(),
                  (h['status_tone'] ?? '').toString()),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          for (final f in (h['fields'] as List?) ?? const [])
            if (f is Map)
              _kv((f['label'] ?? '').toString(), (f['value'] ?? '').toString()),
          if (credit['has'] == true) ...[
            _kv((credit['limit_label'] ?? '').toString(),
                (credit['limit_display'] ?? '').toString()),
            if (credit['prepaid_only'] == true)
              _chip((credit['prepaid_label'] ?? '').toString(), 'warning'),
          ],
        ],
      );

  Widget _tiles(List<dynamic> tiles) => LayoutBuilder(
        builder: (context, box) {
          final cols = box.maxWidth >= 640 ? 4 : 2;
          final gap = Ds.space.x12;
          final w = (box.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final t in tiles)
                if (t is Map)
                  SizedBox(
                      width: w, child: _tile(Map<String, dynamic>.from(t))),
            ],
          );
        },
      );

  Widget _tile(Map<String, dynamic> t) => Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text((t['label'] ?? '').toString(),
                style: Ds.t.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
            SizedBox(height: Ds.space.x8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text((t['value'] ?? '').toString(),
                  style: Ds.t.title
                      .copyWith(color: _tone((t['tone'] ?? '').toString()))),
            ),
          ],
        ),
      );

  Widget _slabCard(Map<String, dynamic> slab, String title) => _card(
        title: title,
        children: [
          Text((slab['pct_display'] ?? '').toString(), style: Ds.t.display),
          SizedBox(height: Ds.space.x4),
          Text((slab['basis_label'] ?? '').toString(), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final s in (slab['ladder'] as List?) ?? const [])
                if (s is Map)
                  _chip(
                    '${s['label']} · ${s['from_display']}',
                    s['active'] == true ? 'success' : 'neutral',
                  ),
            ],
          ),
        ],
      );

  Widget _monthsCard(List<dynamic> months, String title) => _card(
        title: title,
        children: [
          for (final m in months)
            if (m is Map)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x8),
                child: Row(
                  children: [
                    Expanded(
                        child: Text((m['label'] ?? '').toString(),
                            style: Ds.t.body)),
                    Text('${m['orders']}', style: Ds.t.bodySecondary),
                    SizedBox(width: Ds.space.x16),
                    Text((m['value_display'] ?? '').toString(),
                        style: Ds.t.bodyStrong),
                  ],
                ),
              ),
        ],
      );

  Widget _marginCard(Map<String, dynamic> m) => _card(
        title: (m['label'] ?? '').toString(),
        children: m['has'] == true
            ? [
                _kv((m['revenue_label'] ?? '').toString(),
                    (m['revenue_display'] ?? '').toString()),
                _kv((m['gross_margin_label'] ?? '').toString(),
                    (m['gross_margin_display'] ?? '').toString()),
                _kv((m['contribution_label'] ?? '').toString(),
                    (m['contribution_display'] ?? '').toString()),
                if ((m['pct_display'] ?? '').toString().isNotEmpty)
                  _chip((m['pct_display'] ?? '').toString(), 'success'),
              ]
            : [Text((m['empty'] ?? '').toString(), style: Ds.t.bodySecondary)],
      );

  Widget _deliveryCard(Map<String, dynamic> dl) => _card(
        title: (dl['label'] ?? '').toString(),
        children: dl['has'] == true
            ? [
                Text((dl['success_display'] ?? '').toString(),
                    style: Ds.t.display.copyWith(
                        color: _tone((dl['success_tone'] ?? '').toString()))),
                SizedBox(height: Ds.space.x12),
                _kv((dl['attempts_label'] ?? '').toString(), '${dl['attempts']}'),
                _kv((dl['delivered_label'] ?? '').toString(), '${dl['delivered']}'),
                _kv((dl['failed_label'] ?? '').toString(), '${dl['failed']}'),
              ]
            : [Text((dl['empty'] ?? '').toString(), style: Ds.t.bodySecondary)],
      );

  Widget _paymentsCard(Map<String, dynamic> p) {
    final rows = (p['rows'] as List?) ?? const [];
    return _card(
      title: (p['label'] ?? '').toString(),
      children: [
        _kv((p['billed_label'] ?? '').toString(),
            (p['billed_display'] ?? '').toString()),
        _kv((p['paid_label'] ?? '').toString(),
            (p['paid_display'] ?? '').toString()),
        _kv((p['outstanding_label'] ?? '').toString(),
            (p['outstanding_display'] ?? '').toString()),
        if ((p['note'] ?? '').toString().isNotEmpty)
          Text((p['note'] ?? '').toString(), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        if (rows.isEmpty)
          Text((p['empty'] ?? '').toString(), style: Ds.t.bodySecondary)
        else
          for (final r in rows)
            if (r is Map)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text((r['date_label'] ?? '').toString(),
                              style: Ds.t.body),
                          Text(
                            [
                              (r['method'] ?? '').toString(),
                              (r['utr'] ?? '').toString(),
                              (r['order_code'] ?? '').toString(),
                            ].where((s) => s.isNotEmpty).join(' · '),
                            style: Ds.t.caption,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text((r['amount_display'] ?? '').toString(),
                            style: Ds.t.bodyStrong),
                        SizedBox(height: Ds.space.x4),
                        _chip((r['status_label'] ?? '').toString(),
                            (r['status_tone'] ?? '').toString()),
                      ],
                    ),
                  ],
                ),
              ),
      ],
    );
  }

  Widget _ordersCard(Map<String, dynamic> o) {
    final rows = (o['rows'] as List?) ?? const [];
    return _card(
      title: (o['label'] ?? '').toString(),
      children: [
        if (rows.isEmpty)
          Text((o['empty'] ?? '').toString(), style: Ds.t.bodySecondary)
        else
          for (final r in rows)
            if (r is Map)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text((r['order_code'] ?? '').toString(),
                              style: Ds.t.bodyStrong),
                          Text(
                            '${r['date_label']} · ${r['items_label']}',
                            style: Ds.t.caption,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text((r['value_display'] ?? '').toString(),
                            style: Ds.t.bodyStrong),
                        SizedBox(height: Ds.space.x4),
                        _chip((r['status_label'] ?? '').toString(),
                            (r['status_tone'] ?? '').toString()),
                        if (r['is_settled'] != true) ...[
                          SizedBox(height: Ds.space.x4),
                          Text((r['outstanding_display'] ?? '').toString(),
                              style: Ds.t.caption
                                  .copyWith(color: Ds.c.danger)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
      ],
    );
  }

  Widget _disputesCard(Map<String, dynamic> d) {
    final rows = (d['rows'] as List?) ?? const [];
    return _card(
      title: (d['label'] ?? '').toString(),
      children: [
        if (rows.isEmpty)
          Text((d['empty'] ?? '').toString(), style: Ds.t.bodySecondary)
        else
          for (final r in rows)
            if (r is Map)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            [
                              (r['product_name'] ?? '').toString(),
                              (r['ref'] ?? '').toString(),
                            ].where((s) => s.isNotEmpty).join(' · '),
                            style: Ds.t.body,
                          ),
                          Text(
                            '${r['date_label']} · ${r['detail']}',
                            style: Ds.t.caption,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    _chip((r['status_label'] ?? '').toString(),
                        (r['status_tone'] ?? '').toString()),
                  ],
                ),
              ),
      ],
    );
  }

  Widget _whatsappCard(Map<String, dynamic> wa) {
    final rows = (wa['rows'] as List?) ?? const [];
    return _card(
      title: (wa['label'] ?? '').toString(),
      children: [
        if (rows.isEmpty)
          Text((wa['empty'] ?? '').toString(), style: Ds.t.bodySecondary)
        else
          for (final r in rows)
            if (r is Map)
              Align(
                alignment: r['is_out'] == true
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  margin: EdgeInsets.only(bottom: Ds.space.x8),
                  padding: EdgeInsets.all(Ds.space.x12),
                  decoration: BoxDecoration(
                    color:
                        r['is_out'] == true ? Ds.c.brandSoft : Ds.c.bg,
                    borderRadius: Ds.r.rCard,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text((r['body'] ?? '').toString(), style: Ds.t.body),
                      SizedBox(height: Ds.space.x4),
                      Text(
                        [
                          (r['at_label'] ?? '').toString(),
                          (r['status'] ?? '').toString(),
                        ].where((s) => s.isNotEmpty).join(' · '),
                        style: Ds.t.caption,
                      ),
                    ],
                  ),
                ),
              ),
      ],
    );
  }
}
