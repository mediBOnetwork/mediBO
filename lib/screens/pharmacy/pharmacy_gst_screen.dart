// CMD #416 — the pharmacy's GST pack.
//
// The month a small pharmacy pays a CA to re-type: the bills mediBO raised to
// it, the bills it typed from the shop down the road, and every invoice its own
// counter printed — already added up, already split into CGST/SGST, already in
// the shape GSTR-1 and GSTR-3B want.
//
// THIS FILE ADDS UP NOTHING. Every rupee, every tab label, every column header,
// every CSV body and the disclaimer are finished strings from
// `pharmacy_gst_home()`. The tables are drawn from the payload's own
// `columns[]` — so a new column is a backend change, not a deploy.
//
// AND IT NEVER SAYS "FILED". There is no GSP behind this build, so the button
// says Download and the banner prints the backend's own sentence about filing
// happening on the portal. A screen that implied otherwise would be a lie with
// a legal deadline attached to it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_gst_api.dart';
import '../../utils/render_log.dart';

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

Color _toneColor(String tone) {
  switch (tone) {
    case 'danger':
      return Ds.c.danger;
    case 'warning':
      return Ds.c.warning;
    case 'muted':
      return Ds.c.textSecondary;
    default:
      return Ds.c.brand;
  }
}

class PharmacyGstScreen extends StatefulWidget {
  /// Test seam. Null in production -> the real RPCs.
  final GstRpc? rpc;
  const PharmacyGstScreen({super.key, this.rpc});

  @override
  State<PharmacyGstScreen> createState() => _PharmacyGstScreenState();
}

class _PharmacyGstScreenState extends State<PharmacyGstScreen> {
  Map<String, dynamic> _data = const {};
  bool _loading = true;
  String? _error;
  String _tab = 'position';
  String? _period;
  bool _packBusy = false;
  Timer? _poll;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyGstApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _call(
        'pharmacy_gst_home',
        _period == null ? const {} : {'p_period': _period},
      );
      if (!mounted) return;
      if (res['ok'] != true) {
        // A refusal is an ANSWER, not an outage — the backend's own message,
        // and no Retry, because retrying changes nothing.
        setState(() {
          _data = res;
          _loading = false;
        });
        RenderLog.write('c416_gst_denied', 1);
        return;
      }
      setState(() {
        _data = res;
        _period = _s(res['period']);
        _loading = false;
      });
      RenderLog.write('c416_gst_home', 1);
      RenderLog.write(
        'c416_gst_blocks',
        _rows(_m(res['exports'])['blocks']).length,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _copy('error_generic');
      });
    }
  }

  String _copy(String k) => _s(_m(_data['copy'])[k]);

  void _toast(String message) {
    if (!mounted || message.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final denied = _data.isNotEmpty && _data['ok'] != true;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_s(_data['title']).isEmpty ? ' ' : _s(_data['title']),
                style: Ds.t.subtitle),
            if (_s(_data['period_label']).isNotEmpty)
              Text(_s(_data['period_label']), style: Ds.t.caption),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? _skeleton()
            : denied
            ? _denied()
            : _error != null
            ? _errorState()
            : _body(),
      ),
    );
  }

  Widget _skeleton() => ListView(
    padding: EdgeInsets.all(Ds.space.x16),
    children: List.generate(
      4,
      (_) => Container(
        height: Ds.space.x48 + Ds.space.x24,
        margin: EdgeInsets.only(bottom: Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
        ),
      ),
    ),
  );

  Widget _denied() => Center(
    child: Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Text(
        _s(_data['message']),
        textAlign: TextAlign.center,
        style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
      ),
    ),
  );

  Widget _errorState() => ListView(
    padding: EdgeInsets.all(Ds.space.x24),
    children: [
      SizedBox(height: Ds.space.x48),
      Text(_error ?? '', textAlign: TextAlign.center, style: Ds.t.body),
      SizedBox(height: Ds.space.x16),
      Center(
        child: OutlinedButton(
          onPressed: _load,
          child: Text(_copy('retry')),
        ),
      ),
    ],
  );

  Widget _body() => ListView(
    padding: EdgeInsets.fromLTRB(
      Ds.space.x16,
      Ds.space.x16,
      Ds.space.x16,
      Ds.space.x48,
    ),
    children: [
      _monthStrip(),
      SizedBox(height: Ds.space.x12),
      _tabs(),
      SizedBox(height: Ds.space.x24),
      if (_tab == 'position') ..._position(),
      if (_tab == 'purchase') ..._register(_m(_data['purchase']), purchase: true),
      if (_tab == 'sales') ..._register(_m(_data['sales']), purchase: false),
      if (_tab == 'exports') ..._exports(),
    ],
  );

  Widget _monthStrip() {
    final months = _rows(_data['months']);
    return SizedBox(
      height: Ds.touch.minTarget,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: months.length,
        separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
        itemBuilder: (_, i) {
          final mo = months[i];
          final sel = mo['selected'] == true;
          return ChoiceChip(
            selected: sel,
            label: Text(_s(mo['label'])),
            labelStyle: Ds.t.caption.copyWith(
              color: sel ? Colors.white : Ds.c.text,
            ),
            selectedColor: Ds.c.brand,
            backgroundColor: Ds.c.surface,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rChip),
            onSelected: (_) {
              // The backend's own period string, handed straight back.
              _period = _s(mo['period']);
              _load();
            },
          );
        },
      ),
    );
  }

  Widget _tabs() {
    final tabs = _rows(_data['tabs']);
    return SizedBox(
      height: Ds.touch.minTarget,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: tabs.length,
        separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
        itemBuilder: (_, i) {
          final t = tabs[i];
          final sel = _s(t['key']) == _tab;
          return ChoiceChip(
            selected: sel,
            label: Text(_s(t['label'])),
            labelStyle: Ds.t.caption.copyWith(
              color: sel ? Colors.white : Ds.c.text,
            ),
            selectedColor: Ds.c.brand,
            backgroundColor: Ds.c.surface,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rChip),
            onSelected: (_) => setState(() => _tab = _s(t['key'])),
          );
        },
      ),
    );
  }

  List<Widget> _position() {
    final pos = _m(_data['position']);
    final filing = _m(_data['filing']);
    return [
      Text(_s(pos['heading']), style: Ds.t.subtitle),
      SizedBox(height: Ds.space.x12),
      for (final t in _rows(pos['tiles']))
        Container(
          margin: EdgeInsets.only(bottom: Ds.space.x8),
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1,
          ),
          child: Row(
            children: [
              Expanded(child: Text(_s(t['label']), style: Ds.t.body)),
              Text(
                _s(t['value']),
                style: Ds.t.subtitle.copyWith(color: _toneColor(_s(t['tone']))),
              ),
            ],
          ),
        ),
      SizedBox(height: Ds.space.x12),
      Text(
        _s(pos['note']),
        style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
      ),
      SizedBox(height: Ds.space.x24),
      if (_s(_data['gstin_label']).isNotEmpty)
        Text(
          _s(_data['gstin_label']),
          style: Ds.t.caption.copyWith(
            color: _data['has_gstin'] == true
                ? Ds.c.textSecondary
                : Ds.c.warning,
          ),
        ),
      SizedBox(height: Ds.space.x24),
      _filingBanner(filing),
      SizedBox(height: Ds.space.x16),
      SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: FilledButton(
          onPressed: _packBusy ? null : _requestPack,
          style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
          child: Text(
            _packBusy ? _copy('pack_working') : _copy('pack_button'),
          ),
        ),
      ),
    ];
  }

  Widget _filingBanner(Map<String, dynamic> filing) => Container(
    padding: EdgeInsets.all(Ds.space.x16),
    decoration: BoxDecoration(
      color: Ds.c.infoSoft,
      borderRadius: Ds.r.rCard,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, color: Ds.c.info),
        SizedBox(width: Ds.space.x12),
        Expanded(
          child: Text(
            _s(filing['note']),
            style: Ds.t.caption.copyWith(color: Ds.c.text),
          ),
        ),
      ],
    ),
  );

  List<Widget> _register(Map<String, dynamic> reg, {required bool purchase}) {
    final rows = _rows(reg['rows']);
    return [
      Row(
        children: [
          Expanded(child: Text(_s(reg['heading']), style: Ds.t.subtitle)),
          if (purchase)
            TextButton(
              onPressed: _openAddBill,
              child: Text(_s(reg['add_label'])),
            ),
        ],
      ),
      SizedBox(height: Ds.space.x12),
      if (rows.isEmpty && _s(reg['empty']).isNotEmpty)
        Container(
          padding: EdgeInsets.all(Ds.space.x24),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
          ),
          child: Text(
            _s(reg['empty']),
            textAlign: TextAlign.center,
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
        ),
      for (final r in rows)
        Container(
          margin: EdgeInsets.only(bottom: Ds.space.x8),
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
                  Expanded(child: Text(_s(r['party']), style: Ds.t.body)),
                  Text(_s(r['taxable_label']), style: Ds.t.body),
                ],
              ),
              SizedBox(height: Ds.space.x4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        _s(r['invoice_no']),
                        _s(r['date_label']),
                        _s(r['lines_label']),
                        if (_s(r['source_label']).isNotEmpty)
                          _s(r['source_label']),
                      ].where((e) => e.isNotEmpty).join(' · '),
                      style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                    ),
                  ),
                  Text(
                    _s(r['tax_label']),
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                  ),
                ],
              ),
              if (purchase && r['has_gstin'] != true) ...[
                SizedBox(height: Ds.space.x4),
                Text(
                  _s(r['gstin']),
                  style: Ds.t.caption.copyWith(color: Ds.c.warning),
                ),
              ],
            ],
          ),
        ),
      if (rows.isNotEmpty) ...[
        SizedBox(height: Ds.space.x12),
        Row(
          children: [
            Expanded(
              child: Text(
                _s(reg['total_label']),
                style: Ds.t.subtitle,
              ),
            ),
            Text(_s(reg['tax_label']), style: Ds.t.subtitle),
          ],
        ),
      ],
    ];
  }

  List<Widget> _exports() {
    final ex = _m(_data['exports']);
    return [
      Text(_s(ex['heading']), style: Ds.t.subtitle),
      SizedBox(height: Ds.space.x8),
      Text(
        _s(ex['note']),
        style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
      ),
      SizedBox(height: Ds.space.x24),
      for (final b in _rows(ex['blocks'])) _exportBlock(b),
    ];
  }

  Widget _exportBlock(Map<String, dynamic> b) {
    final cols = _rows(b['columns']);
    final rows = _rows(b['rows']);
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x16),
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
              Expanded(child: Text(_s(b['title']), style: Ds.t.body)),
              TextButton(
                onPressed: () => _copyCsv(b),
                child: Text(_copy('copy_button')),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          // Wide tables scroll inside their own card rather than pushing the
          // page sideways.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: Ds.space.x32 + Ds.space.x8,
              dataRowMinHeight: Ds.space.x32,
              dataRowMaxHeight: Ds.space.x48,
              columnSpacing: Ds.space.x24,
              columns: [
                for (final c in cols)
                  DataColumn(
                    numeric: _s(c['align']) == 'right',
                    label: Text(
                      _s(c['label']),
                      style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                    ),
                  ),
              ],
              rows: [
                for (final r in rows)
                  DataRow(
                    cells: [
                      for (final c in cols)
                        DataCell(
                          Text(_s(r[_s(c['key'])]), style: Ds.t.caption),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyCsv(Map<String, dynamic> b) async {
    // The clipboard gets the BACKEND's csv, header included — not a table this
    // screen re-serialised, which is how a copied export starts disagreeing
    // with the register it came from.
    final csv = '${_s(b['csv_header'])}\n${_s(b['csv'])}';
    await Clipboard.setData(ClipboardData(text: csv));
    if (!mounted) return;
    _toast(_copy('copied'));
    await _call('pharmacy_gst_export_log', {
      'p_period': _period,
      'p_key': _s(b['key']),
      'p_rows': _rows(b['rows']).length,
    });
  }

  Future<void> _requestPack() async {
    setState(() => _packBusy = true);
    final res = await _call('pharmacy_gst_pack_request', {'p_period': _period});
    if (!mounted) return;
    if (res['ok'] != true) {
      setState(() => _packBusy = false);
      _toast(_s(res['message']));
      return;
    }
    _toast(_s(res['message']));
    _pollPack(_s(res['run_id']), _s(res['poll_ms']));
  }

  // Polls on the BACKEND's own interval and stops on the backend's own status.
  // No timeout is invented here.
  void _pollPack(String runId, String pollMs) {
    _poll?.cancel();
    final ms = int.tryParse(pollMs) ?? 1500;
    var tries = 0;
    _poll = Timer.periodic(Duration(milliseconds: ms), (t) async {
      tries++;
      final st = await _call('pharmacy_gst_pack_status', {'p_run_id': runId});
      if (!mounted) return;
      final status = _s(st['status']);
      if (status == 'ready') {
        t.cancel();
        setState(() => _packBusy = false);
        _toast(_s(st['message']));
        final url = await PharmacyGstApi.signedPack(
          _s(st['bucket']),
          _s(st['path']),
        );
        if (url != null) {
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        }
      } else if (status == 'failed' || tries > 40) {
        t.cancel();
        setState(() => _packBusy = false);
        _toast(_s(st['message']));
      }
    });
  }

  Future<void> _openAddBill() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _AddBillSheet(
        copy: _m(_data['copy']),
        call: _call,
        onToast: _toast,
      ),
    );
    if (saved == true) _load();
  }
}

// ─────────────────────────── an outside purchase bill ───────────────────────

class _AddBillSheet extends StatefulWidget {
  final Map<String, dynamic> copy;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call;
  final void Function(String) onToast;

  const _AddBillSheet({
    required this.copy,
    required this.call,
    required this.onToast,
  });

  @override
  State<_AddBillSheet> createState() => _AddBillSheetState();
}

class _AddBillSheetState extends State<_AddBillSheet> {
  final _supplier = TextEditingController();
  final _gstin = TextEditingController();
  final _invoice = TextEditingController();
  final _date = TextEditingController();
  final _lines = <Map<String, TextEditingController>>[];
  bool _saving = false;

  String _c(String k) => _s(widget.copy[k]);

  @override
  void initState() {
    super.initState();
    _addLine();
  }

  void _addLine() {
    _lines.add({
      'product_name': TextEditingController(),
      'hsn': TextEditingController(),
      'qty': TextEditingController(),
      'taxable': TextEditingController(),
      'rate': TextEditingController(),
    });
  }

  @override
  void dispose() {
    _supplier.dispose();
    _gstin.dispose();
    _invoice.dispose();
    _date.dispose();
    for (final l in _lines) {
      for (final c in l.values) {
        c.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final res = await widget.call('pharmacy_gst_bill_save', {
      'p': {
        'supplier_name': _supplier.text.trim(),
        'supplier_gstin': _gstin.text.trim(),
        'invoice_no': _invoice.text.trim(),
        'invoice_date': _date.text.trim(),
        'lines': [
          for (final l in _lines)
            if (l['taxable']!.text.trim().isNotEmpty)
              {
                'product_name': l['product_name']!.text.trim(),
                'hsn': l['hsn']!.text.trim(),
                'qty': l['qty']!.text.trim(),
                'taxable': l['taxable']!.text.trim(),
                'rate': l['rate']!.text.trim(),
              },
        ],
      },
    });
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onToast(_s(res['message']));
    if (res['ok'] == true) Navigator.of(context).pop(true);
  }

  InputDecoration _dec(String label) => InputDecoration(
    labelText: label,
    filled: true,
    fillColor: Ds.c.bg,
    border: OutlineInputBorder(borderRadius: Ds.r.rButton),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: Ds.space.x16,
      right: Ds.space.x16,
      top: Ds.space.x24,
      bottom: MediaQuery.of(context).viewInsets.bottom + Ds.space.x24,
    ),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_c('add_title'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x16),
          TextField(controller: _supplier, decoration: _dec(_c('f_supplier'))),
          SizedBox(height: Ds.space.x12),
          TextField(controller: _gstin, decoration: _dec(_c('f_gstin'))),
          SizedBox(height: Ds.space.x12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _invoice,
                  decoration: _dec(_c('f_invoice')),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: TextField(
                  controller: _date,
                  decoration: _dec(_c('f_date')),
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x24),
          for (var i = 0; i < _lines.length; i++) ...[
            TextField(
              controller: _lines[i]['product_name'],
              decoration: _dec(_c('f_hsn').isEmpty ? '' : 'Item ${i + 1}'),
            ),
            SizedBox(height: Ds.space.x8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _lines[i]['hsn'],
                    decoration: _dec(_c('f_hsn')),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: TextField(
                    controller: _lines[i]['taxable'],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: _dec(_c('f_taxable')),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: TextField(
                    controller: _lines[i]['rate'],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: _dec(_c('f_rate')),
                  ),
                ),
              ],
            ),
            SizedBox(height: Ds.space.x12),
          ],
          TextButton(
            onPressed: () => setState(_addLine),
            child: const Text('+'),
          ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
              child: Text(_saving ? _c('saving') : _c('save')),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The way in, drawn from `pharmacy_gst_entry()` and nowhere else.
///
/// It asks for its OWN entry on first build rather than relying on the shell to
/// have loaded it. #411 and #412 both park their entry call in home_shell's
/// boot, which works but couples a pharmacy feature to a file five commands are
/// queued behind; this tile needs nothing from the shell, so wherever it is
/// dropped it simply works. The notifier is still shared and still loaded once.
class GstMenuTile extends StatefulWidget {
  final VoidCallback? onBeforeOpen;
  const GstMenuTile({super.key, this.onBeforeOpen});

  static IconData get icon => Icons.receipt_long_outlined;

  @override
  State<GstMenuTile> createState() => _GstMenuTileState();
}

class _GstMenuTileState extends State<GstMenuTile> {
  @override
  void initState() {
    super.initState();
    if (GstEntry.value.value.isEmpty) GstEntry.load();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<String, dynamic>>(
        valueListenable: GstEntry.value,
        builder: (context, entry, _) {
          if (entry['show'] != true) return const SizedBox.shrink();
          RenderLog.write('c416_gst_entry_tile', 1);
          return InkWell(
            onTap: () {
              widget.onBeforeOpen?.call();
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const PharmacyGstScreen(),
                ),
              );
            },
            borderRadius: Ds.r.rButton,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x4,
                vertical: Ds.space.x12,
              ),
              child: Row(
                children: [
                  Icon(GstMenuTile.icon, size: Ds.t.subtitleSize, color: Ds.c.brand),
                  SizedBox(width: Ds.space.x12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_s(entry['label']), style: Ds.t.bodyStrong),
                        if (_s(entry['sub_label']).isNotEmpty)
                          Text(_s(entry['sub_label']), style: Ds.t.caption),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
}
