// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../supabase_config.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../../widgets/ds_tone.dart';

const _kOcrEdgeFn = 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/gemini-ocr';

class SupplierAddMedicineScreen extends StatefulWidget {
  const SupplierAddMedicineScreen({super.key});

  @override
  State<SupplierAddMedicineScreen> createState() => _SupplierAddMedicineScreenState();
}

class _SupplierAddMedicineScreenState extends State<SupplierAddMedicineScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    RenderLog.write('supplier_add_medicine', 'init');
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        color: Ds.c.surface,
        child: TabBar(
          controller: _tabs,
          labelColor: Ds.c.brand,
          unselectedLabelColor: Ds.c.textSecondary,
          indicatorColor: Ds.c.brand,
          tabs: [
            Tab(text: c('supplier_add_medicine.tab_add_company')),
            Tab(text: c('supplier_add_medicine.tab_add_medicine')),
            Tab(text: c('supplier_add_medicine.tab_add_scheme')),
          ],
        ),
      ),
      Expanded(
        child: TabBarView(controller: _tabs, children: const [
          _AddCompanyTab(),
          _AddMedicineTab(),
          _AddSchemeTab(),
        ]),
      ),
    ]);
  }
}

// ── Add Company tab ───────────────────────────────────────────────────────────

class _AddCompanyTab extends StatefulWidget {
  const _AddCompanyTab();
  @override
  State<_AddCompanyTab> createState() => _AddCompanyTabState();
}

class _AddCompanyTabState extends State<_AddCompanyTab> {
  final _formKey  = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  bool _submitting = false;
  List<Map<String, dynamic>> _pending = [];

  @override
  void initState() { super.initState(); _loadPending(); }

  @override
  void dispose() { _nameCtrl.dispose(); super.dispose(); }

  Future<void> _loadPending() async {
    try {
      final res = await Supabase.instance.client
          .rpc('pending_staging_all', params: {'p_kind': 'company'})
          .then((r) => (((r is List ? r.first : r) as Map)['rows'] as List)) as List;
      if (mounted) setState(() => _pending = res.map((r) => Map<String, dynamic>.from(r as Map)).toList());
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitting = true);
    try {
      await Supabase.instance.client.rpc('submit_pending_company',
          params: {'p_company_name': _nameCtrl.text.trim()});
      _nameCtrl.clear();
      if (mounted) {
        showToast(context, c('supplier_add_medicine.toast_company_submitted'));
        RenderLog.write('supplier_pending_company_submit', 'ok');
        await _loadPending();
      }
    } catch (e) {
      if (mounted) showToast(context, cf('supplier_add_medicine.toast_failed', {'error': '$e'}), isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c('supplier_add_medicine.company_title'),
          style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700)),
        SizedBox(height: Ds.space.x4),
        Text(c('supplier_add_medicine.company_subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        Form(key: _formKey, child: Column(children: [
          TextFormField(controller: _nameCtrl,
            decoration: _inp(c('supplier_add_medicine.field_company_name_label'),
                c('supplier_add_medicine.field_company_name_hint')),
            validator: (v) => (v?.trim().isEmpty ?? true) ? c('supplier_add_medicine.validator_required') : null),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: ElevatedButton(
            onPressed: _submitting ? null : _submit,
            style: _btnStyle(),
            child: _submitting ? _spinner() : Text(c('supplier_add_medicine.btn_submit_for_approval')),
          )),
        ])),
        if (_pending.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(c('supplier_add_medicine.your_submissions'),
            style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
          SizedBox(height: Ds.space.x8),
          ..._pending.map((p) => _PendingRow(
            label: p['company_name'] as String? ?? '',
            statusLabel: (p['status_label'] as String?) ??
                (p['status'] as String? ?? ''),
            statusTone: p['status_tone'] as String?,
          )),
        ],
      ]),
    );
  }
}

// ── Add Medicine tab ──────────────────────────────────────────────────────────

class _AddMedicineTab extends StatefulWidget {
  const _AddMedicineTab();
  @override
  State<_AddMedicineTab> createState() => _AddMedicineTabState();
}

class _AddMedicineTabState extends State<_AddMedicineTab> {
  final _formKey   = GlobalKey<FormState>();
  final _nameCtrl  = TextEditingController();
  final _markCtrl  = TextEditingController();
  final _classCtrl = TextEditingController();
  final _mrpCtrl   = TextEditingController();
  bool _submitting = false;
  List<Map<String, dynamic>> _pending = [];

  @override
  void initState() { super.initState(); _loadPending(); }

  @override
  void dispose() {
    _nameCtrl.dispose(); _markCtrl.dispose();
    _classCtrl.dispose(); _mrpCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPending() async {
    try {
      final res = await Supabase.instance.client
          .rpc('pending_staging_all', params: {'p_kind': 'medicine'})
          .then((r) => (((r is List ? r.first : r) as Map)['rows'] as List)) as List;
      if (mounted) setState(() => _pending = res.map((r) => Map<String, dynamic>.from(r as Map)).toList());
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitting = true);
    try {
      await Supabase.instance.client.rpc('submit_pending_medicine', params: {
        'p_product_name':       _nameCtrl.text.trim(),
        'p_marketer':           _markCtrl.text.trim(),
        'p_therapeutic_class':  _classCtrl.text.trim().isEmpty ? null : _classCtrl.text.trim(),
        'p_mrp': _mrpCtrl.text.trim().isEmpty ? null : double.tryParse(_mrpCtrl.text.trim()),
      });
      _nameCtrl.clear(); _markCtrl.clear(); _classCtrl.clear(); _mrpCtrl.clear();
      if (mounted) {
        showToast(context, c('supplier_add_medicine.toast_medicine_submitted'));
        RenderLog.write('supplier_pending_medicine_submit', 'ok');
        await _loadPending();
      }
    } catch (e) {
      if (mounted) showToast(context, cf('supplier_add_medicine.toast_failed', {'error': '$e'}), isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c('supplier_add_medicine.medicine_title'),
          style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700)),
        SizedBox(height: Ds.space.x4),
        Text(c('supplier_add_medicine.medicine_subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        Form(key: _formKey, child: Column(children: [
          TextFormField(controller: _nameCtrl,
            decoration: _inp(c('supplier_add_medicine.field_product_name_label'),
                c('supplier_add_medicine.field_product_name_hint')),
            validator: (v) => (v?.trim().isEmpty ?? true) ? c('supplier_add_medicine.validator_required') : null),
          const SizedBox(height: 10),
          TextFormField(controller: _markCtrl,
            decoration: _inp(c('supplier_add_medicine.field_marketer_label'),
                c('supplier_add_medicine.field_marketer_hint')),
            validator: (v) => (v?.trim().isEmpty ?? true) ? c('supplier_add_medicine.validator_required') : null),
          const SizedBox(height: 10),
          TextFormField(controller: _classCtrl,
            decoration: _inp(c('supplier_add_medicine.field_therapeutic_class_label'),
                c('supplier_add_medicine.field_therapeutic_class_hint'))),
          const SizedBox(height: 10),
          TextFormField(controller: _mrpCtrl,
            decoration: _inp(c('supplier_add_medicine.field_mrp_label'),
                c('supplier_add_medicine.field_mrp_hint')),
            keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: ElevatedButton(
            onPressed: _submitting ? null : _submit,
            style: _btnStyle(),
            child: _submitting ? _spinner() : Text(c('supplier_add_medicine.btn_submit_for_approval')),
          )),
        ])),
        if (_pending.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(c('supplier_add_medicine.your_submissions'),
            style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
          SizedBox(height: Ds.space.x8),
          ..._pending.map((p) => _PendingRow(
            label: '${p['product_name']} — ${p['marketer']}',
            statusLabel: (p['status_label'] as String?) ??
                (p['status'] as String? ?? ''),
            statusTone: p['status_tone'] as String?,
          )),
        ],
      ]),
    );
  }
}

// ── Add Scheme tab ────────────────────────────────────────────────────────────

class _AddSchemeTab extends StatefulWidget {
  const _AddSchemeTab();
  @override
  State<_AddSchemeTab> createState() => _AddSchemeTabState();
}

class _AddSchemeTabState extends State<_AddSchemeTab> {
  final _searchCtrl   = TextEditingController();
  final _orderQtyCtrl = TextEditingController();
  final _freeQtyCtrl  = TextEditingController();
  final _discCtrl     = TextEditingController();
  final _priceCtrl    = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  Map<String, dynamic>? _selected;
  String _schemeType = 'free_goods';
  bool _saving = false;
  Timer? _debounce;

  bool _ocrLoading = false;
  List<Map<String, dynamic>> _ocrReview = [];
  bool _ocrImporting = false;

  @override
  void dispose() {
    _searchCtrl.dispose(); _orderQtyCtrl.dispose(); _freeQtyCtrl.dispose();
    _discCtrl.dispose(); _priceCtrl.dispose(); _debounce?.cancel();
    super.dispose();
  }

  void _onSearch(String val) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(val));
  }

  Future<void> _search(String q) async {
    if (q.trim().length < 2) { setState(() => _results = []); return; }
    setState(() => _searching = true);
    try {
      final res = await Supabase.instance.client.rpc('supplier_home_medicines',
          params: {'p_search': q, 'p_limit': 10, 'p_offset': 0}) as List;
      if (mounted) setState(() => _results = res.map((r) => Map<String, dynamic>.from(r as Map)).toList());
    } catch (_) {} finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _saveScheme() async {
    if (_selected == null) return;
    final oQty = double.tryParse(_orderQtyCtrl.text.trim());
    final fQty = double.tryParse(_freeQtyCtrl.text.trim());
    final disc = double.tryParse(_discCtrl.text.trim());
    final price = double.tryParse(_priceCtrl.text.trim());
    if (_schemeType == 'free_goods' && (oQty == null || fQty == null)) {
      showToast(context, c('supplier_add_medicine.err_enter_buy_free_qty'), isError: true); return;
    }
    if (_schemeType == 'discount_pct' && disc == null) {
      showToast(context, c('supplier_add_medicine.err_enter_discount_pct'), isError: true); return;
    }
    if (_schemeType == 'special_price' && price == null) {
      showToast(context, c('supplier_add_medicine.err_enter_special_price'), isError: true); return;
    }
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('upsert_supplier_scheme', params: {
        'p_product_id':   _selected!['id'],
        'p_product_name': _selected!['product_name'],
        'p_scheme_type':  _schemeType,
        'p_order_qty':    oQty,
        'p_free_qty':     fQty,
        'p_discount_pct': disc,
        'p_special_price': price,
      });
      if (mounted) {
        showToast(context, c('supplier_add_medicine.toast_scheme_saved'));
        RenderLog.write('supplier_scheme_upsert', '${_selected!['id']}:$_schemeType');
        setState(() {
          _selected = null; _searchCtrl.clear(); _results = [];
          _orderQtyCtrl.clear(); _freeQtyCtrl.clear(); _discCtrl.clear(); _priceCtrl.clear();
        });
      }
    } catch (e) {
      if (mounted) showToast(context, cf('supplier_add_medicine.toast_failed', {'error': '$e'}), isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAndOcr() async {
    final input = html.FileUploadInputElement()..accept = 'image/*';
    input.click();
    final completer = Completer<Uint8List?>();
    input.onChange.listen((_) async {
      final file = input.files?.first;
      if (file == null) { completer.complete(null); return; }
      final reader = html.FileReader();
      reader.readAsArrayBuffer(file);
      reader.onLoadEnd.listen((_) => completer.complete(reader.result as Uint8List?));
    });
    final bytes = await completer.future;
    if (bytes == null || !mounted) return;

    setState(() { _ocrLoading = true; _ocrReview = []; });
    try {
      final b64 = base64Encode(bytes);
      const prompt =
        'Extract a list of medicine schemes from this image. '
        'For each item return JSON: {"product_name":"<verbatim>","order_qty":<number or null>,"free_qty":<number or null>}. '
        'Return ONLY a JSON array. Never expand abbreviations or normalise names.';
      final resp = await http.post(
        Uri.parse(_kOcrEdgeFn),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
        },
        body: jsonEncode({'image_base64': b64, 'prompt': prompt}),
      );
      if (!mounted) return;
      if (resp.statusCode != 200) throw Exception('OCR error ${resp.statusCode}');
      final body = jsonDecode(resp.body) as Map;
      final text = (body['text'] ?? body['content'] ?? '') as String;
      final s = text.indexOf('['), e = text.lastIndexOf(']') + 1;
      if (s < 0 || e <= s) throw Exception('No JSON in OCR response');
      final parsed = jsonDecode(text.substring(s, e)) as List;
      setState(() => _ocrReview = parsed.map((r) => Map<String, dynamic>.from(r as Map)).toList());
      RenderLog.write('supplier_ocr_review', _ocrReview.length);
    } catch (e) {
      if (mounted) showToast(context, cf('supplier_add_medicine.toast_ocr_error', {'error': '$e'}), isError: true);
    } finally {
      if (mounted) setState(() => _ocrLoading = false);
    }
  }

  Future<void> _importOcr() async {
    if (_ocrReview.isEmpty) return;
    setState(() => _ocrImporting = true);
    try {
      final schemes = _ocrReview.map((r) => {
        'product_name': r['product_name'],
        'scheme_type':  'free_goods',
        'order_qty':    r['order_qty']?.toString(),
        'free_qty':     r['free_qty']?.toString(),
      }).toList();
      final count = await Supabase.instance.client
          .rpc('import_supplier_schemes', params: {'p_schemes': schemes}) as int?;
      if (mounted) {
        showToast(context, cf('supplier_add_medicine.toast_schemes_imported',
            {'count': '${count ?? _ocrReview.length}'}));
        RenderLog.write('supplier_ocr_imported', count ?? _ocrReview.length);
        setState(() => _ocrReview = []);
      }
    } catch (e) {
      if (mounted) showToast(context, cf('supplier_add_medicine.toast_import_failed', {'error': '$e'}), isError: true);
    } finally {
      if (mounted) setState(() => _ocrImporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Search & manual ──────────────────────────────────────────────────
        Text(c('supplier_add_medicine.scheme_title'),
          style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700)),
        SizedBox(height: Ds.space.x12),
        TextField(
          controller: _searchCtrl,
          onChanged: _onSearch,
          decoration: _inp(c('supplier_add_medicine.field_search_medicine_label'),
              c('supplier_add_medicine.field_search_medicine_hint')),
        ),
        if (_searching)
          Padding(padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
            child: LinearProgressIndicator(
                color: Ds.c.brand, backgroundColor: Ds.c.successSoft)),
        if (_results.isNotEmpty && _selected == null)
          Container(
            margin: EdgeInsets.only(top: Ds.space.x4),
            decoration: BoxDecoration(
              color: Ds.c.surface, borderRadius: Ds.r.rButton,
              border: Border.all(color: Ds.c.divider),
              boxShadow: Ds.elevation.e2,
            ),
            child: Column(children: _results.map((r) => InkWell(
              onTap: () => setState(() {
                _selected = r; _results = [];
                _searchCtrl.text = r['product_name'] as String? ?? '';
              }),
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x8),
                child: Row(children: [
                  Expanded(child: Text(r['product_name'] as String? ?? '',
                    style: Ds.t.caption.copyWith(color: Ds.c.text))),
                  Text(r['marketer'] as String? ?? '', style: Ds.t.caption),
                ]),
              ),
            )).toList()),
          ),
        if (_selected != null) ...[
          SizedBox(height: Ds.space.x8),
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x8),
            decoration: BoxDecoration(
              color: Ds.c.successSoft, borderRadius: Ds.r.rButton),
            child: Row(children: [
              Icon(Icons.check_circle, color: Ds.c.success, size: 16),
              SizedBox(width: Ds.space.x4),
              Expanded(child: Text(_selected!['product_name'] as String? ?? '',
                style: Ds.t.caption.copyWith(
                    color: Ds.c.success, fontWeight: FontWeight.w500))),
              GestureDetector(
                onTap: () => setState(() { _selected = null; _searchCtrl.clear(); }),
                child: Icon(Icons.close, color: Ds.c.success, size: 16),
              ),
            ]),
          ),
          SizedBox(height: Ds.space.x8),
          DropdownButtonFormField<String>(
            value: _schemeType,
            decoration: _inp(c('supplier_add_medicine.field_scheme_type_label'), ''),
            items: [
              DropdownMenuItem(value: 'free_goods',    child: Text(c('supplier_add_medicine.scheme_type_free_goods'))),
              DropdownMenuItem(value: 'discount_pct',  child: Text(c('supplier_add_medicine.scheme_type_discount_pct'))),
              DropdownMenuItem(value: 'special_price', child: Text(c('supplier_add_medicine.scheme_type_special_price'))),
            ],
            onChanged: (v) => setState(() => _schemeType = v ?? 'free_goods'),
          ),
          const SizedBox(height: 10),
          if (_schemeType == 'free_goods') Row(children: [
            Expanded(child: TextField(controller: _orderQtyCtrl,
              decoration: _inp(c('supplier_add_medicine.field_buy_qty_label'),
                  c('supplier_add_medicine.field_buy_qty_hint')),
              keyboardType: const TextInputType.numberWithOptions(decimal: true))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _freeQtyCtrl,
              decoration: _inp(c('supplier_add_medicine.field_free_qty_label'),
                  c('supplier_add_medicine.field_free_qty_hint')),
              keyboardType: const TextInputType.numberWithOptions(decimal: true))),
          ]),
          if (_schemeType == 'discount_pct') TextField(controller: _discCtrl,
            decoration: _inp(c('supplier_add_medicine.field_discount_pct_label'),
                c('supplier_add_medicine.field_discount_pct_hint')),
            keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          if (_schemeType == 'special_price') TextField(controller: _priceCtrl,
            decoration: _inp(c('supplier_add_medicine.field_special_price_label'),
                c('supplier_add_medicine.field_special_price_hint')),
            keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: ElevatedButton(
            onPressed: _saving ? null : _saveScheme,
            style: _btnStyle(),
            child: _saving ? _spinner() : Text(c('supplier_add_medicine.btn_save_scheme')),
          )),
        ],
        const SizedBox(height: 28),
        Divider(color: Ds.c.divider),
        const SizedBox(height: 16),
        // ── OCR upload ───────────────────────────────────────────────────────
        Text(c('supplier_add_medicine.ocr_title'),
          style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700)),
        SizedBox(height: Ds.space.x4),
        Text(c('supplier_add_medicine.ocr_subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        OutlinedButton.icon(
          onPressed: _ocrLoading ? null : _pickAndOcr,
          icon: _ocrLoading
              ? SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Ds.c.brand))
              : const Icon(Icons.upload_file, size: 18),
          label: Text(_ocrLoading
              ? c('supplier_add_medicine.btn_extracting')
              : c('supplier_add_medicine.btn_upload_scheme_image')),
          style: OutlinedButton.styleFrom(
            foregroundColor: Ds.c.brand,
            side: BorderSide(color: Ds.c.brand),
            padding: EdgeInsets.symmetric(
                vertical: Ds.space.x12, horizontal: Ds.space.x16),
          ),
        ),
        if (_ocrReview.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(c('supplier_add_medicine.ocr_review_title'),
            style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
          SizedBox(height: Ds.space.x8),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Ds.c.divider),
              borderRadius: Ds.r.rButton,
            ),
            child: Column(children: [
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x8),
                color: Ds.c.bg,
                child: Row(children: [
                  Expanded(flex: 3, child: Text(c('supplier_add_medicine.ocr_col_product_name'), style: _colHead)),
                  SizedBox(width: Ds.space.x8),
                  SizedBox(width: 48, child: Text(c('supplier_add_medicine.ocr_col_buy'), textAlign: TextAlign.center, style: _colHead)),
                  SizedBox(width: Ds.space.x8),
                  SizedBox(width: 48, child: Text(c('supplier_add_medicine.ocr_col_free'), textAlign: TextAlign.center, style: _colHead)),
                ]),
              ),
              ..._ocrReview.asMap().entries.map((e) {
                final r = e.value;
                return Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x8),
                  color: e.key.isEven ? Ds.c.surface : Ds.c.bg,
                  child: Row(children: [
                    Expanded(flex: 3, child: Text(r['product_name'] as String? ?? '',
                      style: Ds.t.caption.copyWith(color: Ds.c.text))),
                    SizedBox(width: Ds.space.x8),
                    SizedBox(width: 48, child: Text('${r['order_qty'] ?? '—'}',
                      textAlign: TextAlign.center,
                      style: Ds.t.caption.copyWith(color: Ds.c.text))),
                    SizedBox(width: Ds.space.x8),
                    SizedBox(width: 48, child: Text('${r['free_qty'] ?? '—'}',
                      textAlign: TextAlign.center,
                      style: Ds.t.caption.copyWith(color: Ds.c.text))),
                  ]),
                );
              }),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: _ocrImporting ? null : _importOcr,
            icon: _ocrImporting
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.check, size: 18),
            label: Text(_ocrImporting
                ? c('supplier_add_medicine.btn_importing')
                : cf('supplier_add_medicine.btn_confirm_import', {'count': '${_ocrReview.length}'})),
            style: _btnStyle(),
          )),
        ],
      ]),
    );
  }
}

// ── Shared helpers ────────────────────────────────────────────────────────────

/// The OCR review table's column heading — one style, three columns.
TextStyle get _colHead => Ds.t.caption.copyWith(fontWeight: FontWeight.w600);

InputDecoration _inp(String label, String hint) => InputDecoration(
  labelText: label,
  hintText: hint,
  hintStyle: Ds.t.caption,
  filled: true,
  fillColor: Ds.c.bg,
  contentPadding: EdgeInsets.symmetric(
      horizontal: Ds.space.x12, vertical: Ds.space.x12),
  border: OutlineInputBorder(borderRadius: Ds.r.rButton,
    borderSide: BorderSide(color: Ds.c.divider)),
  enabledBorder: OutlineInputBorder(borderRadius: Ds.r.rButton,
    borderSide: BorderSide(color: Ds.c.divider)),
  focusedBorder: OutlineInputBorder(borderRadius: Ds.r.rButton,
    borderSide: BorderSide(color: Ds.c.brand)),
);

ButtonStyle _btnStyle() => ElevatedButton.styleFrom(
  backgroundColor: Ds.c.brand,
  foregroundColor: Ds.c.surface,
  padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
);

Widget _spinner() => SizedBox(width: 20, height: 20,
  child: CircularProgressIndicator(color: Ds.c.surface, strokeWidth: 2));

/// CHANGE #671 gap 51 — the approval chip is a PRINTER.
///
/// It used to switch on the staging status to pick one of three hardcoded hex
/// pairs, with everything unrecognised silently drawn as "pending" amber.
/// pending_staging_all sends status_label and status_tone now; this row does one
/// tone -> token lookup and decides nothing.
class _PendingRow extends StatelessWidget {
  final String label;
  final String statusLabel;
  final String? statusTone;
  const _PendingRow({
    required this.label,
    required this.statusLabel,
    this.statusTone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x4),
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        color: Ds.c.surface, borderRadius: Ds.r.rButton,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Row(children: [
        Expanded(child: Text(label,
          style: Ds.t.caption.copyWith(color: Ds.c.text))),
        if (statusLabel.isNotEmpty)
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x8, vertical: Ds.space.x4),
            decoration: BoxDecoration(
                color: dsToneBg(statusTone), borderRadius: Ds.r.rChip),
            child: Text(statusLabel,
              style: Ds.t.caption.copyWith(
                  fontWeight: FontWeight.w500, color: dsToneFg(statusTone))),
          ),
      ]),
    );
  }
}
