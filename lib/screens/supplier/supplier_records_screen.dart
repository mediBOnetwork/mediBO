// CHANGE #403 — the supplier's records: documents, deductions, sales, bills.
//
// Four things he could not do from his own login before this screen existed:
// download a document (the purchase order we sent him, a copy of a bill he
// sent us, a monthly statement), see WHY money came off a bill instead of
// arguing about it on the phone, read what he sold mediBO this month against
// last month, and find an old bill by its number, its date or its amount.
//
// All four are one payload each, printed. This file computes nothing: not a
// rupee, not a percentage, not a date, not a plural, not an empty state, not
// even the TAB LIST — supplier_records_home() names the tabs, so a fifth
// record type is an INSERT in `supplier_record_tab` and no deploy here. The
// only thing it decides on its own is which colour a backend tone maps to,
// which is what supplierTone() has always been for.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../services/supplier_account_state.dart';
import '../../services/supplier_records_api.dart';
import '../../utils/render_log.dart';

// ═══════════════════════════════════════════════════════════════════════════
// THE SHELL — the tabs are the payload's, in the payload's order
// ═══════════════════════════════════════════════════════════════════════════
class SupplierRecordsScreen extends StatefulWidget {
  /// Test seam. Null in production -> the real RPCs.
  final SupplierRpc? rpc;
  const SupplierRecordsScreen({super.key, this.rpc});

  @override
  State<SupplierRecordsScreen> createState() => _SupplierRecordsScreenState();
}

class _SupplierRecordsScreenState extends State<SupplierRecordsScreen>
    with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _home;
  TabController? _tabs;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : SupplierApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final h = await _call('supplier_records_home', const {});
    if (!mounted) return;
    final tabs = supplierRows(h['tabs']);
    setState(() {
      _home = h;
      _tabs?.dispose();
      _tabs = tabs.isEmpty ? null : TabController(length: tabs.length, vsync: this);
    });
    RenderLog.write('c403_records', tabs.length);
  }

  @override
  Widget build(BuildContext context) {
    final h = _home;
    if (h == null) {
      return Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(),
        body: const _Skeleton(),
      );
    }
    if (h['ok'] == false) {
      return Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(),
        body: _Refusal(message: supplierStr(h, 'message')),
      );
    }
    final tabs = supplierRows(h['tabs']);
    final ctl = _tabs;
    if (tabs.isEmpty || ctl == null) {
      return Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(title: Text(supplierStr(h, 'title'))),
        body: _Refusal(message: supplierStr(h, 'subtitle')),
      );
    }

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(supplierStr(h, 'title')),
        bottom: TabBar(
          controller: ctl,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: Ds.c.brand,
          unselectedLabelColor: Ds.c.textSecondary,
          indicatorColor: Ds.c.brand,
          tabs: [for (final t in tabs) Tab(text: supplierStr(t, 'label'))],
        ),
      ),
      body: TabBarView(
        controller: ctl,
        children: [
          for (final t in tabs) _tabBody(supplierStr(t, 'key')),
        ],
      ),
    );
  }

  /// A tab key this build has never heard of renders nothing rather than
  /// throwing — the backend may ship a fifth tab before this app does.
  Widget _tabBody(String key) => switch (key) {
        'documents' => SupplierDocumentsTab(rpc: widget.rpc),
        'debits' => SupplierDebitsTab(rpc: widget.rpc),
        'sales' => SupplierSalesTab(rpc: widget.rpc),
        'bills' => SupplierBillsTab(rpc: widget.rpc),
        _ => const SizedBox.shrink(),
      };
}

// ═══════════════════════════════════════════════════════════════════════════
// 1. DOCUMENTS
// ═══════════════════════════════════════════════════════════════════════════
class SupplierDocumentsTab extends StatefulWidget {
  final SupplierRpc? rpc;
  final Future<String> Function(String bucket, String path)? sign;
  final Future<void> Function(String url)? open;
  const SupplierDocumentsTab({super.key, this.rpc, this.sign, this.open});

  @override
  State<SupplierDocumentsTab> createState() => SupplierDocumentsTabState();
}

class SupplierDocumentsTabState extends State<SupplierDocumentsTab> {
  Map<String, dynamic>? _payload;
  String _busyKey = '';

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : SupplierApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await _call('supplier_documents_list', const {});
    if (!mounted) return;
    setState(() => _payload = p);
    RenderLog.write('c403_documents',
        supplierRows(p['groups']).fold<int>(0, (a, g) => a + supplierRows(g['rows']).length));
  }

  Future<String> _sign(String bucket, String path) => widget.sign != null
      ? widget.sign!(bucket, path)
      : SupplierRecordsApi.signedUrl(bucket, path);

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    if (widget.open != null) return widget.open!(url);
    await launchUrl(Uri.parse(url),
        webOnlyWindowName: '_blank', mode: LaunchMode.externalApplication);
  }

  void _toast(String message, Object? tone) {
    if (message.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: supplierTone(tone)));
  }

  /// Ask, then poll on the BACKEND's own interval until it is ready. Never a
  /// locally invented timeout: the loop stops when the payload stops saying
  /// `building`, and the refusal it prints is the backend's sentence.
  Future<void> download(String kind, String ref) async {
    final key = '$kind/$ref';
    if (_busyKey.isNotEmpty) return;
    setState(() => _busyKey = key);
    try {
      var res = await _call('supplier_doc_request', {'p_kind': kind, 'p_ref': ref});
      var poll = SupplierDocPoll.from(res);
      var tries = 0;
      while (poll != null && tries < 20) {
        await Future<void>.delayed(Duration(milliseconds: poll.pollMs));
        if (!mounted) return;
        res = await _call('supplier_doc_status', {'p_id': poll.docId});
        poll = SupplierDocPoll.from(res);
        tries++;
      }
      if (!mounted) return;
      if (res['ok'] != true) {
        _toast(supplierStr(res, 'message'), 'danger');
        return;
      }
      if (supplierStr(res, 'status') == 'building') {
        _toast(supplierStr(res, 'message'), 'info');
        return;
      }
      final url = await _sign(supplierStr(res, 'bucket'), supplierStr(res, 'path'));
      await _open(url);
      await _load();
    } finally {
      if (mounted) setState(() => _busyKey = '');
    }
  }

  Future<void> openSource(String bucket, String path) async {
    final url = await _sign(bucket, path);
    await _open(url);
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    if (p == null) return const _Skeleton();
    if (p['ok'] == false) return _Refusal(message: supplierStr(p, 'message'));

    final groups = supplierRows(p['groups']);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(supplierStr(p, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        for (final g in groups) ...[
          Text(supplierStr(g, 'heading'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          if (supplierRows(g['rows']).isEmpty)
            _Empty(text: supplierStr(g, 'empty_label'))
          else
            for (final r in supplierRows(g['rows']))
              _DocRow(
                row: r,
                downloadLabel: supplierStr(p, 'download_label'),
                buildingLabel: supplierStr(p, 'building_label'),
                busy: _busyKey == '${supplierStr(r, 'kind')}/${supplierStr(r, 'ref')}',
                onDownload: () =>
                    download(supplierStr(r, 'kind'), supplierStr(r, 'ref')),
                onSource: () => openSource(
                    supplierStr(r, 'source_bucket'), supplierStr(r, 'source_path')),
              ),
          SizedBox(height: Ds.space.x24),
        ],
      ],
    );
  }
}

class _DocRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final String downloadLabel;
  final String buildingLabel;
  final bool busy;
  final VoidCallback onDownload;
  final VoidCallback onSource;

  const _DocRow({
    required this.row,
    required this.downloadLabel,
    required this.buildingLabel,
    required this.busy,
    required this.onDownload,
    required this.onSource,
  });

  @override
  Widget build(BuildContext context) {
    final sourceLabel = supplierStr(row, 'source_label');
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x8),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(supplierStr(row, 'title'), style: Ds.t.bodyStrong),
                SizedBox(height: Ds.space.x4),
                Text(supplierStr(row, 'subtitle'), style: Ds.t.caption),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x12),
          if (sourceLabel.isNotEmpty)
            TextButton(
              onPressed: onSource,
              child: Text(sourceLabel,
                  style: Ds.t.caption.copyWith(color: Ds.c.brand)),
            ),
          SizedBox(
            height: Ds.touch.minTarget,
            child: TextButton.icon(
              onPressed: busy ? null : onDownload,
              icon: busy
                  ? SizedBox(
                      width: Ds.space.x16,
                      height: Ds.space.x16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Ds.c.brand))
                  : Icon(Icons.download_outlined, color: Ds.c.brand),
              label: Text(busy ? buildingLabel : downloadLabel,
                  style: Ds.t.body.copyWith(color: Ds.c.brand)),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 2. DEDUCTIONS
// ═══════════════════════════════════════════════════════════════════════════
class SupplierDebitsTab extends StatefulWidget {
  final SupplierRpc? rpc;
  const SupplierDebitsTab({super.key, this.rpc});

  @override
  State<SupplierDebitsTab> createState() => _SupplierDebitsTabState();
}

class _SupplierDebitsTabState extends State<SupplierDebitsTab> {
  Map<String, dynamic>? _payload;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : SupplierApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await _call('supplier_debits_list', const {});
    if (!mounted) return;
    setState(() => _payload = p);
    RenderLog.write('c403_debits', supplierRows(p['rows']).length);
  }

  @override
  Widget build(BuildContext context) =>
      SupplierDebitsView(payload: _payload);
}

class SupplierDebitsView extends StatelessWidget {
  final Map<String, dynamic>? payload;
  const SupplierDebitsView({super.key, required this.payload});

  @override
  Widget build(BuildContext context) {
    final p = payload;
    if (p == null) return const _Skeleton();
    if (p['ok'] == false) return _Refusal(message: supplierStr(p, 'message'));

    final rows = supplierRows(p['rows']);
    final summary = supplierRows(p['summary']);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(supplierStr(p, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        if (summary.isNotEmpty) _TileRow(tiles: summary),
        if (rows.isEmpty) ...[
          SizedBox(height: Ds.space.x24),
          _Empty(text: supplierStr(p, 'empty_label')),
        ] else ...[
          SizedBox(height: Ds.space.x16),
          Text(supplierStr(p, 'payable_note'),
              style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          SizedBox(height: Ds.space.x16),
          for (final r in rows) _DebitCard(row: r),
        ],
      ],
    );
  }
}

class _DebitCard extends StatelessWidget {
  final Map<String, dynamic> row;
  const _DebitCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final note = supplierStr(row, 'note');
    final photoLabel = supplierStr(row, 'photo_label');
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(supplierStr(row, 'product_name'),
                    style: Ds.t.bodyStrong),
              ),
              SizedBox(width: Ds.space.x12),
              Text(supplierStr(row, 'amount_label'),
                  style: Ds.t.bodyStrong.copyWith(color: Ds.c.danger)),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              _Chip(
                  label: supplierStr(row, 'source_label'),
                  tone: 'info'),
              _Chip(
                  label: supplierStr(row, 'status_label'),
                  tone: supplierStr(row, 'status_tone')),
              _Chip(label: supplierStr(row, 'qty_label'), tone: ''),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          _KeyLine(
              label: supplierStr(row, 'ref_caption'),
              value: supplierStr(row, 'ref_label')),
          _KeyLine(label: '', value: supplierStr(row, 'reason_label')),
          if (note.isNotEmpty) _KeyLine(label: '', value: note),
          SizedBox(height: Ds.space.x8),
          Text(supplierStr(row, 'effect_label'),
              style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          SizedBox(height: Ds.space.x4),
          Row(
            children: [
              Expanded(
                  child: Text(supplierStr(row, 'at_label'), style: Ds.t.caption)),
              if (row['has_photo'] == true && photoLabel.isNotEmpty)
                Row(
                  children: [
                    Icon(Icons.photo_outlined,
                        size: Ds.space.x16, color: Ds.c.textSecondary),
                    SizedBox(width: Ds.space.x4),
                    Text(photoLabel, style: Ds.t.caption),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 3. MONTHLY SALES
// ═══════════════════════════════════════════════════════════════════════════
class SupplierSalesTab extends StatefulWidget {
  final SupplierRpc? rpc;
  const SupplierSalesTab({super.key, this.rpc});

  @override
  State<SupplierSalesTab> createState() => _SupplierSalesTabState();
}

class _SupplierSalesTabState extends State<SupplierSalesTab> {
  Map<String, dynamic>? _payload;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : SupplierApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  Future<void> _load(String? month) async {
    final p = await _call('supplier_sales_summary',
        month == null ? const {} : {'p_month': month});
    if (!mounted) return;
    setState(() => _payload = p);
    RenderLog.write('c403_sales', supplierRows(p['tiles']).length);
  }

  @override
  Widget build(BuildContext context) =>
      SupplierSalesView(payload: _payload, onMonth: _load);
}

class SupplierSalesView extends StatelessWidget {
  final Map<String, dynamic>? payload;
  final void Function(String month)? onMonth;
  const SupplierSalesView({super.key, required this.payload, this.onMonth});

  @override
  Widget build(BuildContext context) {
    final p = payload;
    if (p == null) return const _Skeleton();
    if (p['ok'] == false) return _Refusal(message: supplierStr(p, 'message'));

    final months = supplierRows(p['months']);
    final tiles = supplierRows(p['tiles']);
    final top = supplierRows(p['top_products']);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        if (months.isNotEmpty)
          SizedBox(
            height: Ds.touch.minTarget,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final m in months)
                  Padding(
                    padding: EdgeInsets.only(right: Ds.space.x8),
                    child: ChoiceChip(
                      label: Text(supplierStr(m, 'label')),
                      selected: m['selected'] == true,
                      onSelected: (_) => onMonth?.call(supplierStr(m, 'ref')),
                    ),
                  ),
              ],
            ),
          ),
        SizedBox(height: Ds.space.x24),
        _TileRow(tiles: tiles),
        SizedBox(height: Ds.space.x32),
        Text(supplierStr(p, 'top_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (top.isEmpty)
          _Empty(text: supplierStr(p, 'top_empty'))
        else
          for (final t in top)
            Container(
              margin: EdgeInsets.only(bottom: Ds.space.x8),
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x16, vertical: Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                boxShadow: Ds.elevation.e1,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(supplierStr(t, 'product_name'), style: Ds.t.body),
                        SizedBox(height: Ds.space.x4),
                        Text(supplierStr(t, 'qty_label'), style: Ds.t.caption),
                      ],
                    ),
                  ),
                  SizedBox(width: Ds.space.x12),
                  Text(supplierStr(t, 'amount_label'), style: Ds.t.bodyStrong),
                ],
              ),
            ),
        SizedBox(height: Ds.space.x24),
        Text(supplierStr(p, 'note'), style: Ds.t.caption),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 4. BILL ARCHIVE
// ═══════════════════════════════════════════════════════════════════════════
class SupplierBillsTab extends StatefulWidget {
  final SupplierRpc? rpc;
  const SupplierBillsTab({super.key, this.rpc});

  @override
  State<SupplierBillsTab> createState() => SupplierBillsTabState();
}

class SupplierBillsTabState extends State<SupplierBillsTab> {
  Map<String, dynamic>? _payload;
  final TextEditingController _q = TextEditingController();
  final TextEditingController _from = TextEditingController();
  final TextEditingController _to = TextEditingController();
  final TextEditingController _min = TextEditingController();
  final TextEditingController _max = TextEditingController();

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : SupplierApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    search();
  }

  @override
  void dispose() {
    for (final c in [_q, _from, _to, _min, _max]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Only the filters the user actually filled are sent — an empty box is an
  /// ABSENT parameter, never an empty string the backend has to interpret.
  Map<String, dynamic> filters() {
    final f = <String, dynamic>{};
    if (_q.text.trim().isNotEmpty) f['p_q'] = _q.text.trim();
    if (_from.text.trim().isNotEmpty) f['p_from'] = _from.text.trim();
    if (_to.text.trim().isNotEmpty) f['p_to'] = _to.text.trim();
    if (_min.text.trim().isNotEmpty) f['p_min'] = _min.text.trim();
    if (_max.text.trim().isNotEmpty) f['p_max'] = _max.text.trim();
    return f;
  }

  Future<void> search() async {
    final p = await _call('supplier_bill_search', filters());
    if (!mounted) return;
    setState(() => _payload = p);
    RenderLog.write('c403_bills', supplierRows(p['rows']).length);
  }

  void clear() {
    for (final c in [_q, _from, _to, _min, _max]) {
      c.clear();
    }
    search();
  }

  Future<void> openDetail(String id) async {
    final d = await _call('supplier_bill_detail', {'p_id': id});
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: SupplierBillDetailView(payload: d),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    if (p == null) return const _Skeleton();
    if (p['ok'] == false) return _Refusal(message: supplierStr(p, 'message'));

    final rows = supplierRows(p['rows']);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(supplierStr(p, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        _Field(controller: _q, label: supplierStr(p, 'search_hint')),
        SizedBox(height: Ds.space.x12),
        Row(
          children: [
            Expanded(
                child: _Field(
                    controller: _from, label: supplierStr(p, 'from_label'))),
            SizedBox(width: Ds.space.x12),
            Expanded(
                child:
                    _Field(controller: _to, label: supplierStr(p, 'to_label'))),
          ],
        ),
        SizedBox(height: Ds.space.x12),
        Row(
          children: [
            Expanded(
                child: _Field(
                    controller: _min,
                    label: supplierStr(p, 'min_label'),
                    number: true)),
            SizedBox(width: Ds.space.x12),
            Expanded(
                child: _Field(
                    controller: _max,
                    label: supplierStr(p, 'max_label'),
                    number: true)),
          ],
        ),
        SizedBox(height: Ds.space.x16),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: Ds.touch.minTarget,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
                  onPressed: search,
                  child: Text(supplierStr(p, 'search_label')),
                ),
              ),
            ),
            SizedBox(width: Ds.space.x12),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: clear,
                child: Text(supplierStr(p, 'clear_label')),
              ),
            ),
          ],
        ),
        SizedBox(height: Ds.space.x24),
        Text(supplierStr(p, 'count_label'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        if (rows.isEmpty)
          _Empty(text: supplierStr(p, 'empty_label'))
        else
          for (final r in rows)
            InkWell(
              onTap: () => openDetail(supplierStr(r, 'id')),
              borderRadius: Ds.r.rCard,
              child: Container(
                margin: EdgeInsets.only(bottom: Ds.space.x8),
                padding: EdgeInsets.all(Ds.space.x16),
                constraints:
                    BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rCard,
                  boxShadow: Ds.elevation.e1,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(supplierStr(r, 'title'), style: Ds.t.bodyStrong),
                          SizedBox(height: Ds.space.x4),
                          Text(supplierStr(r, 'date_label'),
                              style: Ds.t.caption),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(supplierStr(r, 'amount_label'),
                            style: Ds.t.bodyStrong),
                        SizedBox(height: Ds.space.x4),
                        _Chip(
                            label: supplierStr(r, 'status_label'),
                            tone: supplierStr(r, 'status_tone')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class SupplierBillDetailView extends StatelessWidget {
  final Map<String, dynamic> payload;
  const SupplierBillDetailView({super.key, required this.payload});

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return _Refusal(message: supplierStr(payload, 'message'));
    }
    final lines = supplierRows(payload['lines']);
    final pays = supplierRows(payload['payments']);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Row(
          children: [
            Expanded(
                child:
                    Text(supplierStr(payload, 'title'), style: Ds.t.title)),
            SizedBox(width: Ds.space.x12),
            _Chip(
                label: supplierStr(payload, 'verify_label'),
                tone: supplierStr(payload, 'verify_tone')),
          ],
        ),
        SizedBox(height: Ds.space.x4),
        Text(supplierStr(payload, 'amount_label'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x16),
        for (final h in supplierRows(payload['header']))
          _KeyLine(
              label: supplierStr(h, 'label'), value: supplierStr(h, 'value')),
        SizedBox(height: Ds.space.x24),
        Text(supplierStr(payload, 'lines_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (lines.isEmpty)
          _Empty(text: supplierStr(payload, 'lines_empty'))
        else
          for (final l in lines)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(supplierStr(l, 'product_name'), style: Ds.t.body),
                        SizedBox(height: Ds.space.x4),
                        Text(supplierStr(l, 'qty_label'), style: Ds.t.caption),
                      ],
                    ),
                  ),
                  SizedBox(width: Ds.space.x12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(supplierStr(l, 'amount_label'),
                          style: Ds.t.bodyStrong),
                      SizedBox(height: Ds.space.x4),
                      _Chip(
                          label: supplierStr(l, 'verify_label'),
                          tone: supplierStr(l, 'verify_tone')),
                    ],
                  ),
                ],
              ),
            ),
        SizedBox(height: Ds.space.x24),
        Text(supplierStr(payload, 'payments_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (pays.isEmpty)
          _Empty(text: supplierStr(payload, 'payments_empty'))
        else ...[
          for (final pay in pays)
            _KeyLine(
                label: supplierStr(pay, 'at_label'),
                value: supplierStr(pay, 'amount_label')),
          SizedBox(height: Ds.space.x8),
          Text(supplierStr(payload, 'paid_label'), style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x24),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SHARED PIECES
// ═══════════════════════════════════════════════════════════════════════════
class _TileRow extends StatelessWidget {
  final List<Map<String, dynamic>> tiles;
  const _TileRow({required this.tiles});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 520;
          final children = [
            for (final t in tiles)
              SizedBox(
                width: wide
                    ? (box.maxWidth - Ds.space.x12 * (tiles.length - 1)) /
                        tiles.length
                    : box.maxWidth,
                child: _Tile(tile: t),
              ),
          ];
          return Wrap(
            spacing: Ds.space.x12,
            runSpacing: Ds.space.x12,
            children: children,
          );
        },
      );
}

class _Tile extends StatelessWidget {
  final Map<String, dynamic> tile;
  const _Tile({required this.tile});

  @override
  Widget build(BuildContext context) {
    final caption = supplierStr(tile, 'caption');
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: supplierToneSoft(tile['tone']),
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(supplierStr(tile, 'label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(supplierStr(tile, 'value'),
              style: Ds.t.subtitle.copyWith(color: supplierTone(tile['tone']))),
          if (caption.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(caption, style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String tone;
  const _Chip({required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: supplierToneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label, style: Ds.t.caption.copyWith(color: supplierTone(tone))),
    );
  }
}

class _KeyLine extends StatelessWidget {
  final String label;
  final String value;
  const _KeyLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty) ...[
            SizedBox(
              width: 110,
              child: Text(label, style: Ds.t.caption),
            ),
            SizedBox(width: Ds.space.x8),
          ],
          Expanded(child: Text(value, style: Ds.t.body)),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool number;
  const _Field(
      {required this.controller, required this.label, this.number = false});

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        style: Ds.t.body,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: Ds.t.caption,
          filled: true,
          fillColor: Ds.c.bg,
          border: OutlineInputBorder(borderRadius: Ds.r.rButton),
        ),
      );
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Text(text, style: Ds.t.caption),
      );
}

class _Refusal extends StatelessWidget {
  final String message;
  const _Refusal({required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(message, style: Ds.t.body, textAlign: TextAlign.center),
        ),
      );
}

/// A skeleton, not a bare spinner — the shape of what is coming.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 5; i++)
            Container(
              height: Ds.space.x48 + Ds.space.x16,
              margin: EdgeInsets.only(bottom: Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
              ),
            ),
        ],
      );
}
