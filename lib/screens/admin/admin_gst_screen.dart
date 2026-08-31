import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #320 — GST: input credit, the monthly position and the GSTR exports.
///
/// Before this screen there was no GST anywhere in mediBO — only raw fields
/// (`bill_lines.gst_pct`/`.hsn`, the three GSTINs). The whole of it now lives
/// in `gst_ledger`: `admin_gst_screen(p_period)` returns the position with its
/// working shown, the credit broken down by the supplier it came from, the
/// GSTR-1 / GSTR-3B tables, and the GSTR-2B reconciliation.
///
/// This file computes NOTHING. Every rupee string is `inr_money()` from the
/// backend, every heading comes from `ui_copy`, every column header and its
/// alignment arrive in the payload, and the only thing mapped here is a
/// backend `tone` onto a design token.
class AdminGstScreen extends StatefulWidget {
  const AdminGstScreen({super.key});

  @override
  State<AdminGstScreen> createState() => _AdminGstScreenState();
}

/// The backend names a tone; the token layer owns what that colour is.
Color _toneColor(Object? tone) {
  switch ('$tone') {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'info':
      return Ds.c.info;
    case 'brand':
      return Ds.c.brand;
    default:
      return Ds.c.textSecondary;
  }
}

Color _toneSoft(Object? tone) {
  switch ('$tone') {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'info':
      return Ds.c.infoSoft;
    case 'brand':
      return Ds.c.brandSoft;
    default:
      return Ds.c.bg;
  }
}

/// A column's alignment is the backend's decision, not this file's.
TextAlign _align(Object? a) =>
    '$a' == 'right' ? TextAlign.right : TextAlign.left;

class _AdminGstScreenState extends State<AdminGstScreen> {
  Map<String, dynamic>? _data;
  Object? _error;
  bool _loading = true;
  bool _busy = false;
  String _tab = 'position';
  String? _period;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.rpc('admin_gst_screen',
          params: {'p_period': _period});
      if (!mounted) return;
      setState(() {
        _data = Map<String, dynamic>.from(res as Map);
        _period = '${_data?['period_key'] ?? ''}';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Rebuild reads the bills again. The message it shows is the backend's.
  Future<void> _rebuild() async {
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client
          .rpc('gst_ledger_rebuild', params: {'p_months': 24});
      final m = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${m['message'] ?? ''}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _import(String label, String hint) async {
    final ctrl = TextEditingController();
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + Ds.space.x24,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: Ds.t.subtitle.copyWith(color: Ds.c.text)),
          SizedBox(height: Ds.space.x8),
          Text(hint, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          SizedBox(height: Ds.space.x16),
          TextField(
            controller: ctrl,
            maxLines: 8,
            minLines: 6,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: () => Navigator.pop(sheetCtx, ctrl.text),
              child: Text(label),
            ),
          ),
        ]),
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      final res = await Supabase.instance.client.rpc('gst_2b_import',
          params: {'p_period': _period, 'p_text': text});
      final m = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${m['message'] ?? ''}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final tabs = (d?['tabs'] as List?) ?? const [];
    final periods = (d?['periods'] as List?) ?? const [];

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        foregroundColor: Ds.c.text,
        elevation: 0,
        title: Text('${d?['title'] ?? ''}',
            style: Ds.t.title.copyWith(color: Ds.c.text)),
        actions: [
          if ('${d?['rebuild_label'] ?? ''}'.isNotEmpty)
            TextButton(
              onPressed: _busy ? null : _rebuild,
              child: Text('${d?['rebuild_label']}'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: Column(children: [
          if (periods.isNotEmpty || tabs.isNotEmpty)
            Container(
              width: double.infinity,
              color: Ds.c.surface,
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x16, vertical: Ds.space.x8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (periods.isNotEmpty)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: [
                          for (final p in periods) ...[
                            _Chip(
                              label: '${(p as Map)['label'] ?? ''}',
                              selected: '${p['key']}' == _period,
                              onTap: () {
                                setState(() => _period = '${p['key']}');
                                _load();
                              },
                            ),
                            SizedBox(width: Ds.space.x8),
                          ],
                        ]),
                      ),
                    if (periods.isNotEmpty && tabs.isNotEmpty)
                      SizedBox(height: Ds.space.x8),
                    if (tabs.isNotEmpty)
                      Wrap(
                        spacing: Ds.space.x8,
                        runSpacing: Ds.space.x8,
                        children: [
                          for (final t in tabs)
                            _Chip(
                              label: '${(t as Map)['label'] ?? ''}',
                              selected: _tab == '${t['key']}',
                              onTap: () => setState(() => _tab = '${t['key']}'),
                            ),
                        ],
                      ),
                  ]),
            ),
          Expanded(child: _body(d)),
        ]),
      ),
    );
  }

  Widget _body(Map<String, dynamic>? d) {
    // Reachability proof: a canvas app cannot be clicked by any tool, so the
    // screen reports itself. `curl https://medibo.in/render-log` shows
    // c320_gst_screen once an admin has opened it.
    RenderLog.write('c320_gst_screen', 1);
    if (_loading) return const _Skeleton();
    if (_error != null || d?['ok'] != true) {
      return _ErrorState(
        message: '${d?['error'] ?? _error ?? ''}',
        retryLabel: '${d?['retry_label'] ?? ''}',
        onRetry: _load,
      );
    }
    RenderLog.write('c320_gst_tab_$_tab', 1);

    final header = <Widget>[
      if ('${d?['subtitle'] ?? ''}'.isNotEmpty)
        Text('${d?['subtitle']}',
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      if ('${d?['seller_label'] ?? ''}'.isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text('${d?['seller_label']}',
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      ],
      SizedBox(height: Ds.space.x24),
    ];

    late final List<Widget> body;
    switch (_tab) {
      case 'credit':
        body = _credit(Map<String, dynamic>.from((d?['credit'] as Map?) ?? {}));
        break;
      case 'exports':
        body =
            _exports(Map<String, dynamic>.from((d?['exports'] as Map?) ?? {}));
        break;
      case 'recon':
        body = _recon(Map<String, dynamic>.from((d?['recon'] as Map?) ?? {}));
        break;
      default:
        body = _position(
            Map<String, dynamic>.from((d?['position'] as Map?) ?? {}));
    }

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [...header, ...body],
    );
  }

  // ── Position: output tax − input credit = cash payable, working shown ─────
  List<Widget> _position(Map<String, dynamic> p) {
    final rows = (p['rows'] as List?) ?? const [];
    final heads = (p['heads'] as List?) ?? const [];
    final cols = (p['head_columns'] as List?) ?? const [];
    if ('${p['empty'] ?? ''}'.isNotEmpty) {
      return [_Empty('${p['empty']}')];
    }
    RenderLog.write('c320_gst_position_rows', rows.length);
    return [
      _Card(children: [
        Text('${p['heading'] ?? ''}',
            style: Ds.t.subtitle.copyWith(color: Ds.c.text)),
        SizedBox(height: Ds.space.x16),
        for (final r in rows) ...[
          _WorkingRow(row: Map<String, dynamic>.from(r as Map)),
          SizedBox(height: Ds.space.x12),
        ],
        Divider(color: Ds.c.divider, height: Ds.space.x24),
        Row(children: [
          Expanded(
            child: Text('${p['net_label'] ?? ''}',
                style: Ds.t.bodyStrong.copyWith(color: Ds.c.text)),
          ),
          Text('${p['net_value_label'] ?? ''}',
              style: Ds.t.subtitle.copyWith(color: _toneColor(p['net_tone']))),
        ]),
        SizedBox(height: Ds.space.x12),
        Text('${p['note'] ?? ''}',
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      ]),
      SizedBox(height: Ds.space.x24),
      _Table(columns: cols, rows: heads),
    ];
  }

  // ── Input credit, by the supplier it came from ───────────────────────────
  List<Widget> _credit(Map<String, dynamic> cr) {
    final sups = (cr['suppliers'] as List?) ?? const [];
    if ('${cr['empty'] ?? ''}'.isNotEmpty) return [_Empty('${cr['empty']}')];
    RenderLog.write('c320_gst_credit_suppliers', sups.length);
    return [
      Row(children: [
        Expanded(
          child: Text('${cr['heading'] ?? ''}',
              style: Ds.t.subtitle.copyWith(color: Ds.c.text)),
        ),
        Text('${cr['total_label'] ?? ''}',
            style: Ds.t.subtitle.copyWith(color: Ds.c.brand)),
      ]),
      SizedBox(height: Ds.space.x16),
      for (final s in sups) ...[
        _SupplierCard(supplier: Map<String, dynamic>.from(s as Map)),
        SizedBox(height: Ds.space.x12),
      ],
    ];
  }

  // ── GSTR-1 / GSTR-3B ─────────────────────────────────────────────────────
  List<Widget> _exports(Map<String, dynamic> ex) {
    final blocks = (ex['blocks'] as List?) ?? const [];
    if ('${ex['empty'] ?? ''}'.isNotEmpty) return [_Empty('${ex['empty']}')];
    RenderLog.write('c320_gst_export_blocks', blocks.length);
    return [
      Text('${ex['heading'] ?? ''}',
          style: Ds.t.subtitle.copyWith(color: Ds.c.text)),
      SizedBox(height: Ds.space.x8),
      Text('${ex['copy_hint'] ?? ''}',
          style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      SizedBox(height: Ds.space.x24),
      for (final b in blocks) ...[
        _ExportBlock(
          block: Map<String, dynamic>.from(b as Map),
          onCopy: (csv) async {
            await Clipboard.setData(ClipboardData(text: csv));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${ex['copy_hint'] ?? ''}')));
          },
        ),
        SizedBox(height: Ds.space.x24),
      ],
    ];
  }

  // ── GSTR-2B: credit that has not shown up ────────────────────────────────
  List<Widget> _recon(Map<String, dynamic> rc) {
    final rows = (rc['rows'] as List?) ?? const [];
    RenderLog.write('c320_gst_recon_rows', rows.length);
    return [
      Text('${rc['heading'] ?? ''}',
          style: Ds.t.subtitle.copyWith(color: Ds.c.text)),
      SizedBox(height: Ds.space.x8),
      Text('${rc['note'] ?? ''}',
          style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      SizedBox(height: Ds.space.x16),
      _Card(children: [
        Text('${rc['summary_label'] ?? ''}',
            style: Ds.t.body.copyWith(color: Ds.c.text)),
        SizedBox(height: Ds.space.x8),
        Text('${rc['source_label'] ?? ''}',
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        if ('${rc['excluded_label'] ?? ''}'.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text('${rc['excluded_label']}',
              style: Ds.t.caption.copyWith(color: Ds.c.warning)),
        ],
        SizedBox(height: Ds.space.x16),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: OutlinedButton(
            onPressed: () => _import(
                '${rc['import_label'] ?? ''}', '${rc['import_hint'] ?? ''}'),
            child: Text('${rc['import_label'] ?? ''}'),
          ),
        ),
      ]),
      SizedBox(height: Ds.space.x24),
      if (rows.isEmpty)
        _Empty('${rc['empty'] ?? ''}')
      else
        for (final r in rows) ...[
          _ReconRow(row: Map<String, dynamic>.from(r as Map)),
          SizedBox(height: Ds.space.x12),
        ],
    ];
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Ds.r.chip),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          decoration: BoxDecoration(
            color: selected ? Ds.c.brandSoft : Ds.c.bg,
            borderRadius: BorderRadius.circular(Ds.r.chip),
            border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
          ),
          child: SizedBox(
            height: Ds.touch.minTarget,
            child: Align(
              alignment: Alignment.center,
              widthFactor: 1,
              child: Text(label,
                  style: Ds.t.caption.copyWith(
                      color: selected ? Ds.c.brand : Ds.c.textSecondary,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      );
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}

/// One line of the working: what it is, what it is on, what it comes to.
class _WorkingRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const _WorkingRow({required this.row});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${row['label'] ?? ''}',
                  style: Ds.t.body.copyWith(color: Ds.c.text)),
              if ('${row['sub'] ?? ''}'.isNotEmpty)
                Text('${row['sub']}',
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            ]),
          ),
          SizedBox(width: Ds.space.x12),
          Text('${row['value_label'] ?? ''}',
              style: Ds.t.bodyStrong.copyWith(color: _toneColor(row['tone']))),
        ],
      );
}

/// A table whose columns, labels and alignment all arrive in the payload.
class _Table extends StatelessWidget {
  final List columns;
  final List rows;
  const _Table({required this.columns, required this.rows});

  @override
  Widget build(BuildContext context) {
    if (columns.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: Ds.touch.minTarget,
          dataRowMinHeight: Ds.touch.minTarget,
          dataRowMaxHeight: Ds.touch.listRowMinHeight,
          horizontalMargin: Ds.space.x16,
          columnSpacing: Ds.space.x24,
          columns: [
            for (final c in columns)
              DataColumn(
                numeric: '${(c as Map)['align']}' == 'right',
                label: Text('${c['label'] ?? ''}',
                    style: Ds.t.caption.copyWith(
                        color: Ds.c.textSecondary,
                        fontWeight: FontWeight.w600)),
              ),
          ],
          rows: [
            for (final r in rows)
              DataRow(cells: [
                for (final c in columns)
                  DataCell(Text('${(r as Map)[(c as Map)['key']] ?? ''}',
                      textAlign: _align(c['align']),
                      style: Ds.t.body.copyWith(color: Ds.c.text))),
              ]),
          ],
        ),
      ),
    );
  }
}

/// One supplier's credit, with the invoices it came from.
class _SupplierCard extends StatelessWidget {
  final Map<String, dynamic> supplier;
  const _SupplierCard({required this.supplier});

  @override
  Widget build(BuildContext context) {
    final invoices = (supplier['invoices'] as List?) ?? const [];
    return _Card(children: [
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${supplier['name'] ?? ''}',
                style: Ds.t.bodyStrong.copyWith(color: Ds.c.text)),
            Text('${supplier['gstin_label'] ?? ''}',
                style: Ds.t.caption.copyWith(
                    color: supplier['has_gstin'] == true
                        ? Ds.c.textSecondary
                        : Ds.c.danger)),
          ]),
        ),
        SizedBox(width: Ds.space.x12),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${supplier['credit_label'] ?? ''}',
              style: Ds.t.subtitle.copyWith(color: Ds.c.brand)),
          Text('${supplier['count_label'] ?? ''}',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        ]),
      ]),
      if (invoices.isNotEmpty) ...[
        Divider(color: Ds.c.divider, height: Ds.space.x24),
        for (final i in invoices)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: Row(children: [
              Expanded(
                child: Text('${(i as Map)['invoice_no'] ?? ''}',
                    style: Ds.t.body.copyWith(color: Ds.c.text)),
              ),
              SizedBox(width: Ds.space.x8),
              Text('${i['date_label'] ?? ''}',
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
              SizedBox(width: Ds.space.x16),
              Text('${i['tax_label'] ?? ''}',
                  style: Ds.t.body.copyWith(color: Ds.c.text)),
            ]),
          ),
      ],
    ]);
  }
}

/// A return, exactly as the backend laid it out, plus its CSV.
class _ExportBlock extends StatelessWidget {
  final Map<String, dynamic> block;
  final Future<void> Function(String csv) onCopy;
  const _ExportBlock({required this.block, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final rows = (block['rows'] as List?) ?? const [];
    final csv = '${block['csv_header'] ?? ''}\n${block['csv'] ?? ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text('${block['title'] ?? ''}',
              style: Ds.t.bodyStrong.copyWith(color: Ds.c.text)),
        ),
        SizedBox(
          height: Ds.touch.minTarget,
          child: IconButton(
            onPressed: rows.isEmpty ? null : () => onCopy(csv),
            icon: Icon(Icons.copy_all_outlined, color: Ds.c.brand),
          ),
        ),
      ]),
      SizedBox(height: Ds.space.x8),
      _Table(columns: (block['columns'] as List?) ?? const [], rows: rows),
    ]);
  }
}

/// One purchase invoice and whether its credit has actually appeared.
class _ReconRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const _ReconRow({required this.row});

  @override
  Widget build(BuildContext context) => _Card(children: [
        Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${row['supplier'] ?? ''}',
                  style: Ds.t.bodyStrong.copyWith(color: Ds.c.text)),
              Text('${row['invoice_no'] ?? ''}  ·  ${row['date_label'] ?? ''}',
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            ]),
          ),
          SizedBox(width: Ds.space.x12),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${row['tax_label'] ?? ''}',
                style: Ds.t.bodyStrong.copyWith(color: Ds.c.text)),
            SizedBox(height: Ds.space.x4),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                color: _toneSoft(row['tone']),
                borderRadius: BorderRadius.circular(Ds.r.chip),
              ),
              child: Text('${row['status_label'] ?? ''}',
                  style: Ds.t.caption.copyWith(
                      color: _toneColor(row['tone']),
                      fontWeight: FontWeight.w600)),
            ),
          ]),
        ]),
      ]);
}

class _Empty extends StatelessWidget {
  final String message;
  const _Empty(this.message);
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
        child: Text(message,
            textAlign: TextAlign.center,
            style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
      );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) => ListView.separated(
        padding: EdgeInsets.all(Ds.space.x16),
        itemCount: 4,
        separatorBuilder: (_, _) => SizedBox(height: Ds.space.x12),
        itemBuilder: (_, _) => Container(
          height: Ds.space.x48 + Ds.space.x32,
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
          ),
        ),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;
  const _ErrorState(
      {required this.message, required this.retryLabel, required this.onRetry});

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x32),
        children: [
          Text(message,
              textAlign: TextAlign.center,
              style: Ds.t.body.copyWith(color: Ds.c.danger)),
          if (retryLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
            ),
          ],
        ],
      );
}
