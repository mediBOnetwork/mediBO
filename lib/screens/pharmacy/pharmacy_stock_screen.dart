// CMD #412 — the pharmacy's shelf.
//
// The screen a pharmacy opens to ask "what do I actually have, and what is it
// worth?" — and the answer builds itself: every mediBO order that is delivered
// becomes rows here on its own, with the batch, the expiry and the rate that
// was billed. Nothing has to be typed for the common case, which is the whole
// reason a standalone inventory app dies and this one should not.
//
// THIS FILE COMPUTES NOTHING. Every rupee, quantity, badge, tone, plural,
// state line, empty state and toast is a finished string from
// `pharmacy_stock_home()` / `pharmacy_stock_moves()`. The screen decides no
// threshold — "low", "out", "near expiry" and "negative" are the BACKEND's
// verdict per lot (`_phs_lot_state`), so the header tile and the row badge can
// never disagree.
//
// Negative stock is drawn LOUDLY rather than hidden: it is the shop telling
// itself that something was sold the shelf never knew it had, which is the
// exact list worth fixing. It is never an error and never blocks a bill.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_stock_api.dart';
import '../../utils/render_log.dart';

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

/// The backend names a tone; this is the only place a tone becomes a colour,
/// and it is a lookup, not a judgement.
Color _toneColor(String tone) {
  switch (tone) {
    case 'danger':
      return Ds.c.danger;
    case 'warning':
      return Ds.c.warning;
    case 'muted':
      return Ds.c.textSecondary;
    case 'ok':
    default:
      return Ds.c.brand;
  }
}

Color _toneSoft(String tone) {
  switch (tone) {
    case 'danger':
      return Ds.c.dangerSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'muted':
      return Ds.c.bg;
    case 'ok':
    default:
      return Ds.c.brandSoft;
  }
}

class PharmacyStockScreen extends StatefulWidget {
  /// Test seam. Null in production -> the real RPCs.
  final StockRpc? rpc;
  const PharmacyStockScreen({super.key, this.rpc});

  @override
  State<PharmacyStockScreen> createState() => _PharmacyStockScreenState();
}

class _PharmacyStockScreenState extends State<PharmacyStockScreen> {
  Map<String, dynamic> _data = const {};
  bool _loading = true;
  String? _error;
  String _filter = 'all';
  String _query = '';
  Timer? _debounce;
  final _searchCtl = TextEditingController();

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null
      ? widget.rpc!(fn, p)
      : PharmacyStockApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _call('pharmacy_stock_home', {
        if (_query.trim().isNotEmpty) 'p_q': _query.trim(),
        'p_filter': _filter,
        'p_limit': 40,
        'p_offset': 0,
      });
      if (!mounted) return;
      if (res['ok'] != true) {
        // A refusal is an ANSWER, not an outage: it shows the backend's own
        // message and offers no Retry, because retrying changes nothing.
        setState(() {
          _data = res;
          _loading = false;
          _error = null;
        });
        RenderLog.write('c412_stock_denied', 1);
        return;
      }
      setState(() {
        _data = res;
        _loading = false;
      });
      RenderLog.write('c412_stock_home', 1);
      RenderLog.write('c412_stock_rows', _rows(res['rows']).length);
      if (_s(res['negative_note']).isNotEmpty) {
        RenderLog.write('c412_stock_negative', 1);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _copy('error_generic');
      });
    }
  }

  String _copy(String key) => _s(_m(_data['copy'])[key]);

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _query = v;
      _load();
    });
  }

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
        title: Text(_s(_data['title']).isEmpty ? ' ' : _s(_data['title'])),
      ),
      floatingActionButton: (denied || _loading)
          ? null
          : FloatingActionButton.extended(
              onPressed: _openAddPurchase,
              backgroundColor: Ds.c.brand,
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text(
                _copy('add_button'),
                style: Ds.t.body.copyWith(color: Colors.white),
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
            : _list(),
      ),
    );
  }

  // A skeleton, not a bare spinner: the shape of the answer arrives first.
  Widget _skeleton() => ListView(
    padding: EdgeInsets.all(Ds.space.x16),
    children: List.generate(
      5,
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
          child: Text(_copy('retry').isEmpty ? '' : _copy('retry')),
        ),
      ),
    ],
  );

  Widget _list() {
    final rows = _rows(_data['rows']);
    final empty = _m(_data['empty']);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x48 + Ds.space.x32,
      ),
      children: [
        _tiles(),
        SizedBox(height: Ds.space.x16),
        _searchField(),
        SizedBox(height: Ds.space.x12),
        _filters(),
        if (_s(_data['negative_note']).isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          _negativeNote(),
        ],
        SizedBox(height: Ds.space.x24),
        if (rows.isEmpty && empty.isNotEmpty) _emptyState(empty),
        for (final r in rows) _itemCard(r),
      ],
    );
  }

  Widget _tiles() {
    final tiles = _rows(_data['tiles']);
    return Row(
      children: [
        for (final t in tiles) ...[
          Expanded(
            child: Container(
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                boxShadow: Ds.elevation.e1,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // A stock value of ₹5,489.30 does not fit a quarter of a
                  // 390px phone, and an ellipsis on the ONE number the screen
                  // exists to show is worse than smaller type. Scale it down
                  // instead of truncating it.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _s(t['value']),
                      maxLines: 1,
                      style: Ds.t.subtitle.copyWith(
                        color: _toneColor(_s(t['tone'])),
                      ),
                    ),
                  ),
                  SizedBox(height: Ds.space.x4),
                  Text(
                    _s(t['label']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          if (t != tiles.last) SizedBox(width: Ds.space.x8),
        ],
      ],
    );
  }

  Widget _searchField() => TextField(
    controller: _searchCtl,
    onChanged: _onSearch,
    decoration: InputDecoration(
      hintText: _s(_data['search_hint']),
      prefixIcon: const Icon(Icons.search),
      filled: true,
      fillColor: Ds.c.surface,
      border: OutlineInputBorder(
        borderRadius: Ds.r.rButton,
        borderSide: BorderSide(color: Ds.c.divider),
      ),
    ),
  );

  Widget _filters() {
    final filters = _rows(_data['filters']);
    return SizedBox(
      height: Ds.touch.minTarget,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
        itemBuilder: (_, i) {
          final f = filters[i];
          final selected = f['selected'] == true;
          return ChoiceChip(
            selected: selected,
            label: Text('${_s(f['label'])}  ${_s(f['count'])}'),
            labelStyle: Ds.t.caption.copyWith(
              color: selected ? Colors.white : Ds.c.text,
            ),
            selectedColor: Ds.c.brand,
            backgroundColor: Ds.c.surface,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rChip),
            onSelected: (_) {
              _filter = _s(f['key']);
              _load();
            },
          );
        },
      ),
    );
  }

  Widget _negativeNote() => Container(
    padding: EdgeInsets.all(Ds.space.x16),
    decoration: BoxDecoration(
      color: Ds.c.dangerSoft,
      borderRadius: Ds.r.rCard,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, color: Ds.c.danger),
        SizedBox(width: Ds.space.x12),
        Expanded(
          child: Text(
            _s(_data['negative_note']),
            style: Ds.t.body.copyWith(color: Ds.c.danger),
          ),
        ),
      ],
    ),
  );

  Widget _emptyState(Map<String, dynamic> empty) => Container(
    padding: EdgeInsets.all(Ds.space.x24),
    decoration: BoxDecoration(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
    ),
    child: Column(
      children: [
        Text(_s(empty['title']), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x8),
        Text(
          _s(empty['body']),
          textAlign: TextAlign.center,
          style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
        ),
        SizedBox(height: Ds.space.x16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _openImport,
            child: Text(_copy('import_button')),
          ),
        ),
      ],
    ),
  );

  Widget _itemCard(Map<String, dynamic> r) {
    final badge = _m(r['badge']);
    final batches = _rows(r['batches']);
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(r['product_name']), style: Ds.t.subtitle),
                    if (_s(r['pack_label']).isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(
                        _s(r['pack_label']),
                        style: Ds.t.caption.copyWith(
                          color: Ds.c.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (badge.isNotEmpty) _badge(badge),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _s(r['qty_label']),
                  style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
                ),
              ),
              Text(_s(r['value_label']), style: Ds.t.body),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          Divider(color: Ds.c.divider, height: 1),
          for (final b in batches) _batchRow(r, b),
        ],
      ),
    );
  }

  Widget _badge(Map<String, dynamic> badge) {
    final tone = _s(badge['tone']);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x8,
        vertical: Ds.space.x4,
      ),
      decoration: BoxDecoration(
        color: _toneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(
        _s(badge['label']),
        style: Ds.t.caption.copyWith(color: _toneColor(tone)),
      ),
    );
  }

  Widget _batchRow(Map<String, dynamic> item, Map<String, dynamic> b) {
    final tone = _s(b['tone']);
    return InkWell(
      onTap: () => _openBatchSheet(item, b),
      borderRadius: Ds.r.rButton,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(b['batch_label']), style: Ds.t.body),
                  SizedBox(height: Ds.space.x4),
                  Text(
                    '${_s(b['expiry_label'])} · ${_s(b['cost_label'])}',
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                  ),
                  if (_s(b['state_label']).isNotEmpty) ...[
                    SizedBox(height: Ds.space.x4),
                    Text(
                      _s(b['state_label']),
                      style: Ds.t.caption.copyWith(color: _toneColor(tone)),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(width: Ds.space.x12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _s(b['qty_label']),
                  style: Ds.t.subtitle.copyWith(color: _toneColor(tone)),
                ),
                SizedBox(height: Ds.space.x4),
                Text(
                  _s(b['value_label']),
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── The three write paths, each a sheet ───────────────────────────────────

  Future<void> _openBatchSheet(
    Map<String, dynamic> item,
    Map<String, dynamic> batch,
  ) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _BatchSheet(
        item: item,
        batch: batch,
        copy: _m(_data['copy']),
        reasons: _rows(_data['reasons']),
        call: _call,
        onToast: _toast,
      ),
    );
    if (changed == true) _load();
  }

  Future<void> _openAddPurchase() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _AddPurchaseSheet(
        copy: _m(_data['copy']),
        call: _call,
        onToast: _toast,
        onImport: _openImport,
      ),
    );
    if (added == true) _load();
  }

  Future<void> _openImport() async {
    final applied = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) =>
          _ImportSheet(copy: _m(_data['copy']), call: _call, onToast: _toast),
    );
    if (applied == true) _load();
  }
}

// ─────────────────────────── batch sheet: history + adjust ──────────────────

class _BatchSheet extends StatefulWidget {
  final Map<String, dynamic> item;
  final Map<String, dynamic> batch;
  final Map<String, dynamic> copy;
  final List<Map<String, dynamic>> reasons;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call;
  final void Function(String) onToast;

  const _BatchSheet({
    required this.item,
    required this.batch,
    required this.copy,
    required this.reasons,
    required this.call,
    required this.onToast,
  });

  @override
  State<_BatchSheet> createState() => _BatchSheetState();
}

class _BatchSheetState extends State<_BatchSheet> {
  final _qtyCtl = TextEditingController();
  final _noteCtl = TextEditingController();
  String? _reason;
  bool _saving = false;
  Map<String, dynamic> _history = const {};

  String _c(String k) => _s(widget.copy[k]);

  @override
  void initState() {
    super.initState();
    _qtyCtl.text = _s(widget.batch['qty_label']);
    _loadHistory();
  }

  @override
  void dispose() {
    _qtyCtl.dispose();
    _noteCtl.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final res = await widget.call('pharmacy_stock_moves', {
      'p_stock_id': _s(widget.batch['stock_id']),
      'p_limit': 40,
    });
    if (!mounted) return;
    setState(() => _history = res);
    RenderLog.write('c412_stock_history', 1);
  }

  Future<void> _save() async {
    final qty = num.tryParse(_qtyCtl.text.trim());
    if (qty == null || _reason == null) return;
    setState(() => _saving = true);
    final res = await widget.call('pharmacy_stock_adjust', {
      'p_stock_id': _s(widget.batch['stock_id']),
      'p_new_qty': qty,
      'p_reason': _reason,
      if (_noteCtl.text.trim().isNotEmpty) 'p_note': _noteCtl.text.trim(),
    });
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onToast(_s(res['message']));
    if (res['ok'] == true) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final moves = _rows(_history['rows']);
    return Padding(
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
            Text(_s(widget.item['product_name']), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
            Text(
              '${_s(widget.batch['batch_label'])} · ${_s(widget.batch['expiry_label'])}',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            ),
            SizedBox(height: Ds.space.x24),
            Text(_c('adjust_title'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _qtyCtl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: _c('adjust_qty'),
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
            ),
            SizedBox(height: Ds.space.x12),
            DropdownButtonFormField<String>(
              initialValue: _reason,
              decoration: InputDecoration(
                labelText: _c('adjust_reason'),
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
              items: [
                for (final r in widget.reasons)
                  DropdownMenuItem(
                    value: _s(r['code']),
                    child: Text(_s(r['label'])),
                  ),
              ],
              onChanged: (v) => setState(() => _reason = v),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _noteCtl,
              decoration: InputDecoration(
                labelText: _c('adjust_note'),
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
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
            SizedBox(height: Ds.space.x32),
            Text(_s(_history['title']), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            if (moves.isEmpty && _s(_history['empty']).isNotEmpty)
              Text(
                _s(_history['empty']),
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
              ),
            for (final mv in moves) _moveRow(mv),
          ],
        ),
      ),
    );
  }

  Widget _moveRow(Map<String, dynamic> mv) => Padding(
    padding: EdgeInsets.only(bottom: Ds.space.x12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(mv['kind_label']), style: Ds.t.body),
              SizedBox(height: Ds.space.x4),
              Text(
                [
                  _s(mv['when']),
                  if (_s(mv['actor']).isNotEmpty) _s(mv['actor']),
                  if (_s(mv['reason_label']).isNotEmpty) _s(mv['reason_label']),
                  if (_s(mv['note']).isNotEmpty) _s(mv['note']),
                ].join(' · '),
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
              ),
            ],
          ),
        ),
        SizedBox(width: Ds.space.x12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _s(mv['qty_label']),
              style: Ds.t.body.copyWith(color: _toneColor(_s(mv['tone']))),
            ),
            SizedBox(height: Ds.space.x4),
            Text(
              _s(mv['after_label']),
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            ),
          ],
        ),
      ],
    ),
  );
}

// ─────────────────────────── outside purchase ───────────────────────────────

class _AddPurchaseSheet extends StatefulWidget {
  final Map<String, dynamic> copy;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call;
  final void Function(String) onToast;
  final VoidCallback onImport;

  const _AddPurchaseSheet({
    required this.copy,
    required this.call,
    required this.onToast,
    required this.onImport,
  });

  @override
  State<_AddPurchaseSheet> createState() => _AddPurchaseSheetState();
}

class _AddPurchaseSheetState extends State<_AddPurchaseSheet> {
  final _productCtl = TextEditingController();
  final _batchCtl = TextEditingController();
  final _expiryCtl = TextEditingController();
  final _qtyCtl = TextEditingController();
  final _costCtl = TextEditingController();
  final _supplierCtl = TextEditingController();

  List<Map<String, dynamic>> _hits = const [];
  Map<String, dynamic>? _picked;
  Timer? _debounce;
  bool _saving = false;

  String _c(String k) => _s(widget.copy[k]);

  @override
  void dispose() {
    _debounce?.cancel();
    _productCtl.dispose();
    _batchCtl.dispose();
    _expiryCtl.dispose();
    _qtyCtl.dispose();
    _costCtl.dispose();
    _supplierCtl.dispose();
    super.dispose();
  }

  void _search(String v) {
    _picked = null;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final res = await widget.call('pharmacy_stock_product_search', {
        'p_q': v,
        'p_limit': 20,
      });
      if (!mounted) return;
      setState(() => _hits = _rows(res['rows']));
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final res = await widget.call('pharmacy_stock_add_purchase', {
      'p': {
        if (_picked != null) 'medicine_id': _picked!['medicine_id'],
        'product_name': _picked != null
            ? _s(_picked!['product_name'])
            : _productCtl.text.trim(),
        if (_picked != null) 'pack_label': _s(_picked!['pack_label']),
        'batch_no': _batchCtl.text.trim(),
        'expiry': _expiryCtl.text.trim(),
        'qty': _qtyCtl.text.trim(),
        'unit_cost': _costCtl.text.trim(),
        'supplier_label': _supplierCtl.text.trim(),
      },
    });
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onToast(_s(res['message']));
    if (res['ok'] == true) Navigator.of(context).pop(true);
  }

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
          Row(
            children: [
              Expanded(child: Text(_c('add_title'), style: Ds.t.subtitle)),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(false);
                  widget.onImport();
                },
                child: Text(_c('import_button')),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x16),
          TextField(
            controller: _productCtl,
            onChanged: _search,
            decoration: InputDecoration(
              labelText: _c('f_product'),
              filled: true,
              fillColor: Ds.c.bg,
              border: OutlineInputBorder(borderRadius: Ds.r.rButton),
            ),
          ),
          if (_picked == null)
            for (final h in _hits.take(6))
              ListTile(
                dense: true,
                title: Text(_s(h['product_name']), style: Ds.t.body),
                subtitle: Text(
                  [
                    _s(h['pack_label']),
                    _s(h['mrp_label']),
                  ].where((e) => e.isNotEmpty).join(' · '),
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                ),
                onTap: () => setState(() {
                  _picked = h;
                  _productCtl.text = _s(h['product_name']);
                  _hits = const [];
                }),
              ),
          SizedBox(height: Ds.space.x12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _batchCtl,
                  decoration: InputDecoration(
                    labelText: _c('f_batch'),
                    filled: true,
                    fillColor: Ds.c.bg,
                    border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: TextField(
                  controller: _expiryCtl,
                  decoration: InputDecoration(
                    labelText: _c('f_expiry'),
                    filled: true,
                    fillColor: Ds.c.bg,
                    border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qtyCtl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: _c('f_qty'),
                    filled: true,
                    fillColor: Ds.c.bg,
                    border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: TextField(
                  controller: _costCtl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: _c('f_cost'),
                    filled: true,
                    fillColor: Ds.c.bg,
                    border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          TextField(
            controller: _supplierCtl,
            decoration: InputDecoration(
              labelText: _c('f_supplier'),
              filled: true,
              fillColor: Ds.c.bg,
              border: OutlineInputBorder(borderRadius: Ds.r.rButton),
            ),
          ),
          SizedBox(height: Ds.space.x24),
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

// ─────────────────────────── opening stock: CSV or a photo ──────────────────

class _ImportSheet extends StatefulWidget {
  final Map<String, dynamic> copy;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call;
  final void Function(String) onToast;

  const _ImportSheet({
    required this.copy,
    required this.call,
    required this.onToast,
  });

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  final _csvCtl = TextEditingController();
  Map<String, dynamic> _preview = const {};
  bool _busy = false;

  String _c(String k) => _s(widget.copy[k]);

  @override
  void dispose() {
    _csvCtl.dispose();
    super.dispose();
  }

  Future<void> _readCsv() async {
    if (_csvCtl.text.trim().isEmpty) return;
    setState(() => _busy = true);
    final start = await widget.call('pharmacy_stock_import_start', {
      'p_kind': 'csv',
    });
    final res = await widget.call('pharmacy_stock_import_csv', {
      'p_import_id': _s(start['import_id']),
      'p_text': _csvCtl.text,
    });
    if (!mounted) return;
    setState(() {
      _preview = res;
      _busy = false;
    });
    RenderLog.write('c412_stock_import', 1);
  }

  Future<void> _apply() async {
    setState(() => _busy = true);
    final res = await widget.call('pharmacy_stock_import_apply', {
      'p_import_id': _s(_preview['import_id']),
    });
    if (!mounted) return;
    setState(() => _busy = false);
    widget.onToast(_s(res['message']));
    if (res['ok'] == true) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows(_preview['rows']);
    return Padding(
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
            Text(_c('import_title'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x8),
            Text(
              _c('import_body'),
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            ),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: _csvCtl,
              maxLines: 6,
              decoration: InputDecoration(
                hintText: 'Product,Batch,Expiry,Qty,Rate,MRP',
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
            ),
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: _busy ? null : _readCsv,
                child: Text(_c('import_csv')),
              ),
            ),
            if (_s(_preview['status_label']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x16),
              Text(_s(_preview['status_label']), style: Ds.t.body),
            ],
            if (_s(_preview['error']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(
                _s(_preview['error']),
                style: Ds.t.caption.copyWith(color: Ds.c.danger),
              ),
            ],
            for (final r in rows)
              Padding(
                padding: EdgeInsets.only(top: Ds.space.x12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_s(r['product_name']), style: Ds.t.body),
                          SizedBox(height: Ds.space.x4),
                          Text(
                            '${_s(r['batch_label'])} · ${_s(r['expiry_label'])} · ${_s(r['cost_label'])}',
                            style: Ds.t.caption.copyWith(
                              color: Ds.c.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Text(
                      _s(r['qty_label']),
                      style: Ds.t.body.copyWith(
                        color: _toneColor(_s(r['match_tone'])),
                      ),
                    ),
                  ],
                ),
              ),
            if (_preview['can_apply'] == true) ...[
              SizedBox(height: Ds.space.x24),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: _busy ? null : _apply,
                  style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
                  child: Text(_s(_preview['apply_label'])),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The way in, drawn from `pharmacy_stock_entry()` and nowhere else. A shell
/// that shows this tile holds no label, no icon name and no role test — it just
/// renders whatever the backend answered, or nothing at all.
class StockMenuTile extends StatelessWidget {
  /// Called before navigating, so a sheet or a menu can close itself first.
  final VoidCallback? onBeforeOpen;
  const StockMenuTile({super.key, this.onBeforeOpen});

  static IconData get icon => Icons.inventory_2_outlined;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<String, dynamic>>(
        valueListenable: StockEntry.value,
        builder: (context, entry, _) {
          if (entry['show'] != true) return const SizedBox.shrink();
          RenderLog.write('c412_stock_entry_tile', 1);
          return InkWell(
            onTap: () {
              onBeforeOpen?.call();
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const PharmacyStockScreen(),
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
                  Icon(icon, size: Ds.t.subtitleSize, color: Ds.c.brand),
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
