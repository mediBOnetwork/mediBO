// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/ui_copy.dart';
import '../../supabase_config.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

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
        color: Colors.white,
        child: TabBar(
          controller: _tabs,
          labelColor: const Color(0xFF1B7A43),
          unselectedLabelColor: const Color(0xFF6B7280),
          indicatorColor: const Color(0xFF1B7A43),
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
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c('supplier_add_medicine.company_title'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 4),
        Text(c('supplier_add_medicine.company_subtitle'),
          style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
        const SizedBox(height: 16),
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
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          const SizedBox(height: 8),
          ..._pending.map((p) => _PendingRow(
            label: p['company_name'] as String? ?? '',
            status: p['status'] as String? ?? 'pending',
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
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c('supplier_add_medicine.medicine_title'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 4),
        Text(c('supplier_add_medicine.medicine_subtitle'),
          style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
        const SizedBox(height: 16),
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
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          const SizedBox(height: 8),
          ..._pending.map((p) => _PendingRow(
            label: '${p['product_name']} — ${p['marketer']}',
            status: p['status'] as String? ?? 'pending',
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
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Search & manual ──────────────────────────────────────────────────
        Text(c('supplier_add_medicine.scheme_title'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 12),
        TextField(
          controller: _searchCtrl,
          onChanged: _onSearch,
          decoration: _inp(c('supplier_add_medicine.field_search_medicine_label'),
              c('supplier_add_medicine.field_search_medicine_hint')),
        ),
        if (_searching)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(color: Color(0xFF1B7A43), backgroundColor: Color(0xFFD1FAE5))),
        if (_results.isNotEmpty && _selected == null)
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE5E7EB)),
              boxShadow: const [BoxShadow(color: Color(0x12000000), blurRadius: 8)],
            ),
            child: Column(children: _results.map((r) => InkWell(
              onTap: () => setState(() {
                _selected = r; _results = [];
                _searchCtrl.text = r['product_name'] as String? ?? '';
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  Expanded(child: Text(r['product_name'] as String? ?? '',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF111827)))),
                  Text(r['marketer'] as String? ?? '',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                ]),
              ),
            )).toList()),
          ),
        if (_selected != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.check_circle, color: Color(0xFF065F46), size: 16),
              const SizedBox(width: 6),
              Expanded(child: Text(_selected!['product_name'] as String? ?? '',
                style: const TextStyle(fontSize: 13, color: Color(0xFF065F46), fontWeight: FontWeight.w500))),
              GestureDetector(
                onTap: () => setState(() { _selected = null; _searchCtrl.clear(); }),
                child: const Icon(Icons.close, color: Color(0xFF065F46), size: 16),
              ),
            ]),
          ),
          const SizedBox(height: 10),
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
        const Divider(color: Color(0xFFE5E7EB)),
        const SizedBox(height: 16),
        // ── OCR upload ───────────────────────────────────────────────────────
        Text(c('supplier_add_medicine.ocr_title'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 4),
        Text(c('supplier_add_medicine.ocr_subtitle'),
          style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _ocrLoading ? null : _pickAndOcr,
          icon: _ocrLoading
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)))
              : const Icon(Icons.upload_file, size: 18),
          label: Text(_ocrLoading
              ? c('supplier_add_medicine.btn_extracting')
              : c('supplier_add_medicine.btn_upload_scheme_image')),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF1B7A43),
            side: const BorderSide(color: Color(0xFF1B7A43)),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          ),
        ),
        if (_ocrReview.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(c('supplier_add_medicine.ocr_review_title'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                color: const Color(0xFFF3F4F6),
                child: Row(children: [
                  Expanded(flex: 3, child: Text(c('supplier_add_medicine.ocr_col_product_name'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF6B7280)))),
                  const SizedBox(width: 8),
                  SizedBox(width: 48, child: Text(c('supplier_add_medicine.ocr_col_buy'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF6B7280)))),
                  const SizedBox(width: 8),
                  SizedBox(width: 48, child: Text(c('supplier_add_medicine.ocr_col_free'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF6B7280)))),
                ]),
              ),
              ..._ocrReview.asMap().entries.map((e) {
                final r = e.value;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  color: e.key.isEven ? Colors.white : const Color(0xFFF9FAFB),
                  child: Row(children: [
                    Expanded(flex: 3, child: Text(r['product_name'] as String? ?? '',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF111827)))),
                    const SizedBox(width: 8),
                    SizedBox(width: 48, child: Text('${r['order_qty'] ?? '—'}',
                      textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Color(0xFF374151)))),
                    const SizedBox(width: 8),
                    SizedBox(width: 48, child: Text('${r['free_qty'] ?? '—'}',
                      textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Color(0xFF374151)))),
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

InputDecoration _inp(String label, String hint) => InputDecoration(
  labelText: label,
  hintText: hint,
  hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
  filled: true,
  fillColor: const Color(0xFFF5F6F8),
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
    borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
    borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
    borderSide: const BorderSide(color: Color(0xFF1B7A43))),
);

ButtonStyle _btnStyle() => ElevatedButton.styleFrom(
  backgroundColor: const Color(0xFF1B7A43),
  foregroundColor: Colors.white,
  padding: const EdgeInsets.symmetric(vertical: 14),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
);

Widget _spinner() => const SizedBox(width: 20, height: 20,
  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2));

class _PendingRow extends StatelessWidget {
  final String label;
  final String status;
  const _PendingRow({required this.label, required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg, fg;
    switch (status) {
      case 'approved': bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46); break;
      case 'rejected': bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B); break;
      default:         bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(children: [
        Expanded(child: Text(label,
          style: const TextStyle(fontSize: 13, color: Color(0xFF111827)))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
          child: Text(status,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: fg)),
        ),
      ]),
    );
  }
}
